`timescale 1ns/1ps
`default_nettype none

// AD7606C parallel controller using a conversion/readout pipeline.
// CONVST requests remain on the configured sample cadence. Each completed
// conversion starts its V1..V8 read immediately after synchronized BUSY falls,
// leaving nearly one complete sample period before the next BUSY falling edge
// can update the ADC output register.
module ad7606c_pipelined_controller #(
    parameter integer CONVST_HIGH_CYCLES = 1,
    parameter integer RD_LOW_CYCLES = 2,
    parameter integer RD_HIGH_CYCLES = 1,
    parameter integer CONVERSION_TIMEOUT_CYCLES = 31
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire         stop,
    input  wire         busy_i,
    input  wire [15:0]  db_i,
    input  wire         frstdata_i,
    output wire         adc_reset,
    output wire         convst,
    output wire         cs_n,
    output wire         rd_n,
    output wire         db_oe,
    output reg  [127:0] sample_data,
    output reg          sample_valid,
    output reg          busy_timeout,
    output reg          frame_alignment_error,
    output wire         start_ready,
    output wire         capture_idle,
    output wire [3:0]   state
);
    localparam [3:0] ST_IDLE      = 4'd0;
    localparam [3:0] ST_CS_ASSERT = 4'd1;
    localparam [3:0] ST_RD_LOW   = 4'd2;
    localparam [3:0] ST_RD_HIGH  = 4'd3;
    localparam [3:0] ST_RELEASE  = 4'd4;
    localparam [3:0] ST_ERROR    = 4'd15;

    (* ASYNC_REG = "TRUE" *) reg busy_sync1;
    (* ASYNC_REG = "TRUE" *) reg busy_sync2;
    reg busy_sync_d;
    wire busy_rise = !busy_sync_d && busy_sync2;
    wire busy_fall = busy_sync_d && !busy_sync2;

    reg [3:0] read_state;
    reg [3:0] channel_index;
    reg [7:0] read_timer;
    reg [7:0] conversion_timer;
    reg [7:0] convst_timer;
    reg convst_active;
    reg conversion_pending;
    wire conversion_expired = conversion_pending &&
                              (conversion_timer >= CONVERSION_TIMEOUT_CYCLES);

    function automatic timer_done;
        input [7:0] count;
        input integer cycles;
        begin
            if (cycles <= 1)
                timer_done = 1'b1;
            else
                timer_done = count >= cycles-1;
        end
    endfunction

    assign adc_reset = 1'b0;
    assign db_oe = 1'b0;
    assign convst = convst_active;
    assign cs_n = !((read_state == ST_CS_ASSERT) ||
                    (read_state == ST_RD_LOW) ||
                    (read_state == ST_RD_HIGH));
    assign rd_n = !(read_state == ST_RD_LOW);
    // `stop` is also asserted by the device frontend during initialization
    // and while the system is READY. It inhibits new conversions and
    // suppresses sample_valid without latching across a later START.
    // A new conversion can start while the preceding frame is being read.
    // The ADC readout must not throttle the 1 MSPS CONVST cadence.
    assign start_ready = !busy_timeout && !frame_alignment_error &&
                         !conversion_pending &&
                         !convst_active;
    assign capture_idle = !convst_active && !conversion_pending &&
                          (read_state == ST_IDLE);
    assign state = read_state;

    always @(posedge clk) begin
        if (rst) begin
            busy_sync1            <= 1'b0;
            busy_sync2            <= 1'b0;
            busy_sync_d           <= 1'b0;
            read_state            <= ST_IDLE;
            channel_index         <= 4'd0;
            read_timer            <= 8'd0;
            conversion_timer      <= 8'd0;
            convst_timer          <= 8'd0;
            convst_active         <= 1'b0;
            conversion_pending    <= 1'b0;
            sample_data           <= 128'd0;
            sample_valid          <= 1'b0;
            busy_timeout          <= 1'b0;
            frame_alignment_error <= 1'b0;
        end else begin
            busy_sync1  <= busy_i;
            busy_sync2  <= busy_sync1;
            busy_sync_d <= busy_sync2;
            sample_valid <= 1'b0;

            if (convst_active) begin
                if (timer_done(convst_timer, CONVST_HIGH_CYCLES)) begin
                    convst_active <= 1'b0;
                    convst_timer <= 8'd0;
                end else begin
                    convst_timer <= convst_timer + 1'b1;
                end
            end

            if (conversion_pending) begin
                if (conversion_expired) begin
                    busy_timeout <= 1'b1;
                    read_state <= ST_ERROR;
                    conversion_pending <= 1'b0;
                end else begin
                    conversion_timer <= conversion_timer + 1'b1;
                end
            end

            // BUSY falling means the current conversion has updated the ADC
            // output register. Start at V1 here so the complete frame is read
            // before the next conversion's BUSY falling edge updates it again.
            if (busy_fall) begin
                if (!conversion_pending || conversion_expired) begin
                    busy_timeout <= 1'b1;
                    read_state <= ST_ERROR;
                end else begin
                    conversion_pending <= 1'b0;
                    conversion_timer <= 8'd0;
                    if (!stop) begin
                        if (read_state != ST_IDLE) begin
                            busy_timeout <= 1'b1;
                            read_state <= ST_ERROR;
                        end else begin
                            read_state <= ST_CS_ASSERT;
                            read_timer <= 8'd0;
                            channel_index <= 4'd0;
                        end
                    end
                end
            end

            // Launch conversion independently of read_state. At 1 MSPS, the
            // next CONVST occurs while this frame is still being read, but the
            // read completes before that conversion's BUSY falling edge.
            if (start) begin
                if (!start_ready || stop) begin
                    busy_timeout <= 1'b1;
                    read_state <= ST_ERROR;
                end else begin
                    convst_active <= 1'b1;
                    convst_timer <= 8'd0;
                    conversion_pending <= 1'b1;
                    conversion_timer <= 8'd0;
                end
            end

            case (read_state)
                ST_IDLE: begin
                    read_timer <= 8'd0;
                    channel_index <= 4'd0;
                end

                ST_CS_ASSERT: begin
                    read_state <= ST_RD_LOW;
                    read_timer <= 8'd0;
                end

                ST_RD_LOW: begin
                    if (timer_done(read_timer, RD_LOW_CYCLES)) begin
                        read_timer <= 8'd0;
                        // AD7606C asserts FRSTDATA after the RD falling edge
                        // that exposes V1, then clears it on the next RD edge.
                        // Check the marker at the same qualified capture point
                        // as DB so a shifted frame can never be published.
                        if (((channel_index == 4'd0) && !frstdata_i) ||
                            ((channel_index != 4'd0) && frstdata_i)) begin
                            frame_alignment_error <= 1'b1;
                            conversion_pending <= 1'b0;
                            convst_active <= 1'b0;
                            convst_timer <= 8'd0;
                            read_state <= ST_ERROR;
                        end else begin
                            sample_data[channel_index*16 +: 16] <= db_i;
                            if (channel_index == 4'd7)
                                read_state <= ST_RELEASE;
                            else begin
                                channel_index <= channel_index + 1'b1;
                                read_state <= ST_RD_HIGH;
                            end
                        end
                    end else begin
                        read_timer <= read_timer + 1'b1;
                    end
                end

                ST_RD_HIGH: begin
                    if (timer_done(read_timer, RD_HIGH_CYCLES)) begin
                        read_timer <= 8'd0;
                        read_state <= ST_RD_LOW;
                    end else begin
                        read_timer <= read_timer + 1'b1;
                    end
                end

                ST_RELEASE: begin
                    read_state <= ST_IDLE;
                    channel_index <= 4'd0;
                    if (!stop)
                        sample_valid <= 1'b1;
                end

                ST_ERROR: begin
                    read_state <= ST_ERROR;
                end

                default: begin
                    busy_timeout <= 1'b1;
                    read_state <= ST_ERROR;
                end
            endcase

            // STOP is graceful. The current read sequence reaches ST_IDLE;
            // no new conversion is launched and any incomplete result is
            // discarded by suppressing sample_valid.
            if (stop && read_state == ST_IDLE && !conversion_pending &&
                !convst_active) begin
                channel_index <= 4'd0;
            end
        end
    end
endmodule

`default_nettype wire
