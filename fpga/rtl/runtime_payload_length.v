`timescale 1ns/1ps
`default_nettype none
// Active configuration has already been validated (1..30 groups, 1..24 CH).
// Two clocks to settle; configuration apply re-arms ARP/FIFO before streaming.
(* use_dsp = "no" *)
module runtime_payload_length(input wire clk,rst,
 input wire [23:0] channel_mask,input wire [4:0] groups,
 output reg [15:0] length);
 reg [4:0] channel_count,groups_d;
 wire [9:0] sample_count=channel_count*groups_d;
 function [4:0] count_channels;
   input [23:0] mask;integer i;
   begin count_channels=0;for(i=0;i<24;i=i+1)count_channels=count_channels+mask[i];end
 endfunction
 always @(posedge clk)begin
   if(rst)begin channel_count<=24;groups_d<=30;length<=1452;end
   else begin
     channel_count<=count_channels(channel_mask);groups_d<=groups;
     length<=16'd12+{5'd0,sample_count,1'b0};
   end
 end
endmodule
`default_nettype wire
