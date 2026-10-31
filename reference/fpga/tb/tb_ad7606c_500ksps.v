`timescale 1ns/1ps

// Regression for the former duplicated 64-cycle sampling limiter.
// The top-level scheduler presents one request every 64 clk cycles.  Every
// request must be accepted because the modeled conversion/readout finishes
// before the next request.
module tb_ad7606c_500ksps;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg stop = 1'b0;
    reg busy = 1'b0;
    reg [15:0] db = 16'h1234;
    wire convst;
    wire sample_valid;
    wire [127:0] sample_data;
    wire adc_reset, cs_n, rd_n, db_oe, busy_timeout;
    wire [3:0] state;

    integer cycle = 0;
    integer tick_count = 0;
    integer convst_count = 0;
    integer valid_count = 0;
    integer last_convst_cycle = -1;
    integer last_valid_cycle = -1;
    integer busy_delay = -1;
    integer busy_high_left = 0;
    reg [5:0] scheduler_count = 6'd0;

    always #15.625 clk = ~clk; // 32 MHz

    ad7606c_parallel_controller #(
        .RESET_CYCLES(2), .SETUP_CYCLES(2),
        .CONVST_HIGH_CYCLES(1), .CS_SETUP_CYCLES(1),
        .RD_LOW_CYCLES(2), .RD_INTERVAL_CYCLES(1),
        .BUSY_TIMEOUT_CYCLES(64)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .stop(stop),
        .busy_i(busy), .db_i(db), .adc_reset(adc_reset),
        .convst(convst), .cs_n(cs_n), .rd_n(rd_n), .db_oe(db_oe),
        .sample_data(sample_data), .sample_valid(sample_valid),
        .busy_timeout(busy_timeout), .state(state)
    );

    always @(posedge clk) begin
        cycle <= cycle + 1;
        start <= 1'b0;

        if (!rst && state == 4'd2 && tick_count == 0) begin
            // Align the first scheduler request to an idle controller.
            start <= 1'b1;
            tick_count <= 1;
            scheduler_count <= 6'd0;
        end else if (!rst && tick_count > 0 && tick_count < 6) begin
            if (scheduler_count == 6'd63) begin
                start <= 1'b1;
                tick_count <= tick_count + 1;
                scheduler_count <= 6'd0;
            end else begin
                scheduler_count <= scheduler_count + 1'b1;
            end
        end

        if (convst) begin
            if (last_convst_cycle >= 0 &&
                cycle - last_convst_cycle != 64)
                $fatal(1, "CONVST interval is %0d cycles, expected 64",
                       cycle - last_convst_cycle);
            last_convst_cycle <= cycle;
            convst_count <= convst_count + 1;
            busy_delay <= 2;
        end

        if (busy_delay > 0)
            busy_delay <= busy_delay - 1;
        else if (busy_delay == 0) begin
            busy <= 1'b1;
            busy_high_left <= 8;
            busy_delay <= -1;
        end
        if (busy_high_left > 0) begin
            busy_high_left <= busy_high_left - 1;
            if (busy_high_left == 1)
                busy <= 1'b0;
        end

        if (sample_valid) begin
            if (last_valid_cycle >= 0 && cycle - last_valid_cycle != 64)
                $fatal(1, "sample_valid interval is %0d cycles, expected 64",
                       cycle - last_valid_cycle);
            last_valid_cycle <= cycle;
            valid_count <= valid_count + 1;
        end

        if (valid_count == 5) begin
            if (convst_count != 5 || busy_timeout)
                $fatal(1, "unexpected counts or timeout");
            $display("PASS: actual ADC conversions complete every 64 cycles (500 kSPS)");
            $finish;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
    end

    initial begin
        #100000;
        $fatal(1, "timeout");
    end
endmodule
