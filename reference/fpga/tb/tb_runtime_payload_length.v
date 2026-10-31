`timescale 1ns/1ps
module tb_runtime_payload_length;
 reg clk=0,rst=1;always #4 clk=~clk;
 reg [23:0] mask=0;reg [4:0] groups=1;wire [15:0] length;
 integer ch,g;
 runtime_payload_length dut(clk,rst,mask,groups,length);
 initial begin
   repeat(3)@(negedge clk);rst=0;
   for(ch=1;ch<=24;ch=ch+1)for(g=1;g<=30;g=g+1)begin
     mask=(24'hffffff>>(24-ch));groups=g;
     repeat(2)@(negedge clk);
     if(length!==12+2*ch*g)$fatal(1,"length failed");
   end
   mask=24'haaaaaa;groups=30;repeat(2)@(negedge clk);
   if(length!==732)$fatal(1,"sparse mask failed");
   $display("PASS: 720 legal lengths and sparse channel mask");$finish;
 end
endmodule
