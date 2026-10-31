`timescale 1ns / 1ps
module tb_led_status_blink;
 reg clk=0, rst=1, system_enable=1, capture_enable=1;
 wire system_led_n, capture_led_n;
 always #5 clk=~clk;
 led_status_blink #(.SYSTEM_HALF_PERIOD_CYCLES(4),.CAPTURE_HALF_PERIOD_CYCLES(2)) dut(
   .clk(clk), .rst(rst), .system_enable(system_enable), .capture_enable(capture_enable),
   .system_led_n(system_led_n), .capture_led_n(capture_led_n));
 task tick; begin @(posedge clk); #1; end endtask
 initial begin
   repeat(2) tick; if ({system_led_n,capture_led_n}!==2'b11) $fatal(1,"reset not off");
   rst=0; tick; if ({system_led_n,capture_led_n}!==2'b11) $fatal(1,"early toggle");
   tick; if ({system_led_n,capture_led_n}!==2'b10) $fatal(1,"capture cadence");
   tick;
   repeat(2) tick; if (system_led_n !== 1'b0) $fatal(1,"system cadence");
   capture_enable=0; #1; if ({system_led_n,capture_led_n}!==2'b01) $fatal(1,"capture gate");
   system_enable=0; #1; if ({system_led_n,capture_led_n}!==2'b11) $fatal(1,"system gate");
   $display("[TB][PASS] independent active-low LED cadences and gating"); $finish;
 end
 initial begin #1000; $fatal(1,"timeout"); end
endmodule
