`timescale 1ns / 1ps
`default_nettype none

// Parallel observer for control UDP frames. It publishes one stable descriptor
// only after Ethernet FCS, IPv4 checksum, UDP length and UDP checksum pass.
module control_udp_rx_runtime #(
 parameter [47:0] LOCAL_MAC=48'h02_00_00_00_00_01,
 parameter [15:0] CONTROL_PORT=16'd56556
)(
 input wire rx_clk,input wire rx_rst,input wire frame_start,
 input wire [31:0] local_ip,input wire [31:0] netmask,
 input wire [7:0] data,input wire valid,
 output reg request_send,input wire request_received,
 output reg [47:0] src_mac,output reg [31:0] src_ip,output reg [15:0] src_port,
 output reg [31:0] cmd,output reg [31:0] status,output reg [31:0] length,output reg [31:0] transaction_id,
 output reg [31:0] cfg_local_ip,output reg [31:0] cfg_netmask,
 output reg [31:0] cfg_dst_ip,output reg [15:0] cfg_dst_port,output reg [15:0] cfg_reserved0,
 output reg [31:0] cfg_sample_rate,output reg [31:0] cfg_channel_mask,output reg [31:0] cfg_groups_per_packet,
 output reg [63:0] cfg_reserved1,
 output reg [31:0] diag_frames,output reg [31:0] diag_fcs_good,output reg [31:0] diag_ipv4_good,
 output reg [31:0] diag_control_udp_good,output reg [31:0] diag_commands_published,output reg [31:0] diag_busy_drops
);
 localparam IDLE=0,FRAME=1; localparam [31:0] CRC_RESIDUE=32'hDEBB20E3;
 reg state;reg [10:0] idx;reg [31:0] crc;wire [31:0] crc_next;
 eth_crc32 u_crc(.crc_in(crc),.data_in(data),.crc_out(crc_next));
 reg [47:0] dmac,smac;reg [15:0] etype,iplen,ipflags;reg [7:0] ihl,proto;
 reg [31:0] sip,dip;reg [15:0] sport,dport,ulen,ucsum;
 reg [7:0] ip_hi,udp_hi;reg [31:0] ip_sum,udp_sum,udp_total,udp_fold1,udp_fold2;reg [1:0] udp_stage;reg ip_ok,udp_ok;
 reg [31:0] c_cmd,c_status,c_len,c_tid,c_lip,c_nmask,c_dip,c_rate,c_mask,c_gpp;
 reg [15:0] c_dport,c_res0;reg [63:0] c_res1;
 reg request_pending;wire busy=request_pending;
 reg [31:0] temp;
 function [15:0] fold;input [31:0] x;reg [31:0] y;begin y=x[15:0]+x[31:16];y=y[15:0]+y[31:16];fold=y[15:0];end endfunction
 always @(posedge rx_clk) begin
  if(rx_rst) begin state<=IDLE;idx<=0;crc<=32'hffffffff;request_send<=0;request_pending<=0;
   dmac<=0;smac<=0;etype<=0;iplen<=0;ipflags<=0;ihl<=0;proto<=0;sip<=0;dip<=0;
   sport<=0;dport<=0;ulen<=0;ucsum<=0;ip_hi<=0;udp_hi<=0;ip_sum<=0;udp_sum<=0;udp_total<=0;udp_fold1<=0;udp_fold2<=0;udp_stage<=0;ip_ok<=0;udp_ok<=0;
   c_cmd<=0;c_status<=0;c_len<=0;c_tid<=0;c_lip<=0;c_nmask<=0;c_dip<=0;c_dport<=0;c_res0<=0;c_rate<=0;c_mask<=0;c_gpp<=0;c_res1<=0;
   src_mac<=0;src_ip<=0;src_port<=0;cmd<=0;status<=0;length<=0;transaction_id<=0;
   cfg_local_ip<=0;cfg_netmask<=0;cfg_dst_ip<=0;cfg_dst_port<=0;cfg_reserved0<=0;cfg_sample_rate<=0;cfg_channel_mask<=0;cfg_groups_per_packet<=0;cfg_reserved1<=0;
   diag_frames<=0;diag_fcs_good<=0;diag_ipv4_good<=0;diag_control_udp_good<=0;diag_commands_published<=0;diag_busy_drops<=0;
  end else begin
   // xpm_cdc_handshake requires src_send to remain asserted from the time
   // this descriptor is published until src_rcv acknowledges it.  A one-RXC
   // cycle pulse is explicitly not a legal source handshake and was the
   // cause of the intermittent control-port stall.
   if(request_received)begin
    request_pending<=0;
    request_send<=0;
   end
   case(state)
   IDLE:if(frame_start) begin state<=FRAME;diag_frames<=diag_frames+1'b1;idx<=0;crc<=32'hffffffff;ip_sum<=0;udp_sum<=0;udp_total<=0;udp_fold1<=0;udp_fold2<=0;udp_stage<=0;ip_ok<=0;udp_ok<=0;
    dmac<=0;smac<=0;etype<=0;iplen<=0;ipflags<=0;ihl<=0;proto<=0;sip<=0;dip<=0;sport<=0;dport<=0;ulen<=0;ucsum<=0;
    c_cmd<=0;c_status<=0;c_len<=0;c_tid<=0;c_lip<=0;c_nmask<=0;c_dip<=0;c_dport<=0;c_res0<=0;c_rate<=0;c_mask<=0;c_gpp<=0;c_res1<=0;end
   FRAME:begin
    if(valid) begin
     crc<=crc_next;idx<=idx+1'b1;
     case(idx)
      0:dmac[47:40]<=data;1:dmac[39:32]<=data;2:dmac[31:24]<=data;3:dmac[23:16]<=data;4:dmac[15:8]<=data;5:dmac[7:0]<=data;
      6:smac[47:40]<=data;7:smac[39:32]<=data;8:smac[31:24]<=data;9:smac[23:16]<=data;10:smac[15:8]<=data;11:smac[7:0]<=data;
      12:etype[15:8]<=data;13:etype[7:0]<=data;14:ihl<=data;16:iplen[15:8]<=data;17:iplen[7:0]<=data;
      20:ipflags[15:8]<=data;21:ipflags[7:0]<=data;23:proto<=data;
      26:sip[31:24]<=data;27:sip[23:16]<=data;28:sip[15:8]<=data;29:sip[7:0]<=data;
      30:dip[31:24]<=data;31:dip[23:16]<=data;32:dip[15:8]<=data;33:dip[7:0]<=data;
      34:sport[15:8]<=data;35:sport[7:0]<=data;36:dport[15:8]<=data;37:dport[7:0]<=data;
      38:ulen[15:8]<=data;39:ulen[7:0]<=data;40:ucsum[15:8]<=data;41:ucsum[7:0]<=data;
      42:c_cmd[31:24]<=data;43:c_cmd[23:16]<=data;44:c_cmd[15:8]<=data;45:c_cmd[7:0]<=data;
      46:c_status[31:24]<=data;47:c_status[23:16]<=data;48:c_status[15:8]<=data;49:c_status[7:0]<=data;
      50:c_len[31:24]<=data;51:c_len[23:16]<=data;52:c_len[15:8]<=data;53:c_len[7:0]<=data;
      54:c_tid[31:24]<=data;55:c_tid[23:16]<=data;56:c_tid[15:8]<=data;57:c_tid[7:0]<=data;
      58:c_lip[31:24]<=data;59:c_lip[23:16]<=data;60:c_lip[15:8]<=data;61:c_lip[7:0]<=data;
      62:c_nmask[31:24]<=data;63:c_nmask[23:16]<=data;64:c_nmask[15:8]<=data;65:c_nmask[7:0]<=data;
      66:c_dip[31:24]<=data;67:c_dip[23:16]<=data;68:c_dip[15:8]<=data;69:c_dip[7:0]<=data;
      70:c_dport[15:8]<=data;71:c_dport[7:0]<=data;72:c_res0[15:8]<=data;73:c_res0[7:0]<=data;
      74:c_rate[31:24]<=data;75:c_rate[23:16]<=data;76:c_rate[15:8]<=data;77:c_rate[7:0]<=data;
      78:c_mask[31:24]<=data;79:c_mask[23:16]<=data;80:c_mask[15:8]<=data;81:c_mask[7:0]<=data;
      82:c_gpp[31:24]<=data;83:c_gpp[23:16]<=data;84:c_gpp[15:8]<=data;85:c_gpp[7:0]<=data;
      default:;
     endcase
     if(idx>=14&&idx<=33) begin if(!idx[0]) ip_hi<=data;else begin temp=ip_sum+{ip_hi,data};ip_sum<=temp;if(idx==33)ip_ok<=fold(temp)==16'hffff;end end
     if(udp_stage==1)begin udp_fold1<=udp_total[15:0]+udp_total[31:16];udp_stage<=2;end
     else if(udp_stage==2)begin udp_fold2<=udp_fold1[15:0]+udp_fold1[31:16];udp_stage<=3;end
     else if(udp_stage==3)begin udp_ok<=udp_fold2[15:0]==16'hffff;udp_stage<=0;end
     if(idx>=34&&idx<(34+iplen-20)) begin
      if(!idx[0]) udp_hi<=data; else udp_sum<=udp_sum+{udp_hi,data};
      if(idx==(34+iplen-20-1)) begin
       if(!idx[0]) temp=udp_sum+{data,8'h00};else temp=udp_sum+{udp_hi,data};
       udp_total<=temp+sip[31:16]+sip[15:0]+dip[31:16]+dip[15:0]+16'h0011+ulen;
       udp_stage<=1;
      end
     end
    end else begin
     if(crc==CRC_RESIDUE)diag_fcs_good<=diag_fcs_good+1'b1;
     if(crc==CRC_RESIDUE&&etype==16'h0800&&ihl==8'h45&&proto==8'h11&&(ipflags&16'h3fff)==0&&ip_ok&&iplen>=44&&iplen<=72)
      diag_ipv4_good<=diag_ipv4_good+1'b1;
     if(crc==CRC_RESIDUE&&etype==16'h0800&&ihl==8'h45&&proto==8'h11&&(ipflags&16'h3fff)==0&&ip_ok&&iplen>=44&&iplen<=72&&
        ulen==iplen-20&&ulen>=24&&ulen<=52&&dport==CONTROL_PORT&&(dmac==LOCAL_MAC||dmac==48'hffffffffffff)&&
        (dip==local_ip||dip==32'hffffffff||dip==(local_ip|~netmask))&&c_status==0&&c_len==ulen-24&&(ucsum==0||udp_ok))
      diag_control_udp_good<=diag_control_udp_good+1'b1;
     if(!busy&&crc==CRC_RESIDUE&&etype==16'h0800&&ihl==8'h45&&proto==8'h11&&
        (ipflags&16'h3fff)==0&&ip_ok&&iplen>=44&&iplen<=72&&ulen==iplen-20&&ulen>=24&&ulen<=52&&
        dport==CONTROL_PORT&&(dmac==LOCAL_MAC||dmac==48'hffffffffffff)&&
        (dip==local_ip||dip==32'hffffffff||dip==(local_ip|~netmask))&&
        c_status==0&&c_len==ulen-24&&(ucsum==0||udp_ok)) begin
       src_mac<=smac;src_ip<=sip;src_port<=sport;cmd<=c_cmd;status<=c_status;length<=c_len;transaction_id<=c_tid;
       cfg_local_ip<=c_lip;cfg_netmask<=c_nmask;cfg_dst_ip<=c_dip;cfg_dst_port<=c_dport;cfg_reserved0<=c_res0;cfg_sample_rate<=c_rate;
       cfg_channel_mask<=c_mask;cfg_groups_per_packet<=c_gpp;cfg_reserved1<=c_res1;
       request_send<=1'b1;request_pending<=1'b1;
       diag_commands_published<=diag_commands_published+1'b1;
     end
     else if(busy&&crc==CRC_RESIDUE&&etype==16'h0800&&ihl==8'h45&&proto==8'h11&&ip_ok&&dport==CONTROL_PORT)
      diag_busy_drops<=diag_busy_drops+1'b1;
     state<=IDLE;
    end
   end
   endcase
  end
 end
endmodule
`default_nettype wire
