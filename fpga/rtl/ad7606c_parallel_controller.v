`timescale 1ns/1ps

// AD7606C-16 single-device parallel readout controller.
//
// Scope:
//   * One AD7606C-16 in hardware mode with the parallel 16-bit data bus.
//   * One accepted start request produces one CONVST pulse and one V1..V8
//     result frame.
//   * No AXI, FIFO, packetization, SPI register access, ownership arbitration,
//     board pin assignments, or physical constraints are included here.
//
// Clock/reset:
//   * All controller state is synchronous to clk.
//   * rst is an active-high synchronous reset.
//   * busy_i is an asynchronous external status input and is passed through a
//     two-flop synchronizer before the FSM uses it.
//   * db_i is captured coherently at the end of a qualified RD-low interval. It
//     is not synchronized bit-by-bit; the board-level I/O timing, placement,
//     and input-delay constraints remain a hardware-phase item.
//
// Data contract:
//   sample_data[16*ch +: 16] = V(ch+1), ch=0..7.
//   sample_valid is a one-clk pulse after V8 has been captured and CS has been
//   released for one full clk interval.
//   db_oe is fixed low because this read-only controller never drives DB15:DB0.
//
// Timing contract (AD7606C-16 Rev. A, Tables 3 and 4):
//   tLP_CNV = 10 ns, tHP_CNV = 10 ns, and tCYCLE = 1 us minimum between
//   consecutive CONVST rising edges; tS_BSY = 0 ns after BUSY falls;
//   tHP_RD/tLP_RD = 10 ns, tCYC_RD = 30 ns, tD_RD_DB <= 30 ns for
//   VDRIVE >= 2.7 V (25 ns below 2.7 V), tH_RD_DB = 12 ns, and tHP_CS = 10 ns.
//   The explicit cycle parameters below are the provisional implementation
//   contract for CLK_HZ. At the default 100 MHz assumption (10 ns/cycle), the
//   defaults use one cycle for the 10 ns pulse minima, 100 cycles for tCYCLE,
//   four cycles for RD low so capture is one cycle beyond the 30 ns access
//   bound, and two cycles for the RD-high gap so it also exceeds the 12 ns
//   tH_RD_DB data-hold requirement. Change these parameters together
//   with the actual clock and board I/O timing; they are not an XDC closure.
//
// Reset timing:
//   RESET_CYCLES=320 and SETUP_CYCLES=27400 correspond to the Rev. A full
//   RESET high width (3.2 us) and full-reset tDEVICE_SETUP (274 us) at the
//   provisional 100 MHz clock. The power-up condition, VDRIVE, IOSTANDARD,
//   and final mounted part remain integration closure items.

module ad7606c_parallel_controller #(
    // Provisional clock assumption used to explain the cycle defaults. The
    // controller does not derive a clock; callers must override all timing
    // counts when CLK_HZ changes.
    parameter integer CLK_HZ = 100_000_000,

    // AD7606C full-reset timing at the provisional 100 MHz clock.
    parameter integer RESET_CYCLES = 320,
    parameter integer SETUP_CYCLES = 27_400,

    // CONVST high minimum.  The caller owns the sampling cadence; this
    // controller accepts every start request presented while it is idle.
    parameter integer CONVST_HIGH_CYCLES = 1,

    // Conservative CS-to-first-RD separation. Rev. A tS_CS_RD is 0 ns; one
    // complete clk interval keeps the edge relationship unambiguous in RTL.
    parameter integer CS_SETUP_CYCLES = 1,

    // RD low interval includes margin beyond tD_RD_DB. RD_INTERVAL_CYCLES is
    // the high gap between consecutive RD-low windows, not the total period.
    parameter integer RD_LOW_CYCLES = 4,
    parameter integer RD_INTERVAL_CYCLES = 2,

    // Provisional timeout. The default is longer than the Rev. A no-OSR
    // tCONV maximum at 100 MHz; testbenches may shorten it deliberately.
    parameter integer BUSY_TIMEOUT_CYCLES = 128
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,
    input  wire          stop,
    input  wire          busy_i,
    input  wire  [15:0]  db_i,

    output wire          adc_reset,
    output wire          convst,
    output wire          cs_n,
    output wire          rd_n,
    output wire          db_oe,
    output reg   [127:0] sample_data,
    output reg           sample_valid,
    output reg           busy_timeout,
    output wire  [3:0]   state
);

    // State encodings are part of the small simulation/debug status contract.
    localparam [3:0] ST_ADC_RESET       = 4'd0;
    localparam [3:0] ST_SETUP           = 4'd1;
    localparam [3:0] ST_IDLE            = 4'd2;
    localparam [3:0] ST_CONVST_HIGH     = 4'd3;
    localparam [3:0] ST_WAIT_BUSY_HIGH  = 4'd4;
    localparam [3:0] ST_WAIT_BUSY_LOW   = 4'd5;
    localparam [3:0] ST_CS_ASSERT       = 4'd6;
    localparam [3:0] ST_RD_LOW          = 4'd7;
    localparam [3:0] ST_RD_HIGH         = 4'd8;
    localparam [3:0] ST_CS_RELEASE      = 4'd9;
    localparam [3:0] ST_FRAME_DONE      = 4'd10;
    localparam [3:0] ST_TIMEOUT         = 4'd11;

    reg   [3:0]  state_reg;
    reg   [31:0] timer;
    reg   [3:0]  channel_index;

    // stop_pending is used only where an immediate abort could truncate an
    // active CONVST or RD pulse. The current pulse is completed, then the
    // controller releases CS without producing sample_valid.
    reg          stop_pending;

    (* ASYNC_REG = "TRUE" *) reg busy_sync1;
    (* ASYNC_REG = "TRUE" *) reg busy_sync2;

    // A cycle count of one means the state occupies one complete clk interval.
    function automatic timer_done;
        input [31:0] count;
        input integer cycles;
        begin
            if (cycles <= 1)
                timer_done = 1'b1;
            else
                timer_done = (count >= (cycles - 1));
        end
    endfunction

    assign state = state_reg;

    // Safe output decode. Decode all control pins as one packed value so a
    // state transition cannot create zero-time CS/RD glitches in simulation or
    // rely on ordering between separately assigned combinational outputs.
    reg   [4:0] control_outputs;

    always @* begin
        case (state_reg)
            ST_ADC_RESET: begin
                control_outputs = 5'b10110; // adc_reset=1, CS/RD inactive
            end

            ST_CONVST_HIGH: begin
                control_outputs = 5'b01110; // convst=1
            end

            ST_CS_ASSERT: begin
                control_outputs = 5'b00010; // CS_N=0, RD_N=1
            end

            ST_RD_LOW: begin
                control_outputs = 5'b00000; // CS_N=0, RD_N=0
            end

            ST_RD_HIGH: begin
                control_outputs = 5'b00010; // CS_N=0, RD_N=1
            end

            default: begin
                control_outputs = 5'b00110; // all controls safely inactive
            end
        endcase
    end

    assign {adc_reset, convst, cs_n, rd_n, db_oe} = control_outputs;
    always @(posedge clk) begin
        if (rst) begin
            state_reg          <= ST_ADC_RESET;
            timer              <= 32'd0;
            channel_index      <= 4'd0;
            stop_pending       <= 1'b0;
            busy_sync1         <= 1'b0;
            busy_sync2         <= 1'b0;
            sample_data        <= 128'd0;
            sample_valid       <= 1'b0;
            busy_timeout       <= 1'b0;
        end else begin
            // Synchronize only the single-bit BUSY status. The parallel data
            // bus is sampled coherently inside the qualified RD window.
            busy_sync1 <= busy_i;
            busy_sync2 <= busy_sync1;
            sample_valid <= 1'b0;

            // stop is synchronous. During an active CONVST-high or RD-low
            // state, defer the abort until the current pulse reaches its
            // legal end. This avoids generating an unnecessarily short ADC
            // control pulse. In all other active states, release immediately.
            if (stop && !stop_pending) begin
                case (state_reg)
                    ST_TIMEOUT: begin
                        // Timeout is sticky until reset.
                        state_reg <= ST_TIMEOUT;
                        timer     <= 32'd0;
                    end

                    ST_CONVST_HIGH,
                    ST_RD_LOW: begin
                        stop_pending <= 1'b1;
                    end

                    ST_RD_HIGH,
                    ST_CS_ASSERT: begin
                        state_reg     <= ST_CS_RELEASE;
                        timer         <= 32'd0;
                        channel_index <= 4'd0;
                        stop_pending  <= 1'b1;
                    end

                    ST_FRAME_DONE: begin
                        state_reg     <= ST_IDLE;
                        timer         <= 32'd0;
                        channel_index <= 4'd0;
                        stop_pending  <= 1'b0;
                    end

                    default: begin
                        state_reg     <= ST_IDLE;
                        timer         <= 32'd0;
                        channel_index <= 4'd0;
                        stop_pending  <= 1'b0;
                    end
                endcase
            end else begin
                case (state_reg)
                    ST_ADC_RESET: begin
                        stop_pending <= 1'b0;
                        if (timer_done(timer, RESET_CYCLES)) begin
                            timer     <= 32'd0;
                            state_reg <= ST_SETUP;
                        end else begin
                            timer <= timer + 32'd1;
                        end
                    end

                    ST_SETUP: begin
                        stop_pending <= 1'b0;
                        if (timer_done(timer, SETUP_CYCLES)) begin
                            timer     <= 32'd0;
                            state_reg <= ST_IDLE;
                        end else begin
                            timer <= timer + 32'd1;
                        end
                    end

                    ST_IDLE: begin
                        timer         <= 32'd0;
                        stop_pending  <= 1'b0;
                        if (start && !busy_timeout) begin
                            channel_index <= 4'd0;
                            state_reg      <= ST_CONVST_HIGH;
                        end
                    end

                    ST_CONVST_HIGH: begin
                        if (timer_done(timer, CONVST_HIGH_CYCLES)) begin
                            timer <= 32'd0;
                            if (stop_pending) begin
                                state_reg    <= ST_IDLE;
                                stop_pending <= 1'b0;
                                channel_index <= 4'd0;
                            end else begin
                                state_reg <= ST_WAIT_BUSY_HIGH;
                            end
                        end else begin
                            timer <= timer + 32'd1;
                        end
                    end

                    ST_WAIT_BUSY_HIGH: begin
                        if (busy_sync2) begin
                            timer     <= 32'd0;
                            state_reg <= ST_WAIT_BUSY_LOW;
                        end else if (timer_done(timer, BUSY_TIMEOUT_CYCLES)) begin
                            timer        <= 32'd0;
                            busy_timeout <= 1'b1;
                            state_reg    <= ST_TIMEOUT;
                        end else begin
                            timer <= timer + 32'd1;
                        end
                    end

                    ST_WAIT_BUSY_LOW: begin
                        if (!busy_sync2) begin
                            timer     <= 32'd0;
                            state_reg <= ST_CS_ASSERT;
                        end else if (timer_done(timer, BUSY_TIMEOUT_CYCLES)) begin
                            timer        <= 32'd0;
                            busy_timeout <= 1'b1;
                            state_reg    <= ST_TIMEOUT;
                        end else begin
                            timer <= timer + 32'd1;
                        end
                    end

                    ST_CS_ASSERT: begin
                        if (timer_done(timer, CS_SETUP_CYCLES)) begin
                            timer     <= 32'd0;
                            state_reg <= ST_RD_LOW;
                        end else begin
                            timer <= timer + 32'd1;
                        end
                    end

                    ST_RD_LOW: begin
                        // Capture at the end of the active RD-low interval.
                        // With the default 100 MHz timing, four cycles gives
                        // 40 ns from RD falling to capture, beyond the 30 ns
                        // maximum tD_RD_DB (VDRIVE >= 2.7 V).
                        if (timer_done(timer, RD_LOW_CYCLES)) begin
                            sample_data[channel_index * 16 +: 16] <= db_i;
                            timer <= 32'd0;
                            if (stop_pending) begin
                                channel_index <= 4'd0;
                                state_reg     <= ST_CS_RELEASE;
                                stop_pending  <= 1'b1;
                            end else if (channel_index == 4'd7) begin
                                state_reg <= ST_CS_RELEASE;
                            end else begin
                                channel_index <= channel_index + 4'd1;
                                state_reg     <= ST_RD_HIGH;
                            end
                        end else begin
                            timer <= timer + 32'd1;
                        end
                    end

                    ST_RD_HIGH: begin
                        if (timer_done(timer, RD_INTERVAL_CYCLES)) begin
                            timer     <= 32'd0;
                            state_reg <= ST_RD_LOW;
                        end else begin
                            timer <= timer + 32'd1;
                        end
                    end

                    ST_CS_RELEASE: begin
                        // Keep CS released for one full cycle before reporting
                        // a normal frame. An aborted frame returns to IDLE with
                        // no sample_valid pulse.
                        timer <= 32'd0;
                        if (stop_pending) begin
                            state_reg     <= ST_IDLE;
                            channel_index <= 4'd0;
                            stop_pending  <= 1'b0;
                        end else begin
                            state_reg <= ST_FRAME_DONE;
                            sample_valid <= 1'b1;
                        end
                    end

                    ST_FRAME_DONE: begin
                        timer     <= 32'd0;
                        state_reg <= ST_IDLE;
                    end

                    ST_TIMEOUT: begin
                        // Sticky error state until synchronous reset. Outputs
                        // decode to safe values in this state.
                        timer     <= 32'd0;
                        state_reg <= ST_TIMEOUT;
                    end

                    default: begin
                        state_reg           <= ST_ADC_RESET;
                        timer               <= 32'd0;
                        channel_index       <= 4'd0;
                        stop_pending        <= 1'b0;
                        sample_data         <= 128'd0;
                        sample_valid        <= 1'b0;
                        busy_timeout        <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule
