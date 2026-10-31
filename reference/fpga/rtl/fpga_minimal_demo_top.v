`timescale 1ns / 1ps
`default_nettype none

// Standalone board demo.  Replace u_demo_source with the real ADC acquisition
// module when integrating; network_stream_core does not need to be modified.
module fpga_minimal_demo_top #(
    parameter integer TOTAL_GROUPS = 1000,
    parameter integer GROUPS_PER_PACKET = 10,
    parameter [31:0] SAMPLE_RATE = 32'd1000000,
    parameter [31:0] TARGET_IP = 32'hC0A8_0003,
    parameter integer TXC_PHASE_MDEG = 90000
)(
    input  wire       clk32m,
    input  wire       sw1_n,
    output wire       phy_nrst,
    input  wire       rgmii_rxc,
    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_txc
);
    wire clk32, clk125, clk125_90, clk200, rst, mmcm_locked;
    wire [383:0] sample_group_data;
    wire sample_group_valid;
    wire sample_group_ready;
    wire [31:0] groups_attempted;
    wire source_done;
    (* ASYNC_REG = "TRUE" *) reg [2:0] demo_rst_sync;
    wire demo_rst = demo_rst_sync[2];

    clock_reset_ctrl #(
        .PHY_RESET_CYCLES(2500000),
        .TXC_PHASE_MDEG(TXC_PHASE_MDEG)
    ) u_clock_reset (
        .clk32m(clk32m), .fpga_nrst(sw1_n), .clk32(clk32),
        .clk125(clk125), .clk125_90(clk125_90), .clk200(clk200),
        .rst(rst), .phy_nrst(phy_nrst), .mmcm_locked(mmcm_locked)
    );

    // Reset for acquisition logic: asynchronous assertion, synchronous
    // release in sample_clk/clk32 domain.  Real ADC logic should do the same.
    always @(posedge clk32 or posedge rst) begin
        if (rst)
            demo_rst_sync <= 3'b111;
        else
            demo_rst_sync <= {demo_rst_sync[1:0], 1'b0};
    end

    // Demo source: one 384-bit group every 32 clocks = 1 MSPS/channel.
    sample_group_generator #(
        .SAMPLE_DIV(32), .TOTAL_GROUPS(TOTAL_GROUPS)
    ) u_demo_source (
        .clk(clk32), .rst(demo_rst), .enable(sample_group_ready),
        .group_data(sample_group_data), .group_valid(sample_group_valid),
        .groups_attempted(groups_attempted), .done(source_done)
    );

    network_stream_core #(
        .TARGET_IP(TARGET_IP), .TOTAL_GROUPS(TOTAL_GROUPS),
        .GROUPS_PER_PACKET(GROUPS_PER_PACKET), .SAMPLE_RATE(SAMPLE_RATE)
    ) u_network (
        .sample_clk(clk32), .sample_group_data(sample_group_data),
        .sample_group_valid(sample_group_valid),
        .sample_group_ready(sample_group_ready),
        .clk125(clk125), .clk125_90(clk125_90), .clk200(clk200), .rst(rst),
        .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd),
        .rgmii_rx_ctl(rgmii_rx_ctl), .rgmii_txd(rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txc(rgmii_txc),
        .manual_enable(1'b0), .manual_tap(5'd31),
        .manual_align(3'd0), .rescan(1'b0)
    );
endmodule

`default_nettype wire
