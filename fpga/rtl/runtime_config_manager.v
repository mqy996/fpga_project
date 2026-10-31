`timescale 1ns / 1ps
`default_nettype none

// Control-plane policy in the 125 MHz domain.  START/STOP are executed by
// system_run_ctrl in the 32 MHz acquisition domain through a full CDC
// request/result handshake; SW1/SW2 remain equally authoritative.
module runtime_config_manager #(
 parameter [223:0] DEFAULT_CONFIG={32'hC0A80002,32'hFFFFFF00,32'hC0A80003,16'd56555,16'd0,32'd500000,32'h00FFFFFF,32'd30},
 // At 1 Gbit/s every current control response is on the wire in a few
 // microseconds.  This guard only releases an abnormal stalled transaction;
 // it prevents one lost completion event from permanently blocking UDP 56556.
 parameter integer RESPONSE_TIMEOUT_CYCLES=250000
)(
 input wire clk,input wire rst,
 input wire boot_config_valid,input wire boot_config_ready,input wire [223:0] boot_config,input wire boot_from_flash,input wire [31:0] boot_sequence,
 input wire request_valid,output reg request_done,
 input wire [47:0] request_src_mac,input wire [31:0] request_src_ip,input wire [15:0] request_src_port,
 input wire [31:0] request_cmd,input wire [31:0] request_len,input wire [31:0] request_tid,
 input wire [223:0] request_config,
 input wire system_ready,input wire session_active,input wire stopping,input wire response_mac_done,
 input wire run_command_busy,input wire run_command_done,input wire [3:0] run_command_status,
 output reg run_start_req,output reg run_stop_req,
 input wire flash_busy,input wire flash_error,input wire flash_save_done,input wire [3:0] flash_save_status,
 input wire [31:0] flash_sequence,input wire [1:0] flash_active_copy,
 output reg flash_save_req,output reg [223:0] flash_save_config,
 output reg response_start,output reg [47:0] response_dst_mac,output reg [31:0] response_dst_ip,output reg [15:0] response_dst_port,
 output reg [31:0] response_cmd,output reg [31:0] response_status,output reg [31:0] response_tid,output reg [15:0] response_data_len,
 output reg [223:0] active_config,output reg config_from_flash,output reg [31:0] config_sequence,
 output reg config_change_pulse,output reg arp_clear_pulse,output reg fifo_reprepare_pulse
);
 localparam OK=0,INVALID_CMD=1,INVALID_LENGTH=2,INVALID_PARAM=3,INVALID_STATE=4,BUSY=5,
            UNSUPPORTED=6,FLASH_ERROR=7,VERIFY_ERROR=8,TIMEOUT=9;
 // DEST_EXT_HSK on xpm_cdc_handshake is a four-phase handshake.  In
 // particular, request_done is an acknowledgement *level*, not a one-clock
 // event: it must remain asserted until request_valid has returned low.
 // A one-cycle 125 MHz acknowledgement can be missed by the asynchronous
 // RXC source clock and leaves its request_pending latch stuck forever.
 localparam M_IDLE=0,M_WAIT_RSP=1,M_WAIT_SAVE=2,M_WAIT_SAVE_RSP=3,
            M_VALIDATE_SET=4,M_ACK_REQUEST=5,M_WAIT_RUN=6;
 reg [2:0] state;
 reg boot_applied;
 reg [223:0] pending_config;
 reg pending_apply,pending_default;
 reg [17:0] response_wait_count;
 reg [31:0] last_cmd,last_tid,last_status,last_src_ip;reg [15:0] last_src_port,last_len;
 // SET_CONFIG is captured first, then validated on the following cycle.  This
 // breaks the long handshake-data -> validator -> register-enable path and
 // also guarantees that all 224 configuration bits belong to one request.
 wire [31:0] q_local_ip=pending_config[223:192];wire [31:0] q_netmask=pending_config[191:160];
 wire [31:0] q_target_ip=pending_config[159:128];wire [15:0] q_target_port=pending_config[127:112];
 wire [31:0] q_rate=pending_config[95:64];wire [31:0] q_mask=pending_config[63:32];wire [31:0] q_groups=pending_config[31:0];
 wire q_valid;wire [5:0] q_channels;wire [15:0] q_payload;
 config_validate u_validate(.local_ip(q_local_ip),.netmask(q_netmask),.target_ip(q_target_ip),.target_port(q_target_port),
  .sample_rate(q_rate),.channel_mask(q_mask),.groups_per_packet(q_groups),.valid(q_valid),.enabled_channels(q_channels),.payload_length(q_payload));
 function [15:0] response_length;input [31:0] c;input [31:0] s;begin
  if(s!=OK)response_length=0;else case(c)1:response_length=32;2:response_length=72;3,7,9:response_length=40;
   6:response_length=64;8:response_length=12;10:response_length=24;default:response_length=0;endcase end endfunction
 task launch;input [31:0] c;input [31:0] s;begin
  response_dst_mac<=request_src_mac;response_dst_ip<=request_src_ip;response_dst_port<=request_src_port;
  response_cmd<=c;response_status<=s;response_tid<=request_tid;response_data_len<=response_length(c,s);
  response_start<=1;last_cmd<=c;last_tid<=request_tid;last_status<=s;last_src_ip<=request_src_ip;last_src_port<=request_src_port;last_len<=response_length(c,s);
 end endtask
 always @(posedge clk)begin
  if(rst)begin state<=M_IDLE;request_done<=0;flash_save_req<=0;flash_save_config<=DEFAULT_CONFIG;response_start<=0;run_start_req<=0;run_stop_req<=0;
   response_dst_mac<=0;response_dst_ip<=0;response_dst_port<=0;response_cmd<=0;response_status<=0;response_tid<=0;response_data_len<=0;
   active_config<=DEFAULT_CONFIG;config_from_flash<=0;config_sequence<=0;config_change_pulse<=0;arp_clear_pulse<=0;fifo_reprepare_pulse<=0;boot_applied<=0;
   pending_config<=DEFAULT_CONFIG;pending_apply<=0;pending_default<=0;response_wait_count<=0;last_cmd<=0;last_tid<=0;last_status<=0;last_src_ip<=0;last_src_port<=0;last_len<=0;
  end else begin
   // request_done deliberately has no unconditional default here.  It is
   // held throughout M_ACK_REQUEST so the RXC-side XPM handshake cannot miss
   // the acknowledgement.
   flash_save_req<=0;response_start<=0;config_change_pulse<=0;arp_clear_pulse<=0;fifo_reprepare_pulse<=0;run_start_req<=0;run_stop_req<=0;
   // boot_config_ready is a level held by the CDC bridge until the next
   // reset.  Applying the configuration once avoids losing the boot event
   // when rst125 and the protocol state reset release on adjacent cycles.
   if((boot_config_ready||boot_config_valid)&&!boot_applied)begin
     active_config<=boot_config;config_from_flash<=boot_from_flash;config_sequence<=boot_sequence;
     config_change_pulse<=1;arp_clear_pulse<=1;fifo_reprepare_pulse<=1;boot_applied<=1;
   end
   case(state)
    M_IDLE:begin
      request_done<=0;
      response_wait_count<=0;
      if(request_valid)begin
      // Retried side-effecting commands return their cached result.
      if(request_cmd==last_cmd&&request_tid==last_tid&&request_src_ip==last_src_ip&&request_src_port==last_src_port)begin
        response_dst_mac<=request_src_mac;response_dst_ip<=request_src_ip;response_dst_port<=request_src_port;
        response_cmd<=last_cmd;response_status<=last_status;response_tid<=last_tid;response_data_len<=last_len;response_start<=1;state<=M_WAIT_RSP;
      end else case(request_cmd)
       1,2,6,7,10:begin if(request_len!=0)launch(request_cmd,INVALID_LENGTH);else launch(request_cmd,OK);state<=M_WAIT_RSP;end
       3:begin
        if(request_len!=28)launch(3,INVALID_LENGTH);
        else if(!system_ready||session_active||stopping)launch(3,INVALID_STATE);
        else begin pending_config<=request_config;state<=M_VALIDATE_SET;end
        if(request_len!=28||!system_ready||session_active||stopping)state<=M_WAIT_RSP;
       end
       4:begin
        if(request_len!=0)begin launch(4,INVALID_LENGTH);state<=M_WAIT_RSP;end
        else if(!system_ready||stopping)begin launch(4,INVALID_STATE);state<=M_WAIT_RSP;end
        // START is idempotent in RUN.  Do not send an unnecessary CDC
        // transaction when the synchronised run state already says active.
        else if(session_active)begin launch(4,OK);state<=M_WAIT_RSP;end
        else if(run_command_busy)begin launch(4,BUSY);state<=M_WAIT_RSP;end
        else begin run_start_req<=1'b1;state<=M_WAIT_RUN;end
       end
       5:begin
        if(request_len!=0)begin launch(5,INVALID_LENGTH);state<=M_WAIT_RSP;end
        // STOP is idempotent in READY and while the physical/software stop
        // sequence is already draining.  Only RUN needs a 32 MHz command.
        else if(system_ready||stopping)begin launch(5,OK);state<=M_WAIT_RSP;end
        else if(!session_active)begin launch(5,INVALID_STATE);state<=M_WAIT_RSP;end
        else if(run_command_busy)begin launch(5,BUSY);state<=M_WAIT_RSP;end
        else begin run_stop_req<=1'b1;state<=M_WAIT_RUN;end
       end
       8:begin
        if(request_len!=0)begin launch(8,INVALID_LENGTH);state<=M_WAIT_RSP;end
        else if(!system_ready||session_active||stopping)begin launch(8,INVALID_STATE);state<=M_WAIT_RSP;end
        else if(flash_error)begin launch(8,FLASH_ERROR);state<=M_WAIT_RSP;end
        else if(flash_busy)begin launch(8,BUSY);state<=M_WAIT_RSP;end
        else begin flash_save_config<=active_config;flash_save_req<=1;state<=M_WAIT_SAVE;end
       end
       9:begin
        if(request_len!=0)launch(9,INVALID_LENGTH);
        else if(!system_ready||session_active||stopping)launch(9,INVALID_STATE);
        else begin pending_config<=DEFAULT_CONFIG;pending_apply<=1;pending_default<=1;launch(9,OK);end
        state<=M_WAIT_RSP;
       end
       default:begin launch(request_cmd,INVALID_CMD);state<=M_WAIT_RSP;end
      endcase
      end
    end
    M_VALIDATE_SET:begin
      request_done<=0;
      if(!q_valid||pending_config[111:96]!=0)launch(3,INVALID_PARAM);
      else begin pending_apply<=1;launch(3,OK);end
      state<=M_WAIT_RSP;
    end
    M_WAIT_RUN:begin
      request_done<=0;
      // The 32 MHz controller has accepted the command only after it has
      // applied the same arbitration as SW1/SW2.  Returning this result (not
      // a speculative ACK) lets the host safely start/stop its UDP receiver.
      if(run_command_done)begin
        launch(request_cmd,{28'd0,run_command_status});
        state<=M_WAIT_RSP;
      end
    end
    M_WAIT_SAVE:begin
      request_done<=0;
      if(flash_save_done)begin
        config_sequence<=flash_sequence;config_from_flash<=(flash_save_status==OK);
        launch(8,{28'd0,flash_save_status});state<=M_WAIT_SAVE_RSP;
      end
    end
    M_WAIT_RSP,M_WAIT_SAVE_RSP:begin
      request_done<=0;
      if(response_mac_done || response_wait_count==RESPONSE_TIMEOUT_CYCLES-1)begin
        response_wait_count<=0;
        if(pending_apply)begin active_config<=pending_config;config_from_flash<=0;
          config_change_pulse<=1;arp_clear_pulse<=1;fifo_reprepare_pulse<=1;pending_apply<=0;pending_default<=0;end
        request_done<=1;state<=M_ACK_REQUEST;
      end else response_wait_count<=response_wait_count+1'b1;
    end
    M_ACK_REQUEST:begin
      // The source retains its descriptor until it observes this level and
      // drops src_send.  Only then is it safe to accept another descriptor.
      request_done<=1;
      response_wait_count<=0;
      if(!request_valid)begin
        request_done<=0;
        state<=M_IDLE;
      end
    end
    default:state<=M_IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
