`timescale 1ns / 1ps
`default_nettype none

// One AD7606C-16 software-mode frontend.  It performs the proven fixed
// +/-10 V register sequence, then accepts one-cycle conversion requests.
module ad7606c_device_frontend #(
    parameter integer POWERUP_WAIT_CYCLES = 320000,
    parameter integer REG_RESET_CYCLES = 103,
    parameter integer REG_SETUP_CYCLES = 8768,
    parameter integer PIPELINED_CAPTURE = 0
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         sample_start,
    input  wire         stop,
    input  wire         adc_busy,
    input  wire         adc_frstdata,
    inout  wire [15:0]  adc_db,
    output wire [2:0]   adc_os,
    output wire         adc_par_ser_sel,
    output wire         adc_nstby,
    output wire         adc_range,
    output wire         adc_convst,
    output wire         adc_rst,
    output wire         adc_ncs,
    output wire         adc_nwr,
    output wire         adc_nrd,
    output wire [127:0] sample_data,
    output wire         sample_valid,
    output wire         init_done,
    output wire         capture_idle,
    output wire         sample_ready,
    output wire         error,
    output wire [7:0]   error_code,
    output wire [3:0]   capture_state
);
    localparam [3:0] ST_WAIT_INIT = 0, ST_WR12 = 1, ST_RD12 = 2,
        ST_WR34 = 3, ST_RD34 = 4, ST_WR56 = 5, ST_RD56 = 6,
        ST_WR78 = 7, ST_RD78 = 8, ST_RUN = 9, ST_ERROR = 10;

    reg [3:0] state;
    reg [18:0] power_count;
    wire power_done = (power_count >= POWERUP_WAIT_CYCLES-1);
    wire core_rst = rst || !power_done;

    reg cmd_valid;
    reg cmd_write;
    reg [6:0] cmd_addr;
    wire cmd_ready, cmd_busy, cmd_done, cmd_error;
    wire [7:0] cmd_rdata;
    wire reg_init_done;
    wire [2:0] reg_os;
    wire reg_par, reg_stby, reg_range, reg_convst, reg_rst;
    wire reg_ncs, reg_nwr, reg_nrd;
    wire [15:0] reg_db_o;
    wire reg_db_oe;

    wire conv_rst, conv_convst, conv_ncs, conv_nrd, conv_db_oe;
    wire [127:0] conv_data;
    wire conv_valid, conv_timeout, conv_alignment_error;
    wire conv_start_ready, conv_capture_idle;
    wire [3:0] conv_state;

    reg [15:0] db_o;
    reg db_oe;
    wire [15:0] db_i;
    reg [2:0] pin_os;
    reg pin_par, pin_stby, pin_range, pin_convst, pin_rst;
    reg pin_ncs, pin_nwr, pin_nrd;
    reg init_ok;
    reg fault;
    reg [7:0] fault_code;

    genvar bit_index;
    generate
        for (bit_index=0; bit_index<16; bit_index=bit_index+1) begin : g_db
            IOBUF u_iobuf (.I(db_o[bit_index]), .O(db_i[bit_index]),
                           .T(!db_oe), .IO(adc_db[bit_index]));
        end
    endgenerate

    assign adc_os = pin_os;
    assign adc_par_ser_sel = pin_par;
    assign adc_nstby = pin_stby;
    assign adc_range = pin_range;
    assign adc_convst = pin_convst;
    assign adc_rst = pin_rst;
    assign adc_ncs = pin_ncs;
    assign adc_nwr = pin_nwr;
    assign adc_nrd = pin_nrd;
    assign sample_data = conv_data;
    assign sample_valid = conv_valid && state == ST_RUN && !stop;
    assign init_done = init_ok;
    assign capture_idle = conv_capture_idle;
    assign sample_ready = conv_start_ready;
    assign error = fault;
    assign error_code = fault_code;
    assign capture_state = conv_state;

    always @* begin
        cmd_valid = 1'b0;
        cmd_write = 1'b0;
        cmd_addr = 7'h03;
        case (state)
            ST_WR12: begin cmd_valid=1; cmd_write=1; cmd_addr=7'h03; end
            ST_RD12: begin cmd_valid=1; cmd_addr=7'h03; end
            ST_WR34: begin cmd_valid=1; cmd_write=1; cmd_addr=7'h04; end
            ST_RD34: begin cmd_valid=1; cmd_addr=7'h04; end
            ST_WR56: begin cmd_valid=1; cmd_write=1; cmd_addr=7'h05; end
            ST_RD56: begin cmd_valid=1; cmd_addr=7'h05; end
            ST_WR78: begin cmd_valid=1; cmd_write=1; cmd_addr=7'h06; end
            ST_RD78: begin cmd_valid=1; cmd_addr=7'h06; end
            default: begin end
        endcase
    end

    // Register master owns the pins until fixed initialization is complete.
    always @* begin
        pin_os = reg_os; pin_par = reg_par; pin_stby = reg_stby;
        pin_range = reg_range; pin_convst = reg_convst; pin_rst = reg_rst;
        pin_ncs = reg_ncs; pin_nwr = reg_nwr; pin_nrd = reg_nrd;
        db_o = reg_db_o; db_oe = reg_db_oe;
        if (state == ST_RUN) begin
            pin_convst = conv_convst; pin_rst = conv_rst;
            pin_ncs = conv_ncs; pin_nwr = 1'b1; pin_nrd = conv_nrd;
            db_o = 16'h0000; db_oe = conv_db_oe;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            power_count <= 0;
            state <= ST_WAIT_INIT;
            init_ok <= 0;
            fault <= 0;
            fault_code <= 0;
        end else begin
            if (!power_done)
                power_count <= power_count + 1'b1;
            if (core_rst) begin
                state <= ST_WAIT_INIT;
                init_ok <= 0;
                fault <= 0;
                fault_code <= 0;
            end else begin
                if (cmd_error) begin
                    state <= ST_ERROR; fault <= 1; fault_code <= 8'h01;
                end else if (conv_alignment_error) begin
                    state <= ST_ERROR; fault <= 1; fault_code <= 8'h03;
                end else if (conv_timeout) begin
                    state <= ST_ERROR; fault <= 1; fault_code <= 8'h02;
                end else begin
                    case (state)
                        ST_WAIT_INIT: if (reg_init_done && cmd_ready) state <= ST_WR12;
                        ST_WR12: if (cmd_done) state <= ST_RD12;
                        ST_RD12: if (cmd_done) begin
                            if (cmd_rdata != 8'h33) begin state<=ST_ERROR; fault<=1; fault_code<=8'h01; end
                            else state <= ST_WR34;
                        end
                        ST_WR34: if (cmd_done) state <= ST_RD34;
                        ST_RD34: if (cmd_done) begin
                            if (cmd_rdata != 8'h33) begin state<=ST_ERROR; fault<=1; fault_code<=8'h01; end
                            else state <= ST_WR56;
                        end
                        ST_WR56: if (cmd_done) state <= ST_RD56;
                        ST_RD56: if (cmd_done) begin
                            if (cmd_rdata != 8'h33) begin state<=ST_ERROR; fault<=1; fault_code<=8'h01; end
                            else state <= ST_WR78;
                        end
                        ST_WR78: if (cmd_done) state <= ST_RD78;
                        ST_RD78: if (cmd_done) begin
                            if (cmd_rdata != 8'h33) begin state<=ST_ERROR; fault<=1; fault_code<=8'h01; end
                            else begin state<=ST_RUN; init_ok<=1; end
                        end
                        ST_RUN: begin end
                        default: begin state<=ST_ERROR; fault<=1; fault_code<=8'h01; end
                    endcase
                end
            end
        end
    end

    ad7606c_parallel_reg_master #(
        .CLK_HZ(32000000), .RESET_CYCLES(REG_RESET_CYCLES),
        .SETUP_CYCLES(REG_SETUP_CYCLES), .WR_LOW_CYCLES(2),
        .WR_HIGH_CYCLES(1), .WR_GAP_CYCLES(6), .RD_LOW_CYCLES(2),
        .RD_HIGH_CYCLES(1), .CS_SETUP_CYCLES(1),
        .TRANSACTION_TIMEOUT_CYCLES(4000)
    ) u_reg (
        .clk(clk), .rst(core_rst), .cmd_valid(cmd_valid),
        .cmd_write(cmd_write), .cmd_addr(cmd_addr), .cmd_wdata(8'h33),
        .cmd_ready(cmd_ready), .cmd_busy(cmd_busy), .cmd_done(cmd_done),
        .cmd_error(cmd_error), .cmd_rdata(cmd_rdata), .init_done(reg_init_done),
        .adc_os(reg_os), .adc_par_ser_sel(reg_par), .adc_nstby(reg_stby),
        .adc_range(reg_range), .adc_convst(reg_convst), .adc_rst(reg_rst),
        .adc_ncs(reg_ncs), .adc_nwr(reg_nwr), .adc_nrd(reg_nrd),
        .adc_db_i(db_i), .adc_db_o(reg_db_o), .adc_db_oe(reg_db_oe)
    );

    generate
        if (PIPELINED_CAPTURE != 0) begin : g_pipeline
            ad7606c_pipelined_controller #(
                .CONVST_HIGH_CYCLES(1), .RD_LOW_CYCLES(2),
                .RD_HIGH_CYCLES(1), .CONVERSION_TIMEOUT_CYCLES(31)
            ) u_capture (
                .clk(clk), .rst(core_rst),
                .start(sample_start && state==ST_RUN),
                .stop(stop || state!=ST_RUN), .busy_i(adc_busy), .db_i(db_i),
                .frstdata_i(adc_frstdata),
                .adc_reset(conv_rst), .convst(conv_convst), .cs_n(conv_ncs),
                .rd_n(conv_nrd), .db_oe(conv_db_oe), .sample_data(conv_data),
                .sample_valid(conv_valid), .busy_timeout(conv_timeout),
                .frame_alignment_error(conv_alignment_error),
                .start_ready(conv_start_ready),
                .capture_idle(conv_capture_idle), .state(conv_state));
        end else begin : g_sequential
            assign conv_alignment_error = 1'b0;
            ad7606c_parallel_controller #(
                .CLK_HZ(32000000), .RESET_CYCLES(REG_RESET_CYCLES),
                .SETUP_CYCLES(REG_SETUP_CYCLES), .CONVST_HIGH_CYCLES(1),
                .CS_SETUP_CYCLES(1), .RD_LOW_CYCLES(2),
                .RD_INTERVAL_CYCLES(1), .BUSY_TIMEOUT_CYCLES(320)
            ) u_capture (
                .clk(clk), .rst(core_rst),
                .start(sample_start && state==ST_RUN),
                .stop(stop || state!=ST_RUN), .busy_i(adc_busy), .db_i(db_i),
                .adc_reset(conv_rst), .convst(conv_convst), .cs_n(conv_ncs),
                .rd_n(conv_nrd), .db_oe(conv_db_oe), .sample_data(conv_data),
                .sample_valid(conv_valid), .busy_timeout(conv_timeout),
                .state(conv_state));
            assign conv_start_ready = (conv_state == 4'd2);
            assign conv_capture_idle = (conv_state == 4'd2);
        end
    endgenerate
endmodule

`default_nettype wire
