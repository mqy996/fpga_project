`timescale 1ns / 1ps
`default_nettype none

// Coherent boot/save transfers between the 32 MHz flash domain and 125 MHz
// control domain.  No multi-bit configuration bus is sampled directly.
module flash_config_cdc_bridge(
 input wire clk32,input wire rst32,input wire clk125,input wire rst125,
 input wire flash_boot_done,input wire [223:0] flash_active_config,
 input wire flash_config_from_flash,input wire [31:0] flash_active_sequence,input wire [1:0] flash_active_copy_32,
 output wire boot_config_valid,output wire boot_config_ready,
 output wire [223:0] boot_config,
 output wire boot_from_flash,output wire [31:0] boot_sequence,output wire [1:0] boot_copy,
 input wire save_req_125,input wire [223:0] save_config_125,
 output wire flash_save_req_32,output wire [223:0] flash_save_config_32,
 input wire flash_save_done_32,input wire [3:0] flash_save_status_32,
 input wire [31:0] flash_sequence_32,input wire [1:0] flash_copy_32,
 output wire save_result_valid_125,output wire [3:0] save_status_125,
 output wire [31:0] save_sequence_125,output wire [1:0] save_copy_125
);
 reg boot_done_d;
 always @(posedge clk32) begin
   if(rst32) boot_done_d<=0;
   else boot_done_d<=flash_boot_done;
 end
 wire boot_done_rise = flash_boot_done && !boot_done_d;
 flash_cdc_transfer #(.WIDTH(259)) u_boot(
 .src_clk(clk32),.src_rst(rst32),.src_pulse(boot_done_rise),
 .src_data({flash_config_from_flash,flash_active_sequence,flash_active_copy_32,flash_active_config}),
 .dst_clk(clk125),.dst_rst(rst125),.dst_pulse(boot_config_valid),
 .dst_data({boot_from_flash,boot_sequence,boot_copy,boot_config}),.dst_complete(boot_config_valid));
 reg boot_ready_reg;
 always @(posedge clk125) begin
   if(rst125) boot_ready_reg<=1'b0;
   else if(boot_config_valid) boot_ready_reg<=1'b1;
 end
 assign boot_config_ready = boot_ready_reg;
 flash_cdc_transfer #(.WIDTH(224)) u_save_req(
 .src_clk(clk125),.src_rst(rst125),.src_pulse(save_req_125),.src_data(save_config_125),
 .dst_clk(clk32),.dst_rst(rst32),.dst_pulse(flash_save_req_32),
 .dst_data(flash_save_config_32),.dst_complete(flash_save_done_32));
 flash_cdc_transfer #(.WIDTH(38)) u_save_result(
 .src_clk(clk32),.src_rst(rst32),.src_pulse(flash_save_done_32),
 .src_data({flash_save_status_32,flash_sequence_32,flash_copy_32}),
 .dst_clk(clk125),.dst_rst(rst125),.dst_pulse(save_result_valid_125),
 .dst_data({save_status_125,save_sequence_125,save_copy_125}),.dst_complete(save_result_valid_125));
endmodule

// Convert a source pulse to a complete four-phase XPM handshake. Public
// destination valid is one cycle. A pending slot covers return-to-zero latency;
// the caller must allow only one outstanding flash operation.
module flash_cdc_transfer #(parameter integer WIDTH=1)(
 input wire src_clk,src_rst,src_pulse,input wire [WIDTH-1:0] src_data,
 input wire dst_clk,dst_rst,dst_complete,
 output wire dst_pulse,output wire [WIDTH-1:0] dst_data
);
 reg pending,send;
 reg [WIDTH-1:0] pending_data,held_data;
 wire received,request;
 reg seen,ack;
 always @(posedge src_clk) begin
   if(src_rst)begin pending<=0;send<=0;pending_data<=0;held_data<=0;end
   else begin
     if(send)begin if(received)send<=0;end
     else if(!received && pending)begin
       held_data<=pending_data;send<=1;pending<=0;
     end
     if(src_pulse)begin pending_data<=src_data;pending<=1;end
   end
 end
 assign dst_pulse=request&&!seen&&!dst_rst;
 always @(posedge dst_clk) begin
   if(dst_rst)begin seen<=0;ack<=0;end
   else if(!request)begin seen<=0;ack<=0;end
   else begin
     if(dst_pulse)seen<=1;
     if(dst_complete)ack<=1;
   end
 end
 xpm_cdc_handshake #(.DEST_EXT_HSK(1),.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),
 .SIM_ASSERT_CHK(1),.SRC_SYNC_FF(2),.WIDTH(WIDTH)) u_handshake(
 .src_clk(src_clk),.src_in(held_data),.src_send(send),.src_rcv(received),
 .dest_clk(dst_clk),.dest_out(dst_data),.dest_req(request),.dest_ack(ack));
endmodule
`default_nettype wire
