`timescale 1ns / 1ps
`default_nettype none
module fifo_udp_payload_runtime(
    input wire clk,input wire rst,input wire start,input wire [31:0] sequence_number,
    input wire [31:0] sample_rate,input wire [31:0] channel_mask,input wire [5:0] groups_per_packet,
    output wire busy,input wire [383:0] fifo_data,input wire fifo_empty,output reg fifo_rd_en,
    output reg [7:0] data,output reg valid,input wire ready,output reg last
);
    localparam ST_IDLE=0,ST_HEADER=1,ST_DATA=2;
    reg [1:0] state; reg [3:0] hidx; reg [4:0] ch; reg [5:0] grp; reg low;
    reg [31:0] seq,srate,mask; reg [5:0] gpp; reg [383:0] group_word;
    reg [15:0] sample_word; integer k; reg [4:0] next_ch; reg has_next;
    function [4:0] first_enabled;
      input [31:0] m; integer n; reg found;
      begin first_enabled=0;found=0;for(n=0;n<24;n=n+1) if(m[n]&&!found) begin first_enabled=n;found=1;end end
    endfunction
    assign busy=state!=ST_IDLE;
    always @(*) begin
        sample_word=group_word[ch*16 +:16]; next_ch=0;has_next=0;
        for(k=0;k<24;k=k+1) if(k>ch && mask[k] && !has_next) begin next_ch=k;has_next=1; end
        data=0;valid=0;last=0;
        if(state==ST_HEADER) begin valid=1;case(hidx)
          0:data=seq[31:24];1:data=seq[23:16];2:data=seq[15:8];3:data=seq[7:0];
          4:data=srate[31:24];5:data=srate[23:16];6:data=srate[15:8];7:data=srate[7:0];
          8:data=mask[31:24];9:data=mask[23:16];10:data=mask[15:8];11:data=mask[7:0];default:data=0;endcase
        end else if(state==ST_DATA) begin valid=1;data=low?sample_word[7:0]:sample_word[15:8];last=low&&!has_next&&(grp==gpp-1);end
    end
    always @(posedge clk) begin
      if(rst) begin state<=ST_IDLE;hidx<=0;ch<=0;grp<=0;low<=0;seq<=0;srate<=0;mask<=0;gpp<=0;group_word<=0;fifo_rd_en<=0;end
      else begin fifo_rd_en<=0;case(state)
        ST_IDLE:if(start) begin seq<=sequence_number;srate<=sample_rate;mask<=channel_mask;gpp<=groups_per_packet;hidx<=0;grp<=0;state<=ST_HEADER;end
        ST_HEADER:if(valid&&ready) begin
          if(hidx==11) begin group_word<=fifo_data;fifo_rd_en<=1;ch<=first_enabled(mask);low<=0;state<=ST_DATA;end
          else hidx<=hidx+1'b1;
        end
        ST_DATA:if(valid&&ready) begin
          if(!low) low<=1; else begin low<=0;if(has_next) ch<=next_ch;else begin
            if(grp==gpp-1) state<=ST_IDLE; else begin grp<=grp+1'b1;group_word<=fifo_data;fifo_rd_en<=1;ch<=first_enabled(mask);end
          end end
        end
        default:state<=ST_IDLE;
      endcase end
    end
endmodule
`default_nettype wire
