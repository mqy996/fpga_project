`timescale 1ns/1ps

module tb_system_run_ctrl;
    reg clk=0, rst=1, start_pulse=0, stop_pulse=0, software_start_pulse=0, software_stop_pulse=0;
    reg adc_init_done=0, adc_idle=1, adc_error=0;
    reg arp_valid_async=0, udp_idle_async=1, fifo_ready=0, network_error=0;
    wire session_active, fifo_flush_req, adc_stop_req, ready, error;
    wire [3:0] state, software_command_status;
    wire software_command_done;
    always #15.625 clk=~clk;

    system_run_ctrl #(.FLUSH_CYCLES(3)) dut (
        .clk(clk),.rst(rst),.start_pulse(start_pulse),.stop_pulse(stop_pulse),
        .software_start_pulse(software_start_pulse),.software_stop_pulse(software_stop_pulse),
        .reconfigure_pulse(1'b0),
        .adc_init_done(adc_init_done),.adc_idle(adc_idle),.adc_error(adc_error),
        .arp_valid(arp_valid_async),.udp_idle(udp_idle_async),
        .fifo_ready(fifo_ready),.network_error(network_error),
        .session_active(session_active),.fifo_flush_req(fifo_flush_req),
        .adc_stop_req(adc_stop_req),.ready(ready),.error(error),.state(state),
        .software_command_done(software_command_done),.software_command_status(software_command_status));

    task pulse_start; begin @(posedge clk); start_pulse<=1; @(posedge clk); start_pulse<=0; end endtask
    task pulse_stop;  begin @(posedge clk); stop_pulse<=1;  @(posedge clk); stop_pulse<=0;  end endtask
    task pulse_sw_start; begin @(posedge clk); software_start_pulse<=1; @(posedge clk); software_start_pulse<=0; end endtask
    task pulse_sw_stop; begin @(posedge clk); software_stop_pulse<=1; @(posedge clk); software_stop_pulse<=0; end endtask
    initial begin
        repeat(4) @(posedge clk); rst<=0;
        adc_init_done<=1; arp_valid_async<=1;
        wait(fifo_flush_req); repeat(5) @(posedge clk); fifo_ready<=1;
        wait(ready); pulse_sw_start();
        repeat(2) @(posedge clk);
        if(!session_active) $fatal(1,"software START did not enter RUN");
        pulse_stop();
        wait(fifo_flush_req); repeat(5) @(posedge clk);
        wait(ready);
        if(session_active) $fatal(1,"STOP left session active");
        pulse_sw_stop(); #1;
        if(!software_command_done || software_command_status!=0) $fatal(1,"software STOP was not idempotent in READY");
        pulse_start(); repeat(2) @(posedge clk); adc_error<=1;
        wait(error);
        if(session_active || !adc_stop_req) $fatal(1,"ERROR shutdown failed");
        $display("PASS: READY/START/STOP/ERROR control sequence");
        $finish;
    end
    initial begin #20000; $fatal(1,"timeout"); end
endmodule
