`timescale 1ns/1ps
module tb_sample_rate_config_cdc;
    reg src_clk=0,dst_clk=0,src_rst=1,dst_rst=1,src_update=0;
    reg [31:0] src_rate=0; reg [7:0] src_div=0;
    wire src_busy; wire [31:0] dst_rate; wire [7:0] dst_div; wire dst_update;
    always #4 src_clk=~src_clk;
    always #7 dst_clk=~dst_clk;
    sample_rate_config_cdc dut(
        .src_clk(src_clk),.src_rst(src_rst),.src_update(src_update),
        .src_sample_rate(src_rate),.src_sample_div(src_div),.src_busy(src_busy),
        .dst_clk(dst_clk),.dst_rst(dst_rst),.dst_sample_rate(dst_rate),
        .dst_sample_div(dst_div),.dst_update(dst_update));
    task send_rate; input [31:0] r; input [7:0] d; begin
        @(posedge src_clk); src_rate<=r;src_div<=d;src_update<=1;
        @(posedge src_clk); src_update<=0;
    end endtask
    initial begin
        repeat(4) @(posedge src_clk); src_rst<=0; dst_rst<=0;
        send_rate(32'd250000,8'd128);
        wait(dst_update); #1;
        if(dst_rate!=32'd250000 || dst_div!=8'd128) $fatal(1,"250 kSPS CDC failed");
        repeat(4) @(posedge dst_clk);
        send_rate(32'd500000,8'd64);
        wait(dst_update); #1;
        if(dst_rate!=32'd500000 || dst_div!=8'd64) $fatal(1,"500 kSPS CDC failed");
        repeat(4) @(posedge dst_clk);
        send_rate(32'd1000000,8'd32);
        wait(dst_update); #1;
        if(dst_rate!=32'd1000000 || dst_div!=8'd32) $fatal(1,"1 MSPS CDC failed");
        $display("PASS: sample-rate coherent CDC"); $finish;
    end
    initial begin #100000 $fatal(1,"timeout"); end
endmodule
