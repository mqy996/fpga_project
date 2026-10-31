`timescale 1ns / 1ps
`default_nettype none
module control_response_tx_runtime #(
 parameter [47:0] LOCAL_MAC=48'h02_00_00_00_00_01,
 parameter [31:0] DEVICE_ID=1,parameter [31:0] FW_VERSION=32'h0002_0000,
 parameter [31:0] HW_VERSION=32'h0001_0000
)(
 input wire clk,input wire rst,input wire start,
 input wire [47:0] dst_mac,input wire [31:0] dst_ip,input wire [15:0] dst_port,
 input wire [31:0] local_ip,input wire [31:0] netmask,
 input wire [31:0] cmd,input wire [31:0] status,input wire [31:0] transaction_id,input wire [15:0] data_length,
 input wire [31:0] device_state,input wire [31:0] target_ip,input wire [15:0] target_port,
 input wire [31:0] sample_rate,input wire [31:0] channel_mask,input wire [31:0] groups_per_packet,
 input wire [15:0] payload_length,input wire arp_valid,input wire [47:0] learned_mac,
 input wire config_from_flash,input wire [31:0] config_sequence,
 input wire [23:0] jedec_id,input wire [1:0] active_copy,input wire flash_error,
 input wire [7:0] flash_error_code,input wire flash_busy,
 input wire [31:0] packets_sent,input wire [9:0] fifo_level,input wire adc_error,
 output wire [7:0] tx_data,output wire tx_valid,input wire tx_ready,output wire tx_last,
 output wire busy,output wire done
);
 reg active,frame_start;reg [7:0] idx;reg [15:0] total,frame_payload_length;reg [31:0] rcmd,rstatus,rtid;
 wire payload_ready;wire payload_last=active&&(idx==total-1'b1);wire [7:0] payload_data;
 function [7:0] wb;input [31:0] w;input [1:0] n;begin case(n)0:wb=w[31:24];1:wb=w[23:16];2:wb=w[15:8];default:wb=w[7:0];endcase end endfunction
 reg [7:0] pv;
 always @(*)begin
  pv=0;
  if(idx<4)pv=wb(rcmd,idx[1:0]);else if(idx<8)pv=wb(rstatus,idx[1:0]);
  else if(idx<12)pv=wb({16'd0,total-16},idx[1:0]);else if(idx<16)pv=wb(rtid,idx[1:0]);
  else case(rcmd)
   32'h80000001:case(idx-16)
    0,1,2,3:pv=wb(DEVICE_ID,(idx-16)&3);4,5,6,7:pv=wb(FW_VERSION,(idx-20)&3);
    8,9,10,11:pv=wb(HW_VERSION,(idx-24)&3);12,13,14,15:pv=wb(device_state,(idx-28)&3);
    16,17,18,19:pv=wb(local_ip,(idx-32)&3);20,21,22,23:pv=wb(netmask,(idx-36)&3);
    24:pv=target_port[15:8];25:pv=target_port[7:0];26:pv=8'hdc;27:pv=8'hec;
    28:pv=LOCAL_MAC[47:40];29:pv=LOCAL_MAC[39:32];30:pv=LOCAL_MAC[31:24];31:pv=LOCAL_MAC[23:16];default:pv=0;endcase
   32'h80000002:case(idx-16)
    0,1,2,3:pv=wb(DEVICE_ID,(idx-16)&3);4,5,6,7:pv=wb(FW_VERSION,(idx-20)&3);
    8,9,10,11:pv=wb(HW_VERSION,(idx-24)&3);12,13,14,15:pv=wb(device_state,(idx-28)&3);
    16,17,18,19:pv=wb(local_ip,(idx-32)&3);20,21,22,23:pv=wb(netmask,(idx-36)&3);
    24,25,26,27:pv=wb(target_ip,(idx-40)&3);28:pv=target_port[15:8];29:pv=target_port[7:0];30:pv=8'hdc;31:pv=8'hec;
    32,33,34,35:pv=wb(sample_rate,(idx-48)&3);36,37,38,39:pv=wb(channel_mask,(idx-52)&3);
    40,41,42,43:pv=wb(groups_per_packet,(idx-56)&3);44:pv=payload_length[15:8];45:pv=payload_length[7:0];
    48,49,50,51:pv=wb({31'd0,arp_valid},(idx-64)&3);
    52:pv=learned_mac[47:40];53:pv=learned_mac[39:32];54:pv=learned_mac[31:24];55:pv=learned_mac[23:16];56:pv=learned_mac[15:8];57:pv=learned_mac[7:0];
    60,61,62,63:pv=wb(config_sequence,(idx-76)&3);64,65,66,67:pv=wb({31'd0,config_from_flash},(idx-80)&3);
    68,69,70,71:pv=wb({29'd0,adc_error,flash_error,flash_busy},(idx-84)&3);default:pv=0;endcase
   32'h80000003,32'h80000007,32'h80000009:case(idx-16)
    0,1,2,3:pv=wb(local_ip,(idx-16)&3);4,5,6,7:pv=wb(netmask,(idx-20)&3);
    8,9,10,11:pv=wb(target_ip,(idx-24)&3);12:pv=target_port[15:8];13:pv=target_port[7:0];14,15:pv=0;
    16,17,18,19:pv=wb(sample_rate,(idx-32)&3);20,21,22,23:pv=wb(channel_mask,(idx-36)&3);
    24,25,26,27:pv=wb(groups_per_packet,(idx-40)&3);28,29,30,31:pv=wb({31'd0,config_from_flash},(idx-44)&3);
    32,33,34,35:pv=wb(config_sequence,(idx-48)&3);36:pv=payload_length[15:8];37:pv=payload_length[7:0];default:pv=0;endcase
   32'h80000006:case(idx-16)
    0,1,2,3:pv=wb(device_state,(idx-16)&3);4,5,6,7:pv=wb(packets_sent,(idx-20)&3);
    8,9,10,11:pv=wb({22'd0,fifo_level},(idx-24)&3);12,13,14,15:pv=wb({31'd0,arp_valid},(idx-28)&3);
    16,17,18,19:pv=wb({31'd0,flash_busy},(idx-32)&3);20,21,22,23:pv=wb({31'd0,flash_error},(idx-36)&3);
    24,25,26,27:pv=wb({24'd0,flash_error_code},(idx-40)&3);28,29,30,31:pv=wb({31'd0,adc_error},(idx-44)&3);
    32,33,34,35:pv=wb(local_ip,(idx-48)&3);36,37,38,39:pv=wb(target_ip,(idx-52)&3);
    40,41,42,43:pv=wb(config_sequence,(idx-56)&3);44,45,46,47:pv=wb({30'd0,active_copy},(idx-60)&3);default:pv=0;endcase
   32'h80000008:case(idx-16)
    0,1,2,3:pv=wb(config_sequence,(idx-16)&3);4,5,6,7:pv=wb({30'd0,active_copy},(idx-20)&3);
    8,9,10,11:pv=wb({23'd0,flash_error_code,flash_error},(idx-24)&3);default:pv=0;endcase
   32'h8000000a:case(idx-16)
    0,1,2,3:pv=wb({8'd0,jedec_id},(idx-16)&3);4,5,6,7:pv=wb({30'd0,active_copy},(idx-20)&3);
    8,9,10,11:pv=wb(config_sequence,(idx-24)&3);12,13,14,15:pv=wb({31'd0,flash_error},(idx-28)&3);
    16,17,18,19:pv=wb({24'd0,flash_error_code},(idx-32)&3);20,21,22,23:pv=wb({31'd0,flash_busy},(idx-36)&3);default:pv=0;endcase
   default:pv=0;
  endcase
 end
 assign payload_data=pv;assign done=tx_valid&&tx_ready&&tx_last;
 always @(posedge clk)begin if(rst)begin active<=0;frame_start<=0;idx<=0;total<=0;frame_payload_length<=0;rcmd<=0;rstatus<=0;rtid<=0;end else begin frame_start<=0;
  if(start&&!active)begin active<=1;frame_start<=1;idx<=0;total<=16+data_length;frame_payload_length<=16+data_length;rcmd<=cmd|32'h80000000;rstatus<=status;rtid<=transaction_id;end
  else if(active&&payload_ready)begin if(payload_last)active<=0;else idx<=idx+1'b1;end end end
 udp_ipv4_tx_runtime #(.SRC_MAC(LOCAL_MAC))u_udp(.clk(clk),.rst(rst),.start(frame_start),.src_ip(local_ip),
  .dst_mac(dst_mac),.dst_ip(dst_ip),.src_port(16'd56556),.dst_port(dst_port),.payload_length(frame_payload_length),.busy(busy),
  .payload_data(payload_data),.payload_valid(active),.payload_ready(payload_ready),.payload_last(payload_last),
  .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_last(tx_last));
endmodule
`default_nettype wire
