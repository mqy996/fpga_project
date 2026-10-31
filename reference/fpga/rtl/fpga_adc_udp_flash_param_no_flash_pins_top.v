`timescale 1ns / 1ps
`default_nettype none

// QSPI diagnostic wrapper.  The current network/clock/reset top is retained,
// but the post-configuration Flash pins are not package pins in this build.
// BYPASS_FLASH keeps the internal Flash interface released.
module fpga_adc_udp_flash_param_no_flash_pins_top #(
    parameter integer CLOCK_STABLE_CYCLES = 1
)(
    input wire clk32m,
    input wire sw1_n,
    input wire sw2_n,
    output wire phy_nrst,
    output wire sample_monitor,
    input wire rgmii_rxc,
    input wire [3:0] rgmii_rxd,
    input wire rgmii_rx_ctl,
    output wire [3:0] rgmii_txd,
    output wire rgmii_tx_ctl,
    output wire rgmii_txc,
    input wire adc1_busy,
    inout wire [15:0] adc1_db,
    output wire [2:0] adc1_os,
    output wire adc1_par_ser_sel, adc1_nstby, adc1_range,
    output wire adc1_convst, adc1_rst, adc1_ncs, adc1_nwr, adc1_nrd,
    input wire adc2_busy,
    inout wire [15:0] adc2_db,
    output wire [2:0] adc2_os,
    output wire adc2_par_ser_sel, adc2_nstby, adc2_range,
    output wire adc2_convst, adc2_rst, adc2_ncs, adc2_nwr, adc2_nrd,
    input wire adc3_busy,
    inout wire [15:0] adc3_db,
    output wire [2:0] adc3_os,
    output wire adc3_par_ser_sel, adc3_nstby, adc3_range,
    output wire adc3_convst, adc3_rst, adc3_ncs, adc3_nwr, adc3_nrd
);
    wire flash_cs_n_unused;
    wire [3:0] flash_dq_unused;

    fpga_adc_udp_flash_param_top #(
        .BYPASS_FLASH(1),
        .CLOCK_STABLE_CYCLES(CLOCK_STABLE_CYCLES)
    ) u_core (
        .clk32m(clk32m), .sw1_n(sw1_n), .sw2_n(sw2_n),
        .phy_nrst(phy_nrst), .sample_monitor(sample_monitor),
        .flash_cs_n(flash_cs_n_unused), .flash_dq(flash_dq_unused),
        .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd),
        .rgmii_rx_ctl(rgmii_rx_ctl), .rgmii_txd(rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txc(rgmii_txc),
        .adc1_busy(adc1_busy), .adc1_db(adc1_db), .adc1_os(adc1_os),
        .adc1_par_ser_sel(adc1_par_ser_sel), .adc1_nstby(adc1_nstby),
        .adc1_range(adc1_range), .adc1_convst(adc1_convst),
        .adc1_rst(adc1_rst), .adc1_ncs(adc1_ncs), .adc1_nwr(adc1_nwr),
        .adc1_nrd(adc1_nrd), .adc2_busy(adc2_busy), .adc2_db(adc2_db),
        .adc2_os(adc2_os), .adc2_par_ser_sel(adc2_par_ser_sel),
        .adc2_nstby(adc2_nstby), .adc2_range(adc2_range),
        .adc2_convst(adc2_convst), .adc2_rst(adc2_rst),
        .adc2_ncs(adc2_ncs), .adc2_nwr(adc2_nwr), .adc2_nrd(adc2_nrd),
        .adc3_busy(adc3_busy), .adc3_db(adc3_db), .adc3_os(adc3_os),
        .adc3_par_ser_sel(adc3_par_ser_sel), .adc3_nstby(adc3_nstby),
        .adc3_range(adc3_range), .adc3_convst(adc3_convst),
        .adc3_rst(adc3_rst), .adc3_ncs(adc3_ncs), .adc3_nwr(adc3_nwr),
        .adc3_nrd(adc3_nrd)
    );
endmodule

`default_nettype wire
