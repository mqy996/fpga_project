`timescale 1ns / 1ps
`default_nettype none
module arp_request_runtime #(
 parameter [47:0] LOCAL_MAC=48'h02_00_00_00_00_01,
 parameter integer RETRY_CYCLES=125000000
)(input wire clk,input wire rst,input wire enable,input wire arp_valid,input wire [31:0] local_ip,input wire [31:0] target_ip,
 output reg [7:0] tx_data,output reg tx_valid,input wire tx_ready,output reg tx_last);
 reg [31:0] timer;reg [5:0] idx;reg sending;
 always @(*) begin tx_valid=sending;tx_last=sending&&idx==59;tx_data=0;case(idx)
  0,1,2,3,4,5:tx_data=8'hff;6:tx_data=LOCAL_MAC[47:40];7:tx_data=LOCAL_MAC[39:32];8:tx_data=LOCAL_MAC[31:24];
  9:tx_data=LOCAL_MAC[23:16];10:tx_data=LOCAL_MAC[15:8];11:tx_data=LOCAL_MAC[7:0];12:tx_data=8'h08;13:tx_data=8'h06;
  14:tx_data=0;15:tx_data=1;16:tx_data=8'h08;17:tx_data=0;18:tx_data=6;19:tx_data=4;20:tx_data=0;21:tx_data=1;
  22:tx_data=LOCAL_MAC[47:40];23:tx_data=LOCAL_MAC[39:32];24:tx_data=LOCAL_MAC[31:24];25:tx_data=LOCAL_MAC[23:16];26:tx_data=LOCAL_MAC[15:8];27:tx_data=LOCAL_MAC[7:0];
  28:tx_data=local_ip[31:24];29:tx_data=local_ip[23:16];30:tx_data=local_ip[15:8];31:tx_data=local_ip[7:0];
  38:tx_data=target_ip[31:24];39:tx_data=target_ip[23:16];40:tx_data=target_ip[15:8];41:tx_data=target_ip[7:0];default:tx_data=0;endcase end
 always @(posedge clk)begin if(rst||!enable||arp_valid)begin timer<=0;idx<=0;sending<=0;end
  else if(sending&&tx_ready)begin if(tx_last)begin sending<=0;idx<=0;timer<=RETRY_CYCLES-1;end else idx<=idx+1'b1;end
  else if(!sending)begin if(timer==0)begin sending<=1;idx<=0;timer<=RETRY_CYCLES-1;end else timer<=timer-1'b1;end end
endmodule
`default_nettype wire
