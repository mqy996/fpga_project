`timescale 1ns / 1ps
`default_nettype none

// Four-input, frame-locked byte-stream arbiter.  A single mux replaces the
// former three-level arbiter cascade, shortening the 125 MHz transmit path.
// Priority when idle is s0, s1, s2, then s3.  Ownership cannot change until
// the selected source completes its last-byte handshake.
module frame_arbiter_4to1(
 input wire clk,input wire rst,
 input wire [7:0] s0_data,input wire s0_valid,output wire s0_ready,input wire s0_last,
 input wire [7:0] s1_data,input wire s1_valid,output wire s1_ready,input wire s1_last,
 input wire [7:0] s2_data,input wire s2_valid,output wire s2_ready,input wire s2_last,
 input wire [7:0] s3_data,input wire s3_valid,output wire s3_ready,input wire s3_last,
 output reg [7:0] m_data,output reg m_valid,input wire m_ready,output reg m_last,
 output wire [2:0] owner
);
 localparam NONE=3'd0,S0=3'd1,S1=3'd2,S2=3'd3,S3=3'd4;
 reg [2:0] held_owner;
 wire [2:0] selected=(held_owner!=NONE)?held_owner:
                     s0_valid?S0:s1_valid?S1:s2_valid?S2:s3_valid?S3:NONE;
 assign owner=selected;
 assign s0_ready=(selected==S0)&&m_ready;
 assign s1_ready=(selected==S1)&&m_ready;
 assign s2_ready=(selected==S2)&&m_ready;
 assign s3_ready=(selected==S3)&&m_ready;
 always @(*) begin
  m_data=0;m_valid=0;m_last=0;
  case(selected)
   S0:begin m_data=s0_data;m_valid=s0_valid;m_last=s0_last;end
   S1:begin m_data=s1_data;m_valid=s1_valid;m_last=s1_last;end
   S2:begin m_data=s2_data;m_valid=s2_valid;m_last=s2_last;end
   S3:begin m_data=s3_data;m_valid=s3_valid;m_last=s3_last;end
   default:begin m_data=0;m_valid=0;m_last=0;end
  endcase
 end
 always @(posedge clk) begin
  if(rst)held_owner<=NONE;
  else begin
   if(held_owner==NONE&&selected!=NONE)held_owner<=selected;
   if(m_valid&&m_ready&&m_last)held_owner<=NONE;
  end
 end
endmodule
`default_nettype wire
