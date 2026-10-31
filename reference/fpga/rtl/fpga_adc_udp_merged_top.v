`timescale 1ns / 1ps
`default_nettype none

module fpga_adc_udp_merged_top #(
    parameter integer SIMULATION = 0,
    parameter integer ARP_START_DELAY_CYCLES = 375000000,
    parameter integer ADC_POWERUP_WAIT_CYCLES = 320000,
    parameter integer ADC_SAMPLE_DIV = 64,
    parameter [31:0] UDP_SAMPLE_RATE = 32'd500000,
    parameter integer ADC_PIPELINED_CAPTURE = 0
)(
    input  wire clk32m,
    input  wire sw1_n,
    input  wire sw2_n,
    output wire phy_nrst,
    output wire sample_monitor,

    input wire rgmii_rxc, input wire [3:0] rgmii_rxd,
    input wire rgmii_rx_ctl, output wire [3:0] rgmii_txd,
    output wire rgmii_tx_ctl, output wire rgmii_txc,

    input wire adc1_busy, inout wire [15:0] adc1_db,
    output wire [2:0] adc1_os,
    output wire adc1_par_ser_sel, adc1_nstby, adc1_range,
    output wire adc1_convst, adc1_rst, adc1_ncs, adc1_nwr, adc1_nrd,

    input wire adc2_busy, inout wire [15:0] adc2_db,
    output wire [2:0] adc2_os,
    output wire adc2_par_ser_sel, adc2_nstby, adc2_range,
    output wire adc2_convst, adc2_rst, adc2_ncs, adc2_nwr, adc2_nrd,

    input wire adc3_busy, inout wire [15:0] adc3_db,
    output wire [2:0] adc3_os,
    output wire adc3_par_ser_sel, adc3_nstby, adc3_range,
    output wire adc3_convst, adc3_rst, adc3_ncs, adc3_nwr, adc3_nrd
);
    wire clk32, clk125, clk125_90, clk200, mmcm_locked;
    wire rst_async, rst32, rst125, rst125_90, rst200;
    wire start_pulse, stop_pulse, sw1_stable_n, sw2_stable_n;
    wire [383:0] sample_group_data;
    wire sample_group_valid, sample_group_ready;
    wire adc_init_done, adc_idle, adc_error;
    wire [7:0] adc_error_code;
    wire [2:0] done_mask, debug_sample_valid;
    wire [11:0] debug_capture_state;
    wire sample_start;
    wire session_active, fifo_flush_req, fifo_ready, adc_stop_req;
    wire arp_valid_125, arp_valid_32;
    wire udp_idle_125, udp_idle_32;
    wire network_error, system_ready, system_error;
    wire [3:0] system_state;
    wire [9:0] fifo_wr_count, fifo_rd_count;
    wire [31:0] udp_packets_sent;

    // One clk32-wide pulse means that one complete 24-channel sample group
    // was accepted by the asynchronous FIFO.  At 500 kSPS its repetition
    // frequency is 500 kHz and its period is 2 us.
    assign sample_monitor = sample_group_valid && sample_group_ready;

    clock_reset_ctrl u_clock_reset (
        .clk32m(clk32m), .clk32(clk32), .clk125(clk125),
        .clk125_90(clk125_90), .clk200(clk200),
        .rst_async(rst_async), .rst32(rst32), .rst125(rst125),
        .rst125_90(rst125_90), .rst200(rst200),
        .phy_nrst(phy_nrst), .mmcm_locked(mmcm_locked));

    button_debounce u_start_button (
        .clk(clk32),.rst(rst32),.button_n(sw1_n),
        .press_pulse(start_pulse),.stable_n(sw1_stable_n));
    button_debounce u_stop_button (
        .clk(clk32),.rst(rst32),.button_n(sw2_n),
        .press_pulse(stop_pulse),.stable_n(sw2_stable_n));

    system_run_ctrl u_run_ctrl (
        .clk(clk32),.rst(rst32),.start_pulse(start_pulse),
        .stop_pulse(stop_pulse),.adc_init_done(adc_init_done),
        .adc_idle(adc_idle),.adc_error(adc_error),
        .arp_valid(arp_valid_32),.udp_idle(udp_idle_32),
        .fifo_ready(fifo_ready),.network_error(network_error),
        .session_active(session_active),.fifo_flush_req(fifo_flush_req),
        .adc_stop_req(adc_stop_req),.ready(system_ready),
        .error(system_error),.state(system_state));

    adc_capture_24ch #(.SAMPLE_DIV(ADC_SAMPLE_DIV),
        .POWERUP_WAIT_CYCLES(ADC_POWERUP_WAIT_CYCLES),
        .PIPELINED_CAPTURE(ADC_PIPELINED_CAPTURE)) u_adc_capture (
        .clk(clk32),.rst(rst32),.run_enable(session_active),
        .sample_div_runtime(ADC_SAMPLE_DIV),
        .stop_req(adc_stop_req),.group_data(sample_group_data),
        .group_valid(sample_group_valid),.group_ready(sample_group_ready),
        .init_done(adc_init_done),.capture_idle(adc_idle),
        .error(adc_error),.error_code(adc_error_code),
        .done_mask(done_mask),.sample_start(sample_start),
        .adc1_busy(adc1_busy),.adc1_db(adc1_db),.adc1_os(adc1_os),
        .adc1_par_ser_sel(adc1_par_ser_sel),.adc1_nstby(adc1_nstby),
        .adc1_range(adc1_range),.adc1_convst(adc1_convst),.adc1_rst(adc1_rst),
        .adc1_ncs(adc1_ncs),.adc1_nwr(adc1_nwr),.adc1_nrd(adc1_nrd),
        .adc2_busy(adc2_busy),.adc2_db(adc2_db),.adc2_os(adc2_os),
        .adc2_par_ser_sel(adc2_par_ser_sel),.adc2_nstby(adc2_nstby),
        .adc2_range(adc2_range),.adc2_convst(adc2_convst),.adc2_rst(adc2_rst),
        .adc2_ncs(adc2_ncs),.adc2_nwr(adc2_nwr),.adc2_nrd(adc2_nrd),
        .adc3_busy(adc3_busy),.adc3_db(adc3_db),.adc3_os(adc3_os),
        .adc3_par_ser_sel(adc3_par_ser_sel),.adc3_nstby(adc3_nstby),
        .adc3_range(adc3_range),.adc3_convst(adc3_convst),.adc3_rst(adc3_rst),
        .adc3_ncs(adc3_ncs),.adc3_nwr(adc3_nwr),.adc3_nrd(adc3_nrd),
        .debug_sample_valid(debug_sample_valid),
        .debug_capture_state(debug_capture_state));

    network_stream_core #(
        .SIMULATION(SIMULATION),.TARGET_IP(32'hC0A8_0003),
        .ARP_START_DELAY_CYCLES(ARP_START_DELAY_CYCLES),
        .GROUPS_PER_PACKET(30),.SAMPLE_RATE(UDP_SAMPLE_RATE)
    ) u_network (
        .sample_clk(clk32),.sample_group_data(sample_group_data),
        .sample_group_valid(sample_group_valid),
        .sample_group_ready(sample_group_ready),
        .session_active(session_active),.fifo_flush_req(fifo_flush_req),
        .fifo_ready(fifo_ready),.arp_valid_125(arp_valid_125),
        .arp_valid_32(arp_valid_32), .udp_idle_125(udp_idle_125),
        .udp_idle_32(udp_idle_32),.session_error(network_error),
        .debug_fifo_wr_count(fifo_wr_count),.debug_fifo_rd_count(fifo_rd_count),
        .debug_udp_packets_sent(udp_packets_sent),
        .clk125(clk125),.clk125_90(clk125_90),.clk200(clk200),
        .rst_async(rst_async), .rst32(rst32), .rst125(rst125),
        .rst125_90(rst125_90), .rst200(rst200),
        .rgmii_rxc(rgmii_rxc),.rgmii_rxd(rgmii_rxd),
        .rgmii_rx_ctl(rgmii_rx_ctl),.rgmii_txd(rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl),.rgmii_txc(rgmii_txc),
        .manual_enable(1'b0),.manual_tap(5'd31),
        .manual_align(3'd0),.rescan(1'b0));

    // Stable hierarchical names used by the debug build Tcl.
    (* KEEP="TRUE" *) wire [3:0] dbg_system_state = system_state;
    (* KEEP="TRUE" *) wire dbg_ready = system_ready;
    (* KEEP="TRUE" *) wire dbg_error = system_error;
    (* KEEP="TRUE" *) wire dbg_start = start_pulse;
    (* KEEP="TRUE" *) wire dbg_stop = stop_pulse;
    (* KEEP="TRUE" *) wire dbg_sample_start = sample_start;
    (* KEEP="TRUE" *) wire [2:0] dbg_sample_valid = debug_sample_valid;
    (* KEEP="TRUE" *) wire [2:0] dbg_done_mask = done_mask;
    (* KEEP="TRUE" *) wire [11:0] dbg_capture_state = debug_capture_state;
    (* KEEP="TRUE" *) wire [7:0] dbg_adc_error_code = adc_error_code;
    // A compact first-three-channel preview keeps the ILA build practical in
    // Vivado 2019.2; the complete 384-bit word remains observable at the FIFO
    // write interface when a wider custom probe is needed.
    (* KEEP="TRUE" *) wire [47:0] dbg_group_preview = sample_group_data[47:0];
    (* KEEP="TRUE" *) wire [9:0] dbg_fifo_wr_count = fifo_wr_count;
    (* KEEP="TRUE" *) wire [9:0] dbg_fifo_rd_count = fifo_rd_count;
    (* KEEP="TRUE" *) wire dbg_arp_valid = arp_valid_125;
    (* KEEP="TRUE" *) wire dbg_udp_idle = udp_idle_125;
    (* KEEP="TRUE" *) wire [31:0] dbg_packets = udp_packets_sent;
endmodule

`default_nettype wire
