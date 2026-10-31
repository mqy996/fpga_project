`timescale 1ns / 1ps
`default_nettype none

module clock_reset_ctrl #(
    parameter integer PHY_RESET_CYCLES = 2500000,
    // Delay release of all user logic until the input oscillator and MMCM
    // have remained stable for 1 ms (32,000 cycles at 32 MHz).
    parameter integer CLOCK_STABLE_CYCLES = 32000,
    // RGMII TXC phase in one-thousandth of a degree.  Integer form keeps
    // Vivado batch generics reliable while the primitive receives a real.
    parameter integer TXC_PHASE_MDEG = 90000
)(
    input  wire clk32m,
    output wire clk32,
    output wire clk125,
    output wire clk125_90,
    output wire clk200,
    output wire rst_async,
    output wire rst32,
    output wire rst125,
    output wire rst125_90,
    output wire rst200,
    output reg  phy_nrst,
    output wire mmcm_locked
);
    wire clk32_ibuf;
    wire clkfb_mmcm, clkfb_buf;
    wire clk125_mmcm, clk125_90_mmcm, clk200_mmcm;
    reg [31:0] phy_reset_count = 0;
    reg [31:0] stable_count_32 = 0;
    reg stable_32 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] stable_125 = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] stable_125_90 = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] stable_200 = 2'b00;

    IBUF #(.IBUF_LOW_PWR("FALSE"), .IOSTANDARD("LVCMOS33"))
    u_ibuf (.I(clk32m), .O(clk32_ibuf));

    // VCO = 32 MHz * 31.25 = 1000 MHz.
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"), .CLKFBOUT_MULT_F(31.250),
        .CLKIN1_PERIOD(31.250), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.000),
        .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(TXC_PHASE_MDEG / 1000.0),
        .CLKOUT2_DIVIDE(5), .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(clk32_ibuf), .CLKFBIN(clkfb_buf), .RST(1'b0),
        .PWRDWN(1'b0), .CLKFBOUT(clkfb_mmcm),
        .CLKOUT0(clk125_mmcm), .CLKOUT1(clk125_90_mmcm),
        .CLKOUT2(clk200_mmcm), .LOCKED(mmcm_locked),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
    );

    BUFG u_fb (.I(clkfb_mmcm), .O(clkfb_buf));
    BUFG u_32 (.I(clk32_ibuf), .O(clk32));
    BUFG u_125 (.I(clk125_mmcm), .O(clk125));
    BUFG u_125_90 (.I(clk125_90_mmcm), .O(clk125_90));
    BUFG u_200 (.I(clk200_mmcm), .O(clk200));

    assign rst_async = ~mmcm_locked;

    wire base_rst32, base_rst125, base_rst125_90, base_rst200;
    reset_sync u_rst32 (
        .clk(clk32), .arst(rst_async), .srst(base_rst32));
    reset_sync u_rst125 (
        .clk(clk125), .arst(rst_async), .srst(base_rst125));
    reset_sync u_rst125_90 (
        .clk(clk125_90), .arst(rst_async), .srst(base_rst125_90));
    reset_sync u_rst200 (
        .clk(clk200), .arst(rst_async), .srst(base_rst200));

    // This counter is independent of the user-domain reset outputs.  It can
    // therefore hold those outputs asserted while the MMCM clock trees settle.
    always @(posedge clk32 or posedge rst_async) begin
        if (rst_async) begin
            stable_count_32 <= 0;
            stable_32 <= 1'b0;
        end else if (!stable_32) begin
            if (stable_count_32 >= CLOCK_STABLE_CYCLES-1) begin
                stable_32 <= 1'b1;
            end else begin
                stable_count_32 <= stable_count_32 + 1'b1;
            end
        end
    end

    // Synchronize the stable indication into every generated-clock domain.
    always @(posedge clk125 or posedge rst_async) begin
        if (rst_async) stable_125 <= 2'b00;
        else stable_125 <= {stable_125[0],stable_32};
    end
    always @(posedge clk125_90 or posedge rst_async) begin
        if (rst_async) stable_125_90 <= 2'b00;
        else stable_125_90 <= {stable_125_90[0],stable_32};
    end
    always @(posedge clk200 or posedge rst_async) begin
        if (rst_async) stable_200 <= 2'b00;
        else stable_200 <= {stable_200[0],stable_32};
    end

    assign rst32 = base_rst32 || !stable_32;
    assign rst125 = base_rst125 || !stable_125[1];
    assign rst125_90 = base_rst125_90 || !stable_125_90[1];
    assign rst200 = base_rst200 || !stable_200[1];

    always @(posedge clk125) begin
        if (rst125) begin phy_reset_count <= 0; phy_nrst <= 0; end
        else if (!phy_nrst) begin
            if (phy_reset_count >= PHY_RESET_CYCLES-1) phy_nrst <= 1;
            else phy_reset_count <= phy_reset_count + 1'b1;
        end
    end
endmodule

`default_nettype wire
