`timescale 1ns / 1ps
`default_nettype none

// One-byte elastic register.  It sustains one byte per clock while breaking
// the source/arbiter decode path away from the MAC CRC combinational path.
module stream_pipeline(
 input wire clk,input wire rst,
 input wire [7:0] s_data,input wire s_valid,output wire s_ready,input wire s_last,
 output wire [7:0] m_data,output wire m_valid,input wire m_ready,output wire m_last
);
 reg [7:0] data_reg;reg valid_reg;reg last_reg;
 assign s_ready=!valid_reg||m_ready;
 assign m_data=data_reg;assign m_valid=valid_reg;assign m_last=last_reg;
 always @(posedge clk)begin
  if(rst)begin data_reg<=0;valid_reg<=0;last_reg<=0;end
  else if(s_ready)begin
   valid_reg<=s_valid;
   if(s_valid)begin data_reg<=s_data;last_reg<=s_last;end
  end
 end
endmodule
`default_nettype wire
