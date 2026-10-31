`timescale 1ns / 1ps
`default_nettype none
module cdc_pulse_sync(input wire src_clk,input wire src_rst,input wire src_pulse,
 input wire dst_clk,input wire dst_rst,output reg dst_pulse);
 reg src_toggle;
 (* ASYNC_REG="TRUE" *) reg dst_ff1,dst_ff2;
 reg dst_seen;
 always @(posedge src_clk)begin if(src_rst)src_toggle<=0;else if(src_pulse)src_toggle<=~src_toggle;end
 always @(posedge dst_clk)begin
  if(dst_rst)begin dst_ff1<=0;dst_ff2<=0;dst_seen<=0;dst_pulse<=0;end
  else begin dst_ff1<=src_toggle;dst_ff2<=dst_ff1;dst_pulse<=dst_ff2^dst_seen;if(dst_ff2!=dst_seen)dst_seen<=dst_ff2;end
 end
endmodule
`default_nettype wire
