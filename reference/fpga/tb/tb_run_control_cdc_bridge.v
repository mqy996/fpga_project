`timescale 1ns/1ps

module tb_run_control_cdc_bridge;
    reg src_clk = 0, dst_clk = 0;
    reg src_rst = 1, dst_rst = 1;
    reg src_start = 0, src_stop = 0;
    reg dst_done = 0;
    reg [3:0] dst_status = 0;
    wire src_busy, src_done;
    wire [3:0] src_status;
    wire dst_start_pulse, dst_stop_pulse;

    always #4 src_clk = ~src_clk;
    always #7 dst_clk = ~dst_clk;

    run_control_cdc_bridge dut (
        .src_clk(src_clk),.src_rst(src_rst),.src_start(src_start),.src_stop(src_stop),
        .src_busy(src_busy),.src_done(src_done),.src_status(src_status),
        .dst_clk(dst_clk),.dst_rst(dst_rst),.dst_start_pulse(dst_start_pulse),.dst_stop_pulse(dst_stop_pulse),
        .dst_done(dst_done),.dst_status(dst_status));

    task issue_start;
    begin
        @(negedge src_clk); src_start <= 1'b1;
        @(negedge src_clk); src_start <= 1'b0;
    end endtask
    task issue_stop;
    begin
        @(negedge src_clk); src_stop <= 1'b1;
        @(negedge src_clk); src_stop <= 1'b0;
    end endtask
    initial begin
        repeat (3) @(posedge src_clk); src_rst <= 0;
        repeat (3) @(posedge dst_clk); dst_rst <= 0;
        issue_start();
        wait (dst_start_pulse);
        if (dst_stop_pulse) $fatal(1, "START became STOP across CDC");
        wait (src_done);
        if (src_status != 0) $fatal(1, "START delivery was not acknowledged");
        wait (!src_busy);

        issue_stop();
        wait (dst_stop_pulse);
        if (dst_start_pulse) $fatal(1, "STOP became START across CDC");
        wait (src_done);
        if (src_status != 0) $fatal(1, "STOP delivery was not acknowledged");
        wait (!src_busy);
        $display("PASS: asynchronous START/STOP CDC delivery acknowledgement");
        $finish;
    end
    initial begin #20000; $fatal(1, "timeout"); end
endmodule
