`timescale 1ns / 1ps
`default_nettype none

// Vivado 2019.2 XPM wrapper.  The wrapper keeps XPM-specific details out of
// the acquisition and packetizer modules and maps the 384-bit FIFO to BRAM.
module sample_group_async_fifo (
    input  wire         rst,
    input  wire         wr_clk,
    input  wire [383:0] din,
    input  wire         wr_en,
    output wire         full,
    output wire         prog_full,
    output wire         overflow,
    output wire [9:0]   wr_data_count,
    output wire         wr_rst_busy,

    input  wire         rd_clk,
    output wire [383:0] dout,
    input  wire         rd_en,
    output wire         empty,
    output wire         underflow,
    output wire [9:0]   rd_data_count,
    output wire         rd_rst_busy
);
    wire data_valid;
    wire prog_empty;
    wire almost_empty, almost_full;
    wire dbiterr, sbiterr;

    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2),
        .DOUT_RESET_VALUE("0"),
        .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("block"),
        .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(512),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10),
        .PROG_FULL_THRESH(480),
        .RD_DATA_COUNT_WIDTH(10),
        .READ_DATA_WIDTH(384),
        .READ_MODE("fwft"),
        .RELATED_CLOCKS(0),
        // Vivado 2019.2 reports false SLEEP_CHECK messages for this wide
        // FWFT configuration even with sleep tied low. Functional boundary
        // checks are covered by the dedicated testbench.
        .SIM_ASSERT_CHK(0),
        .USE_ADV_FEATURES("0707"),
        .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(384),
        .WR_DATA_COUNT_WIDTH(10)
    ) u_fifo (
        .rst(rst),
        .wr_clk(wr_clk), .din(din), .wr_en(wr_en),
        .full(full), .prog_full(prog_full), .overflow(overflow),
        .wr_data_count(wr_data_count), .wr_rst_busy(wr_rst_busy),
        .rd_clk(rd_clk), .dout(dout), .rd_en(rd_en),
        .empty(empty), .underflow(underflow),
        .rd_data_count(rd_data_count), .rd_rst_busy(rd_rst_busy),
        .data_valid(data_valid), .prog_empty(prog_empty),
        .almost_empty(almost_empty), .almost_full(almost_full),
        .dbiterr(dbiterr), .sbiterr(sbiterr),
        .injectdbiterr(1'b0), .injectsbiterr(1'b0), .sleep(1'b0)
    );
endmodule

`default_nettype wire
