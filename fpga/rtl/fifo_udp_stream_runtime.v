`timescale 1ns / 1ps
`default_nettype none
module fifo_udp_stream_runtime #(
 parameter [47:0] SRC_MAC=48'h02_00_00_00_00_01
)(
 input wire clk,input wire rst,input wire enable,input wire session_reset,
 input wire [31:0] src_ip,
 input wire [47:0] dst_mac,input wire [31:0] dst_ip,input wire [15:0] dst_port,
 input wire [31:0] sample_rate,input wire [31:0] channel_mask,input wire [5:0] groups_per_packet,
 input wire [15:0] payload_length,input wire [383:0] fifo_data,input wire fifo_empty,input wire [9:0] fifo_count,
 output wire fifo_rd_en,output wire [7:0] tx_data,output wire tx_valid,input wire tx_ready,output wire tx_last,
 output wire busy,output reg [31:0] packets_started,output reg [31:0] packets_completed,output reg [31:0] sequence_number
);
 reg start; wire pbusy,fbusy;wire [7:0] pdata;wire pvalid,pready,plast;
 wire done=tx_valid&&tx_ready&&tx_last;
 assign busy=pbusy||fbusy;
 always @(posedge clk) begin
  if(rst||session_reset) begin start<=0;packets_started<=0;packets_completed<=0;sequence_number<=1;end
  else begin start<=0;if(done) begin packets_completed<=packets_completed+1'b1;sequence_number<=sequence_number+1'b1;end
   // start is registered, so explicitly exclude the cycle in which it is
   // already high. The downstream blocks enter busy on that edge; without
   // this guard the diagnostic started counter increments twice per frame.
   if(enable&&!start&&!pbusy&&!fbusy&&fifo_count>=groups_per_packet) begin start<=1;packets_started<=packets_started+1'b1;end
  end
 end
 fifo_udp_payload_runtime u_payload(.clk(clk),.rst(rst||session_reset),.start(start),.sequence_number(sequence_number),
  .sample_rate(sample_rate),.channel_mask(channel_mask),.groups_per_packet(groups_per_packet),.busy(pbusy),
  .fifo_data(fifo_data),.fifo_empty(fifo_empty),.fifo_rd_en(fifo_rd_en),.data(pdata),.valid(pvalid),.ready(pready),.last(plast));
 udp_ipv4_tx_runtime #(.SRC_MAC(SRC_MAC)) u_frame(.clk(clk),.rst(rst||session_reset),.start(start),.src_ip(src_ip),
  .dst_mac(dst_mac),.dst_ip(dst_ip),.src_port(16'd56555),.dst_port(dst_port),.payload_length(payload_length),.busy(fbusy),
  .payload_data(pdata),.payload_valid(pvalid),.payload_ready(pready),.payload_last(plast),
  .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_last(tx_last));
endmodule
`default_nettype wire
