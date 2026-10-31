`timescale 1ns/1ps

// Single AD7606C-16 parallel software-mode register master.
//
// The ADC data bus is intentionally split into input/output/OE signals.  A
// board-level wrapper owns the actual IOBUFs; this module never declares an
// implicit inout.  The master does not start conversions (CONVST is held low).
// cmd_done means the electrical transaction completed. This generic timing
// engine intentionally does not hard-code the ADC register permission map;
// callers that require semantic write confirmation must read the register back
// or add an address-policy wrapper above this module.
module ad7606c_parallel_reg_master #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer RESET_CYCLES = 320,
    parameter integer SETUP_CYCLES = 27_400,
    parameter integer WR_LOW_CYCLES = 4,
    parameter integer WR_HIGH_CYCLES = 1,
    parameter integer WR_GAP_CYCLES = 18,
    parameter integer RD_LOW_CYCLES = 4,
    parameter integer RD_HIGH_CYCLES = 2,
    parameter integer CS_SETUP_CYCLES = 1,
    // AD7606C parallel writes are valid only after a completed register read
    // has moved the device out of its default ADC read mode. STATUS (0x01) is
    // a safe, read-only default entry address; board integrations may override
    // it with another known-readable Table 31 address.
    parameter [6:0] REGISTER_MODE_ENTRY_ADDR = 7'h01,
    parameter integer TRANSACTION_TIMEOUT_CYCLES = 10_000
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         cmd_valid,
    input  wire         cmd_write,
    input  wire  [6:0]  cmd_addr,
    input  wire  [7:0]  cmd_wdata,
    output reg          cmd_ready,
    output reg          cmd_busy,
    output reg          cmd_done,
    output reg          cmd_error,
    output reg   [7:0]  cmd_rdata,
    output reg          init_done,

    output reg   [2:0]  adc_os,
    output reg          adc_par_ser_sel,
    output reg          adc_nstby,
    output reg          adc_range,
    output reg          adc_convst,
    output reg          adc_rst,
    output reg          adc_ncs,
    output reg          adc_nwr,
    output reg          adc_nrd,
    input  wire  [15:0] adc_db_i,
    output reg   [15:0] adc_db_o,
    output reg          adc_db_oe
);

    localparam [4:0]

        ST_RESET = 5'd0,
        ST_SETUP = 5'd1,
        ST_IDLE = 5'd2,
        ST_WR_SETUP = 5'd3,
        ST_WR_LOW = 5'd4,
        ST_WR_HIGH = 5'd5,
        ST_WR_GAP = 5'd6,
        ST_RD_CMD_SETUP = 5'd7,
        ST_RD_CMD_LOW = 5'd8,
        ST_RD_CMD_HIGH = 5'd9,
        ST_RD_CMD_GAP = 5'd10,
        ST_RD_DATA_SETUP = 5'd11,
        ST_RD_DATA_LOW = 5'd12,
        ST_RD_DATA_HIGH = 5'd13,
        ST_EXIT_SETUP = 5'd14,
        ST_EXIT_LOW = 5'd15,
        ST_EXIT_HIGH = 5'd16,
        ST_EXIT_GAP = 5'd17,
        ST_DONE = 5'd18,
        ST_ERROR = 5'd19;

    reg [4:0] state;
    reg   [31:0] timer;
    reg   [31:0] transaction_timer;
    reg          init_done_reg;
    reg   [6:0]  cmd_addr_reg;
    reg   [7:0]  cmd_wdata_reg;
    reg          cmd_write_reg;
    reg   [7:0]  cmd_rdata_reg;
    reg          read_error_pending;
    reg          transaction_timeout;

    function automatic timer_expired;
        input [31:0] value;
        input integer cycles;
        begin
            if (cycles <= 1)
                timer_expired = 1'b1;
            else
                timer_expired = (value >= cycles - 1);
        end
    endfunction

    function automatic transaction_state;
        input [4:0] s;
        begin
        case (s)
            ST_WR_SETUP, ST_WR_LOW, ST_WR_HIGH, ST_WR_GAP,
            ST_RD_CMD_SETUP, ST_RD_CMD_LOW, ST_RD_CMD_HIGH, ST_RD_CMD_GAP,
            ST_RD_DATA_SETUP, ST_RD_DATA_LOW, ST_RD_DATA_HIGH,
            ST_EXIT_SETUP, ST_EXIT_LOW, ST_EXIT_HIGH, ST_EXIT_GAP:
                transaction_state = 1'b1;
            default:
                transaction_state = 1'b0;
            endcase
        end
    endfunction

    // Give timeout an explicit priority over normal state advancement. Without
    // this condition, a later nonblocking FSM assignment can overwrite timeout.
    always @* begin
        transaction_timeout = transaction_state(state) &&
                              timer_expired(transaction_timer,
                                            TRANSACTION_TIMEOUT_CYCLES);
    end

    always @* begin
        // Safe defaults: no conversion, no ADC control pulse, and released DB.
        adc_os         = 3'b111;
        adc_par_ser_sel = 1'b0;
        adc_nstby      = 1'b1;
        adc_range      = 1'b0;
        adc_convst     = 1'b0;
        adc_rst        = 1'b0;
        adc_ncs        = 1'b1;
        adc_nwr        = 1'b1;
        adc_nrd        = 1'b1;
        adc_db_o       = 16'h0000;
        adc_db_oe      = 1'b0;

        case (state)
            ST_RESET: begin
                adc_rst = 1'b1;
            end
            ST_WR_SETUP, ST_WR_LOW, ST_WR_HIGH: begin
                adc_ncs   = 1'b0;
                adc_db_o  = {1'b0, cmd_addr_reg, cmd_wdata_reg};
                adc_db_oe = 1'b1;
                if (state == ST_WR_LOW)
                    adc_nwr = 1'b0;
            end
            ST_RD_CMD_SETUP, ST_RD_CMD_LOW, ST_RD_CMD_HIGH: begin
                adc_ncs   = 1'b0;
                // A requested write first performs a complete benign register
                // read to enter register mode. The subsequent write frame is
                // then legal from the AD7606C's default ADC read mode.
                adc_db_o  = {1'b1,
                             (cmd_write_reg ? REGISTER_MODE_ENTRY_ADDR : cmd_addr_reg),
                             8'h00};
                adc_db_oe = 1'b1;
                if (state == ST_RD_CMD_LOW)
                    adc_nwr = 1'b0;
            end
            ST_RD_DATA_SETUP, ST_RD_DATA_LOW, ST_RD_DATA_HIGH: begin
                adc_ncs = 1'b0;
                if (state == ST_RD_DATA_LOW)
                    adc_nrd = 1'b0;
            end
            ST_EXIT_SETUP, ST_EXIT_LOW, ST_EXIT_HIGH: begin
                adc_ncs   = 1'b0;
                adc_db_o  = 16'h0000;
                adc_db_oe = 1'b1;
                if (state == ST_EXIT_LOW)
                    adc_nwr = 1'b0;
            end
            default: begin
                // Keep safe defaults.
            end
        endcase

        init_done = init_done_reg;
        cmd_ready = (state == ST_IDLE) && init_done_reg;
        cmd_busy  = !cmd_ready && (state != ST_DONE);
        cmd_done  = (state == ST_DONE);
        cmd_error = (state == ST_ERROR);
        cmd_rdata = cmd_rdata_reg;
    end

    always @(posedge clk) begin
        if (rst) begin
            state              <= ST_RESET;
            timer              <= 32'd0;
            transaction_timer  <= 32'd0;
            init_done_reg      <= 1'b0;
            cmd_addr_reg       <= 7'd0;
            cmd_wdata_reg      <= 8'd0;
            cmd_write_reg      <= 1'b0;
            cmd_rdata_reg      <= 8'd0;
            read_error_pending  <= 1'b0;
        end else if (transaction_timeout) begin
            // Timeout wins over normal state progress and leaves the ADC-side
            // outputs at their combinational safe idle values in ST_ERROR.
            state              <= ST_ERROR;
            timer              <= 32'd0;
            transaction_timer  <= 32'd0;
            read_error_pending <= 1'b0;
        end else begin
            if (transaction_state(state))
                transaction_timer <= transaction_timer + 32'd1;
            else
                transaction_timer <= 32'd0;

            case (state)
                ST_RESET: begin
                    timer <= 32'd0;
                    if (timer_expired(timer, RESET_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_SETUP;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                ST_SETUP: begin
                    if (timer_expired(timer, SETUP_CYCLES)) begin
                        timer         <= 32'd0;
                        init_done_reg <= 1'b1;
                        state         <= ST_IDLE;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                ST_IDLE: begin
                    timer <= 32'd0;
                    if (cmd_valid && cmd_ready) begin
                        cmd_addr_reg       <= cmd_addr;
                        cmd_wdata_reg      <= cmd_wdata;
                        cmd_write_reg      <= cmd_write;
                        read_error_pending <= 1'b0;
                        // A read command is also the required entry sequence
                        // before any parallel register write.
                        state              <= ST_RD_CMD_SETUP;
                    end
                end

                ST_WR_SETUP: begin
                    if (timer_expired(timer, CS_SETUP_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_WR_LOW;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_WR_LOW: begin
                    if (timer_expired(timer, WR_LOW_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_WR_HIGH;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_WR_HIGH: begin
                    if (timer_expired(timer, WR_HIGH_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_WR_GAP;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_WR_GAP: begin
                    if (timer_expired(timer, WR_GAP_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_EXIT_SETUP;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                ST_RD_CMD_SETUP: begin
                    if (timer_expired(timer, CS_SETUP_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_RD_CMD_LOW;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_RD_CMD_LOW: begin
                    if (timer_expired(timer, WR_LOW_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_RD_CMD_HIGH;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_RD_CMD_HIGH: begin
                    if (timer_expired(timer, WR_HIGH_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_RD_CMD_GAP;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_RD_CMD_GAP: begin
                    // The WR rising-edge interval requirement also applies
                    // between the read-address WR frame and the later exit
                    // WR frame.  Use the full write gap here rather than the
                    // shorter CS-only separation.
                    if (timer_expired(timer, WR_GAP_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_RD_DATA_SETUP;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_RD_DATA_SETUP: begin
                    if (timer_expired(timer, CS_SETUP_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_RD_DATA_LOW;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_RD_DATA_LOW: begin
                    if (timer_expired(timer, RD_LOW_CYCLES)) begin
                        // A bad response header must not overwrite the last
                        // known-good result. Case inequality treats X/Z on the
                        // board-facing DB input as an explicit error.
                        if ((adc_db_i[15] !== 1'b0) ||
                            (adc_db_i[14:8] !==
                             (cmd_write_reg ? REGISTER_MODE_ENTRY_ADDR : cmd_addr_reg))) begin
                            read_error_pending <= 1'b1;
                        end else begin
                            // The internal read that enters register mode for a
                            // write is protocol-only; it must not overwrite the
                            // result of the caller's most recent read command.
                            if (!cmd_write_reg)
                                cmd_rdata_reg <= adc_db_i[7:0];
                            read_error_pending <= 1'b0;
                        end
                        timer <= 32'd0;
                        state <= ST_RD_DATA_HIGH;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_RD_DATA_HIGH: begin
                    if (timer_expired(timer, RD_HIGH_CYCLES)) begin
                        timer <= 32'd0;
                        // A normal read exits register mode. A requested write
                        // instead continues from the verified entry read into
                        // its DB15=0 write frame. On a bad entry response, do
                        // not write; issue only the safe all-zero exit frame.
                        state <= (cmd_write_reg && !read_error_pending) ?
                                 ST_WR_SETUP : ST_EXIT_SETUP;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                ST_EXIT_SETUP: begin
                    if (timer_expired(timer, CS_SETUP_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_EXIT_LOW;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_EXIT_LOW: begin
                    if (timer_expired(timer, WR_LOW_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_EXIT_HIGH;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_EXIT_HIGH: begin
                    if (timer_expired(timer, WR_HIGH_CYCLES)) begin
                        timer <= 32'd0;
                        state <= ST_EXIT_GAP;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end
                ST_EXIT_GAP: begin
                    if (timer_expired(timer, WR_GAP_CYCLES)) begin
                        timer <= 32'd0;
                        state <= read_error_pending ? ST_ERROR : ST_DONE;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                ST_DONE: begin
                    timer <= 32'd0;
                    state <= ST_IDLE;
                end

                ST_ERROR: begin
                    timer <= 32'd0;
                    state <= ST_ERROR;
                end

                default: begin
                    state             <= ST_RESET;
                    timer             <= 32'd0;
                    init_done_reg     <= 1'b0;
                    read_error_pending <= 1'b0;
                end
            endcase
        end
    end

endmodule
