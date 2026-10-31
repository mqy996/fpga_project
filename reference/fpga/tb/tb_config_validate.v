`timescale 1ns/1ps
module tb_config_validate;
 reg [31:0] lip=32'hc0a80002,nm=32'hffffff00,dip=32'hc0a80003,rate=500000,mask=32'h00ffffff,gpp=30;
 reg [15:0] port=56555;wire valid;wire [5:0] channels;wire [15:0] length;
 config_validate dut(.local_ip(lip),.netmask(nm),.target_ip(dip),.target_port(port),.sample_rate(rate),.channel_mask(mask),.groups_per_packet(gpp),.valid(valid),.enabled_channels(channels),.payload_length(length));
 initial begin
  #1;if(!valid||channels!=24||length!=1452)$fatal(1,"default config validation failed");
  mask=32'h00000001;gpp=1;#1;if(!valid||channels!=1||length!=14)$fatal(1,"one-channel config failed");
  rate=250000;#1;if(!valid)$fatal(1,"250 kSPS rejected");
  rate=1000000;#1;if(!valid)$fatal(1,"1 MSPS rejected");
  rate=125000;#1;if(valid)$fatal(1,"unsupported sample rate accepted");rate=500000;
  nm=32'hff00ff00;#1;if(valid)$fatal(1,"non-contiguous mask accepted");nm=32'hffffff00;
  dip=32'hc0a80103;#1;if(valid)$fatal(1,"off-subnet target accepted");
  $display("PASS: runtime configuration validation");$finish;
 end
endmodule
