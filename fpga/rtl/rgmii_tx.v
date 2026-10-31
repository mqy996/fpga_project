`timescale 1ns / 1ps
`default_nettype none

module rgmii_tx(
    input  wire       clk125,
    input  wire       clk125_90,
    input  wire       rst125,
    input  wire       rst125_90,
    input  wire [7:0] gmii_txd,
    input  wire       gmii_tx_en,
    input  wire       gmii_tx_er,
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_txc
);
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_txd
            ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
            u_oddr_txd (
                .Q(rgmii_txd[i]), .C(clk125), .CE(1'b1),
                .D1(gmii_txd[i]), .D2(gmii_txd[i+4]), .R(rst125), .S(1'b0)
            );
        end
    endgenerate

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
    u_oddr_ctl (
        .Q(rgmii_tx_ctl), .C(clk125), .CE(1'b1),
        .D1(gmii_tx_en), .D2(gmii_tx_en ^ gmii_tx_er), .R(rst125), .S(1'b0)
    );

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
    u_oddr_txc (
        .Q(rgmii_txc), .C(clk125_90), .CE(1'b1),
        .D1(1'b1), .D2(1'b0), .R(rst125_90), .S(1'b0)
    );
endmodule

`default_nettype wire
