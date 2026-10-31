`timescale 1ns/1ps
// Behavioral CCLK handover: first three complete clocks never reach the chip.
module STARTUPE2 #(parameter PROG_USR="FALSE", parameter SIM_CCLK_FREQ=0.0)(
 input CLK,GSR,GTS,KEYCLEARB,PACK,USRCCLKO,USRCCLKTS,USRDONEO,USRDONETS,
 output CFGCLK,CFGMCLK,EOS,PREQ);
 integer cycles=0;
 wire cclk = !USRCCLKTS && cycles>=3 && USRCCLKO;
 assign EOS=1'b1;
 always @(negedge USRCCLKO) if(cycles<3) cycles=cycles+1;
endmodule

module tb_flash_boot;
 reg clk=0,rst=1,save_pulse=0,clk125=0;
 initial begin #1.7;forever #4 clk125=~clk125;end
 wire save_req;
 always #15.625 clk=~clk;
 wire cs,mosi,boot,err,done;
 reg miso=1;
 wire [23:0] id;
 wire [1:0] copy;
 wire [31:0] seq,attempts;
 wire [3:0] save_status;
 reg [223:0] cfg={32'hc0a80002,32'hffffff00,32'hc0a80003,16'd56555,16'd0,32'd500000,32'hffffff,32'd30};
 wire [223:0] save_cfg32,boot_cfg,active_cfg;
 wire boot_valid,boot_ready,result_valid;wire [3:0] result_status;wire [31:0] result_seq;wire [1:0] result_copy,boot_copy;
 integer boot_count=0,result_count=0,request_count=0;
 reg boot_prev=0,result_prev=0;
 flash_config_cdc_bridge bridge(.clk32(clk),.rst32(rst),.clk125(clk125),.rst125(rst),
 .flash_boot_done(boot),.flash_active_config(active_cfg),.flash_config_from_flash(copy!=0),.flash_active_sequence(seq),.flash_active_copy_32(copy),
 .boot_config_valid(boot_valid),.boot_config_ready(boot_ready),.boot_config(boot_cfg),.boot_copy(boot_copy),
 .save_req_125(save_pulse),.save_config_125(cfg),.flash_save_req_32(save_req),.flash_save_config_32(save_cfg32),
 .flash_save_done_32(done),.flash_save_status_32(save_status),.flash_sequence_32(seq),.flash_copy_32(copy),
 .save_result_valid_125(result_valid),.save_status_125(result_status),.save_sequence_125(result_seq),.save_copy_125(result_copy));
 always @(posedge clk125)begin
   if(!rst)begin
     if(boot_valid && boot_prev)$fatal(1,"boot valid repeated");
     if(result_valid && result_prev)$fatal(1,"result valid repeated");
     if(boot_valid)begin boot_count=boot_count+1;if(boot_cfg!==active_cfg)$fatal(1,"boot data torn");end
     if(result_valid)result_count=result_count+1;
   end
   boot_prev<=boot_valid;result_prev<=result_valid;
 end
 always @(posedge clk) if(!rst && save_req)request_count=request_count+1;
 flash_param_manager #(.STARTUP_WAIT_CYCLES(8),.DEBUG_RETRY_CYCLES(32)) dut(
 .clk(clk),.rst(rst),.save_req(save_req),.save_config(save_cfg32),.save_done(done),.save_status(save_status),.active_config(active_cfg),
 .boot_done(boot),.flash_error(err),.jedec_id(id),.active_copy(copy),.active_sequence(seq),
 .flash_cs_n(cs),.flash_dq0(mosi),.flash_dq1(miso),.debug_jedec_attempt_count(attempts));
 wire sck=dut.u_spi.u_startup.cclk;
 reg [7:0] mema[0:4095],memb[0:4095];
 integer bits=0,idx=0,addr=0,k,n=0,fail_id=0,iteration;
 reg [7:0] sh=0,cmd=0,outbyte=255;
 reg wel=0;
 always @(negedge cs) begin bits=0;idx=0;addr=0;sh=0;cmd=0;miso=1; end
 always @(posedge sck) if(!cs) begin
   sh={sh[6:0],mosi}; bits=bits+1;
   if(bits==8) begin
     bits=0;
     if(idx==0) begin
       cmd=sh;
       if(cmd==8'h06)wel=1;
       if(cmd==8'h9f)n=n+1;
       if(cmd!=8'h06 && cmd!=8'h9f && cmd!=8'h03 && cmd!=8'h05 && cmd!=8'h20 && cmd!=8'h02) $fatal(1,"bad opcode %h",cmd);
     end else if((cmd==3 || cmd==2 || cmd==8'h20) && idx<=3) begin
       addr=(addr<<8)|sh;
       if(idx==3 && (cmd==2 || cmd==8'h20)) begin
         if(!wel || (addr!=24'h800000 && addr!=24'hc00000 && addr!=24'h800018 && addr!=24'hc00018)) $fatal(1,"unsafe write");
         if(cmd==8'h20) for(k=0;k<4096;k=k+1)begin if(addr==24'h800000)mema[k]=255;else memb[k]=255;end
       end
     end else if(cmd==2 && idx>=4) begin
       if(addr>=24'hc00000)memb[addr-24'hc00000]=memb[addr-24'hc00000]&sh;
       else mema[addr-24'h800000]=mema[addr-24'h800000]&sh;
       addr=addr+1;
     end else if(cmd==3 && idx>=4) addr=addr+1;
     idx=idx+1;
   end
 end
 always @(negedge sck) if(!cs) begin
   outbyte=255;
   if(cmd==8'h9f && n>fail_id)case(idx)1:outbyte=8'hef;2:outbyte=8'h40;3:outbyte=8'h18;endcase
   if(cmd==5)outbyte=0;
   if(cmd==3 && idx>=4)begin
     if(addr>=24'hc00000)outbyte=memb[addr-24'hc00000];else outbyte=mema[addr-24'h800000];
   end
   miso=outbyte[7-bits];
 end
 task reset_device; begin repeat(50)@(posedge clk);rst=1;repeat(5)@(posedge clk);@(negedge clk);rst=0;end endtask
 task save; reg [223:0] expected_cfg; begin
   expected_cfg=cfg;
   @(negedge clk125);save_pulse=1;@(negedge clk125);save_pulse=0;
   cfg=~expected_cfg; // Source may change immediately after the input pulse.
   wait(result_valid);@(posedge clk125);if(result_status!==0 || result_seq!==seq || result_copy!==copy)$fatal(1,"CDC save result failed status=%h seq=%h/%h copy=%h/%h",result_status,result_seq,seq,result_copy,copy);
   if(active_cfg!==expected_cfg)$fatal(1,"saved configuration torn");
   cfg=expected_cfg;
   @(negedge clk125);repeat(50)@(posedge clk);
 end endtask
 initial begin
   for(k=0;k<4096;k=k+1)begin mema[k]=255;memb[k]=255;end
   reset_device;wait(boot);if(err!==0 || id!==24'hef4018 || copy!==0)$fatal(1,"boot failed");
   save;if(copy!==1 || seq!==1)$fatal(1,"A failed");
   save;if(copy!==2 || seq!==2)$fatal(1,"B failed");
   for(iteration=0;iteration<12;iteration=iteration+1)begin cfg[31:0]=iteration+1;repeat(iteration+1)@(posedge clk125);save;end
   if(seq!==14 || request_count!=14 || result_count!=14)$fatal(1,"lost or repeated saves");
   reset_device;wait(boot);if(err!==0 || copy!==2 || seq!==14)$fatal(1,"reload failed");
   fail_id=n+2;reset_device;wait(boot);if(err!==0 || attempts!==3)$fatal(1,"retry recovery failed");
   fail_id=999;reset_device;wait(boot);if(err!==1 || attempts!==3)$fatal(1,"failure fallback failed");
   repeat(100)@(posedge clk125);
   if(boot_count!=4)$fatal(1,"boot pulse lost/repeated %d",boot_count);
   if(!boot_ready)$fatal(1,"boot_config_ready did not remain asserted");
   $display("PASS: handover, actual XPM bridge, 14 A/B saves, reload, retries");$finish;
 end
 initial begin #20000000;$fatal(1,"timeout");end
endmodule
