`timescale 1ns/1ps
module tb_runtime_config_manager;
 reg clk=0,rst=1,bootv=0,bootready=0,reqv=0,ready=1,active=0,stopping=0,rspdone=0,fb=0,fe=0,fsdone=0;
 reg runbusy=0,rundone=0; reg [3:0] runstatus=0;
 reg [3:0] fsstatus=0;reg [31:0] fseq=0;reg [1:0] fcopy=0;
 reg [31:0] cmd=0,len=0,tid=1;reg [223:0] reqcfg={32'hc0a80022,32'hffffff00,32'hc0a80003,16'd56555,16'd0,32'd500000,32'h00ffffff,32'd30};
 wire reqdone,savereq,rspstart,cfgchg,arpclr,flush,runstart,runstop;wire [223:0] savecfg,activecfg;wire [31:0] rspcmd,rspstatus,rsptid;wire [15:0] rsplen;wire [47:0] rspmac;wire [31:0] rspip;wire [15:0] rspport;wire fromflash;wire [31:0] cfgseq;
 always #4 clk=~clk;
 runtime_config_manager dut(.clk(clk),.rst(rst),.boot_config_valid(bootv),.boot_config_ready(bootready),.boot_config({32'hc0a80002,32'hffffff00,32'hc0a80003,16'd56555,16'd0,32'd500000,32'h00ffffff,32'd30}),.boot_from_flash(1'b0),.boot_sequence(32'd0),
  .request_valid(reqv),.request_done(reqdone),.request_src_mac(48'h001122334455),.request_src_ip(32'hc0a80003),.request_src_port(16'd60000),.request_cmd(cmd),.request_len(len),.request_tid(tid),.request_config(reqcfg),
  .system_ready(ready),.session_active(active),.stopping(stopping),.response_mac_done(rspdone),.run_command_busy(runbusy),.run_command_done(rundone),.run_command_status(runstatus),.run_start_req(runstart),.run_stop_req(runstop),.flash_busy(fb),.flash_error(fe),.flash_save_done(fsdone),.flash_save_status(fsstatus),.flash_sequence(fseq),.flash_active_copy(fcopy),
  .flash_save_req(savereq),.flash_save_config(savecfg),.response_start(rspstart),.response_dst_mac(rspmac),.response_dst_ip(rspip),.response_dst_port(rspport),.response_cmd(rspcmd),.response_status(rspstatus),.response_tid(rsptid),.response_data_len(rsplen),
  .active_config(activecfg),.config_from_flash(fromflash),.config_sequence(cfgseq),.config_change_pulse(cfgchg),.arp_clear_pulse(arpclr),.fifo_reprepare_pulse(flush));
 // Model the source side of a true four-phase CDC handshake: after seeing
 // destination acknowledgement it keeps the request asserted briefly, then
 // withdraws it.  The acknowledgement must remain stable during that time.
 task finish_response;begin
   wait(rspstart);@(posedge clk);rspdone<=1;@(posedge clk);rspdone<=0;
   wait(reqdone);
   repeat(4)begin @(posedge clk); if(!reqdone)$fatal(1,"request_done was a pulse, not a held CDC acknowledgement"); end
   reqv<=0;
   repeat(2)@(posedge clk);
   if(reqdone)$fatal(1,"request_done did not release after request_valid fell");
 end endtask
 initial begin
 repeat(3)@(posedge clk);rst<=0;bootv<=1;@(posedge clk);bootv<=0;
  // A completed response must release the descriptor immediately so the
  // following command is accepted.  This models GET_INFO -> GET_STATUS,
  // the sequence that previously exposed a permanent control-port stall.
  cmd<=2;len<=0;tid<=8;reqv<=1;wait(rspstart);if(rsplen!=72)$fatal(1,"GET_INFO response length mismatch");finish_response();
  cmd<=6;len<=0;tid<=9;reqv<=1;wait(rspstart);if(rsplen!=64)$fatal(1,"GET_STATUS response length mismatch");finish_response();
  cmd<=3;len<=28;tid<=10;reqv<=1;finish_response();if(activecfg!=reqcfg)$fatal(1,"SET did not apply after response");
  cmd<=4;len<=0;tid<=11;reqv<=1;wait(runstart);@(posedge clk);rundone<=1;runstatus<=0;@(posedge clk);rundone<=0;wait(rspstart);if(rspstatus!=0)$fatal(1,"network START did not return controller OK");
  @(posedge clk);rspdone<=1;@(posedge clk);rspdone<=0;wait(reqdone);repeat(4)begin @(posedge clk);if(!reqdone)$fatal(1,"START acknowledgement was not held");end reqv<=0;repeat(2)@(posedge clk);if(reqdone)$fatal(1,"START acknowledgement did not release");
  cmd<=5;len<=0;tid<=13;reqv<=1;wait(runstop);@(posedge clk);rundone<=1;runstatus<=0;@(posedge clk);rundone<=0;finish_response();
  cmd<=8;tid<=12;reqv<=1;wait(savereq);if(savecfg!=activecfg)$fatal(1,"SAVE config mismatch");@(posedge clk);fseq<=1;fcopy<=1;fsdone<=1;@(posedge clk);fsdone<=0;finish_response();
  $display("PASS: sequential GET_INFO/GET_STATUS, SET ordering, software START/STOP and SAVE handshake");$finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule
