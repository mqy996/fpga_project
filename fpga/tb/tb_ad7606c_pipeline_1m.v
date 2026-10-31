`timescale 1ns/1ps

module tb_ad7606c_pipeline_1m;
    localparam integer NUM_CONVERSIONS = 12;
    localparam integer BUSY_HIGH_CYCLES = 21; // ceil(650 ns / 31.25 ns)

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg stop = 1'b1;
    reg busy = 1'b0;
    reg [15:0] db_model = 16'd0;
    reg frstdata_model = 1'b0;

    wire convst, cs_n, rd_n, sample_valid, busy_timeout;
    wire frame_alignment_error;
    wire adc_reset, db_oe, start_ready, capture_idle;
    wire [15:0] db = db_model;
    wire [127:0] sample_data;
    wire [3:0] state;

    integer cycle_count = 0;
    integer start_count = 0;
    integer convst_count = 0;
    integer valid_count = 0;
    integer busy_fall_count = 0;
    integer reads_since_busy = 0;
    integer last_start_cycle = -1;
    integer last_convst_cycle = -1;
    integer last_valid_cycle = -1;
    integer last_busy_fall_cycle = -1;
    integer last_rd_fall_cycle = -1;
    integer min_busy_margin_cycles = 1000;
    integer expected_frame_id = 0;
    integer i;
    integer channel;

    reg [7:0] conversion_counter = 8'd0;
    reg [7:0] active_frame_id = 8'd0;
    reg [7:0] adc_output_frame_id = 8'd0;
    integer busy_countdown = 0;

    always #15.625 clk = ~clk;

    function [15:0] adc_word;
        input [7:0] frame_id;
        input [3:0] channel_id;
        begin
            // High nibble identifies this model; frame and channel are unique.
            adc_word = 16'hA000 | {4'h0, frame_id, channel_id};
        end
    endfunction

    ad7606c_pipelined_controller dut (
        .clk(clk), .rst(rst), .start(start), .stop(stop), .busy_i(busy),
        .db_i(db), .frstdata_i(frstdata_model),
        .adc_reset(adc_reset), .convst(convst), .cs_n(cs_n),
        .rd_n(rd_n), .db_oe(db_oe), .sample_data(sample_data),
        .sample_valid(sample_valid), .busy_timeout(busy_timeout),
        .frame_alignment_error(frame_alignment_error),
        .start_ready(start_ready), .capture_idle(capture_idle), .state(state)
    );

    // Simplified AD7606C timing model: each CONVST starts a conversion, BUSY
    // remains high for the rounded-up 650 ns conversion time, and the output
    // register changes only when BUSY falls. Each RD falling edge exposes the
    // next word V1..V8, with a distinct value for every frame and channel.
    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            busy_countdown <= 0;
            conversion_counter <= 8'd0;
            active_frame_id <= 8'd0;
            frstdata_model <= 1'b0;
        end else if (convst) begin
            if (busy || busy_countdown != 0)
                $fatal(1, "CONVST overlapped an unfinished ADC conversion");
            conversion_counter <= conversion_counter + 8'd1;
            active_frame_id <= conversion_counter + 8'd1;
            busy <= 1'b1;
            busy_countdown <= BUSY_HIGH_CYCLES;
        end else if (busy_countdown > 0) begin
            busy_countdown <= busy_countdown - 1;
            if (busy_countdown == 1)
                busy <= 1'b0;
        end
    end

    // BUSY falling publishes one completed frame and begins a fresh V1 index.
    always @(negedge busy) begin
        if (!rst) begin
            if (busy_fall_count > 0) begin
                if (reads_since_busy != 8)
                    $fatal(1, "next BUSY fall arrived after only %0d/8 reads",
                           reads_since_busy);
                if (cycle_count - last_busy_fall_cycle != 32)
                    $fatal(1, "BUSY falling interval %0d, expected 32 clocks",
                           cycle_count - last_busy_fall_cycle);
                if (cycle_count - last_rd_fall_cycle < 6)
                    $fatal(1,
                        "last RD falling edge has only %0d clocks before BUSY falls",
                        cycle_count - last_rd_fall_cycle);
                if (cycle_count - last_rd_fall_cycle < min_busy_margin_cycles)
                    min_busy_margin_cycles = cycle_count - last_rd_fall_cycle;
            end
            adc_output_frame_id = active_frame_id;
            expected_frame_id = active_frame_id;
            last_busy_fall_cycle = cycle_count;
            reads_since_busy = 0;
            busy_fall_count = busy_fall_count + 1;
        end
    end

    // On each RD edge, model the ADC's ordered parallel output register.
    always @(negedge rd_n) begin
        if (!rst) begin
            if (cs_n)
                $fatal(1, "RD asserted while CS was inactive");
            if (busy_fall_count == 0)
                $fatal(1, "RD started before the first completed conversion");
            if (reads_since_busy >= 8)
                $fatal(1, "more than eight RD pulses in one conversion frame");
            db_model = adc_word(adc_output_frame_id, reads_since_busy[3:0]);
            frstdata_model = (reads_since_busy == 0);
            reads_since_busy = reads_since_busy + 1;
            last_rd_fall_cycle = cycle_count;
        end
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (!rst) begin
            if (busy_timeout || frame_alignment_error)
                $fatal(1, "controller reported BUSY timeout or FRSTDATA frame misalignment");

            if (start) begin
                if (last_start_cycle >= 0 &&
                    cycle_count - last_start_cycle != 32)
                    $fatal(1, "start interval %0d, expected 32 clocks",
                           cycle_count - last_start_cycle);
                last_start_cycle = cycle_count;
                start_count = start_count + 1;
            end

            if (convst) begin
                if (last_convst_cycle >= 0 &&
                    cycle_count - last_convst_cycle != 32)
                    $fatal(1, "CONVST interval %0d, expected 32 clocks",
                           cycle_count - last_convst_cycle);
                last_convst_cycle = cycle_count;
                convst_count = convst_count + 1;
            end

            if (sample_valid) begin
                if (last_valid_cycle >= 0 &&
                    cycle_count - last_valid_cycle != 32)
                    $fatal(1, "sample interval %0d, expected 32 clocks",
                           cycle_count - last_valid_cycle);
                if (reads_since_busy != 8)
                    $fatal(1, "sample_valid with only %0d RD pulses",
                           reads_since_busy);
                if (expected_frame_id == 0)
                    $fatal(1, "sample_valid without a completed frame");

                for (channel = 0; channel < 8; channel = channel + 1) begin
                    if (sample_data[channel*16 +: 16] !==
                        adc_word(expected_frame_id[7:0], channel[3:0]))
                        $fatal(1,
                            "frame %0d channel V%0d mismatch: got %04h expected %04h",
                            expected_frame_id, channel + 1,
                            sample_data[channel*16 +: 16],
                            adc_word(expected_frame_id[7:0], channel[3:0]));
                end

                last_valid_cycle = cycle_count;
                valid_count = valid_count + 1;
                if (valid_count == NUM_CONVERSIONS) begin
                    if (start_count != NUM_CONVERSIONS ||
                        convst_count != NUM_CONVERSIONS ||
                        busy_fall_count != NUM_CONVERSIONS || busy_timeout ||
                        frame_alignment_error)
                        $fatal(1,
                            "count mismatch: start=%0d CONVST=%0d BUSYfall=%0d valid=%0d timeout=%0b",
                            start_count, convst_count, busy_fall_count,
                            valid_count, busy_timeout);
                    $display("PASS: %0d ordered V1..V8 frames at 1 MSPS; BUSY=%0d clocks, minimum last-RD margin=%0d clocks",
                             valid_count, BUSY_HIGH_CYCLES,
                             min_busy_margin_cycles);
                    $finish;
                end
            end
        end
    end

    // Match the frontend's 1 MHz sample cadence: one-cycle START every 32
    // system clocks. START remains accepted while the preceding frame is read.
    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);
        stop = 1'b0;

        for (i = 0; i < NUM_CONVERSIONS; i = i + 1) begin
            if (i > 0)
                repeat (31) @(negedge clk);
            if (!start_ready)
                $fatal(1, "controller not ready at 1 MSPS sample tick");
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    end

    initial begin
        #20000;
        $fatal(1, "simulation timeout");
    end
endmodule
