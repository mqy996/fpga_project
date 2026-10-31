`timescale 1ns / 1ps
`default_nettype none

// RGMII receiver for the custom acquisition board.
//
// The four data pins and RX_CTL share one run-time programmable IDELAY value.
// A valid Ethernet FCS locks both the delay tap and byte-alignment mode.
module rgmii_rx_adaptive #(
    parameter integer SIMULATION = 0
)(
    input  wire       rst_async,
    input  wire       rst200,
    input  wire       clk200,
    input  wire       rgmii_rxc,
    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,

    input  wire       manual_enable,
    input  wire [4:0] manual_tap,
    input  wire [2:0] manual_align,
    input  wire       rescan,

    output wire       rx_clk,
    output wire       rx_rst,
    // Registered in the recovered RXC domain before it crosses into the
    // 125 MHz protocol domain.  Keeping this as a flop output avoids feeding
    // combinational receiver-enable logic directly into a CDC synchronizer.
    output reg        rx_ready,
    output wire       frame_start,
    output wire [7:0] frame_data,
    output wire       frame_valid,
    output wire       frame_end,

    output wire [4:0] current_tap,
    output wire [4:0] tap_readback,
    output wire [2:0] current_align,
    output wire       calibration_locked,
    output wire [3:0] error_count,

    output wire [3:0] debug_raw_rise,
    output wire [3:0] debug_raw_fall,
    output wire [7:0] debug_raw_byte,
    output wire       debug_raw_dv,
    output wire       debug_raw_er,
    output wire [7:0] debug_candidate0,
    output wire [7:0] debug_candidate1,
    output wire [7:0] debug_candidate2,
    output wire [7:0] debug_candidate3,
    output wire [7:0] debug_candidate4,
    output wire [7:0] debug_candidate5,
    output wire [3:0] debug_preamble_count,
    output wire [31:0] debug_crc,
    output wire       debug_frame_good,
    output wire       debug_frame_bad
);
    wire rxc_global;
    wire idelay_ready_async;
    wire [3:0] captured_rise;
    wire [3:0] captured_fall;
    wire captured_ctl_rise;
    wire captured_ctl_fall;
    wire [4:0] delay_count0;
    wire [7:0] raw_byte = {captured_fall, captured_rise};
    wire raw_dv = captured_ctl_rise;
    wire raw_er = captured_ctl_rise ^ captured_ctl_fall;

    reg ready_sync1, ready_sync2;
    reg manual_enable_s1, manual_enable_s2, manual_enable_d;
    reg [4:0] manual_tap_s1, manual_tap_s2, manual_tap_d;
    reg [2:0] manual_align_s1, manual_align_s2;
    reg rescan_s1, rescan_s2, rescan_d;

    reg [4:0] tap_reg;
    reg [2:0] align_reg;
    reg       locked_reg;
    reg [3:0] error_reg;
    reg [3:0] settle_count;
    reg       delay_load;

    wire align_frame_good;
    wire align_frame_bad;
    wire [2:0] detected_mode;
    wire force_mode = manual_enable_s2 || locked_reg;
    wire [2:0] forced_mode = manual_enable_s2 ? manual_align_s2 : align_reg;
    wire receiver_enable = ready_sync2 && settle_count == 0 && !delay_load;

    assign rx_clk = rxc_global;
    assign current_tap = tap_reg;
    assign tap_readback = (SIMULATION != 0) ? tap_reg : delay_count0;
    assign current_align = manual_enable_s2 ? manual_align_s2 : align_reg;
    assign calibration_locked = manual_enable_s2 || locked_reg;
    assign error_count = error_reg;

    assign debug_raw_rise = captured_rise;
    assign debug_raw_fall = captured_fall;
    assign debug_raw_byte = raw_byte;
    assign debug_raw_dv = raw_dv;
    assign debug_raw_er = raw_er;
    assign debug_frame_good = align_frame_good;
    assign debug_frame_bad = align_frame_bad;

    generate
        if (SIMULATION != 0) begin : g_sim_capture
            reg [3:0] fall_data;
            reg       fall_ctl;
            reg [3:0] rise_data_reg, fall_data_reg;
            reg       rise_ctl_reg, fall_ctl_reg;

            assign rxc_global = rgmii_rxc;
            assign idelay_ready_async = 1'b1;
            assign captured_rise = rise_data_reg;
            assign captured_fall = fall_data_reg;
            assign captured_ctl_rise = rise_ctl_reg;
            assign captured_ctl_fall = fall_ctl_reg;
            assign delay_count0 = tap_reg;

            reset_sync u_rx_reset (
                .clk(rgmii_rxc), .arst(rst_async), .srst(rx_rst));

            always @(negedge rgmii_rxc or posedge rx_rst) begin
                if (rx_rst) begin fall_data <= 0; fall_ctl <= 0; end
                else begin fall_data <= rgmii_rxd; fall_ctl <= rgmii_rx_ctl; end
            end

            always @(posedge rgmii_rxc or posedge rx_rst) begin
                if (rx_rst) begin
                    rise_data_reg <= 0; fall_data_reg <= 0;
                    rise_ctl_reg <= 0; fall_ctl_reg <= 0;
                end else begin
                    rise_data_reg <= rgmii_rxd;
                    fall_data_reg <= fall_data;
                    rise_ctl_reg <= rgmii_rx_ctl;
                    fall_ctl_reg <= fall_ctl;
                end
            end
        end else begin : g_hw_capture
            wire [3:0] delayed_data;
            wire delayed_ctl;
            wire [4:0] unused_count1, unused_count2, unused_count3;

            BUFG u_rxc_bufg (.I(rgmii_rxc), .O(rxc_global));

            reset_sync u_rx_reset (
                .clk(rxc_global), .arst(rst_async), .srst(rx_rst));

            (* IODELAY_GROUP = "reference_ping_rx" *)
            IDELAYCTRL u_idelayctrl (
                .REFCLK(clk200), .RST(rst200), .RDY(idelay_ready_async)
            );

            genvar i;
            for (i = 0; i < 4; i = i + 1) begin : g_data
                wire [4:0] count_value;
                (* IODELAY_GROUP = "reference_ping_rx" *)
                IDELAYE2 #(
                    .IDELAY_TYPE("VAR_LOAD"), .IDELAY_VALUE(31),
                    .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA")
                ) u_delay (
                    .DATAOUT(delayed_data[i]), .IDATAIN(rgmii_rxd[i]),
                    .DATAIN(1'b0), .C(rxc_global), .CE(1'b0), .INC(1'b0),
                    .LD(delay_load), .LDPIPEEN(1'b0), .REGRST(1'b0),
                    .CINVCTRL(1'b0), .CNTVALUEIN(tap_reg),
                    .CNTVALUEOUT(count_value)
                );
                if (i == 0) begin : g_count0
                    assign delay_count0 = count_value;
                end
                IDDR #(
                    .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                    .SRTYPE("SYNC")
                ) u_iddr (
                    .Q1(captured_rise[i]), .Q2(captured_fall[i]),
                    .C(rxc_global), .CE(1'b1), .D(delayed_data[i]),
                    .R(rx_rst), .S(1'b0)
                );
            end

            (* IODELAY_GROUP = "reference_ping_rx" *)
            IDELAYE2 #(
                .IDELAY_TYPE("VAR_LOAD"), .IDELAY_VALUE(31),
                .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA")
            ) u_ctl_delay (
                .DATAOUT(delayed_ctl), .IDATAIN(rgmii_rx_ctl),
                .DATAIN(1'b0), .C(rxc_global), .CE(1'b0), .INC(1'b0),
                .LD(delay_load), .LDPIPEEN(1'b0), .REGRST(1'b0),
                .CINVCTRL(1'b0), .CNTVALUEIN(tap_reg), .CNTVALUEOUT()
            );
            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .SRTYPE("SYNC")
            ) u_ctl_iddr (
                .Q1(captured_ctl_rise), .Q2(captured_ctl_fall),
                .C(rxc_global), .CE(1'b1), .D(delayed_ctl),
                .R(rx_rst), .S(1'b0)
            );
        end
    endgenerate

    // VIO controls are clocked at 200 MHz in the debug top.  They remain
    // stable between user operations, so two-stage sampling is sufficient.
    always @(posedge rxc_global or posedge rx_rst) begin
        if (rx_rst) begin
            ready_sync1 <= 0; ready_sync2 <= 0;
            rx_ready <= 1'b0;
            manual_enable_s1 <= 0; manual_enable_s2 <= 0;
            manual_enable_d <= 0;
            manual_tap_s1 <= 31; manual_tap_s2 <= 31; manual_tap_d <= 31;
            manual_align_s1 <= 0; manual_align_s2 <= 0;
            rescan_s1 <= 0; rescan_s2 <= 0; rescan_d <= 0;
        end else begin
            ready_sync1 <= idelay_ready_async;
            ready_sync2 <= ready_sync1;
            rx_ready <= receiver_enable;
            manual_enable_s1 <= manual_enable;
            manual_enable_s2 <= manual_enable_s1;
            manual_enable_d <= manual_enable_s2;
            manual_tap_s1 <= manual_tap;
            manual_tap_s2 <= manual_tap_s1;
            manual_tap_d <= manual_tap_s2;
            manual_align_s1 <= manual_align;
            manual_align_s2 <= manual_align_s1;
            rescan_s1 <= rescan;
            rescan_s2 <= rescan_s1;
            rescan_d <= rescan_s2;
        end
    end

    always @(posedge rxc_global or posedge rx_rst) begin
        if (rx_rst) begin
            tap_reg <= 31;
            align_reg <= 0;
            locked_reg <= 0;
            error_reg <= 0;
            settle_count <= 15;
            delay_load <= 0;
        end else begin
            delay_load <= 0;
            if (settle_count != 0)
                settle_count <= settle_count - 1'b1;

            if (rescan_s2 && !rescan_d) begin
                tap_reg <= 31;
                align_reg <= 0;
                locked_reg <= 0;
                error_reg <= 0;
                delay_load <= 1;
                settle_count <= 15;
            end else if (manual_enable_s2 &&
                         (!manual_enable_d || manual_tap_s2 != manual_tap_d)) begin
                tap_reg <= manual_tap_s2;
                locked_reg <= 0;
                error_reg <= 0;
                delay_load <= 1;
                settle_count <= 15;
            end else if (align_frame_good) begin
                error_reg <= 0;
                if (!manual_enable_s2) begin
                    locked_reg <= 1;
                    align_reg <= detected_mode;
                end
            end else if (align_frame_bad) begin
                if (manual_enable_s2) begin
                    if (error_reg != 15) error_reg <= error_reg + 1'b1;
                end else if (!locked_reg) begin
                    tap_reg <= (tap_reg == 0) ? 31 : tap_reg - 1'b1;
                    error_reg <= 0;
                    delay_load <= 1;
                    settle_count <= 15;
                end else if (error_reg == 7) begin
                    locked_reg <= 0;
                    error_reg <= 0;
                    tap_reg <= (tap_reg == 0) ? 31 : tap_reg - 1'b1;
                    delay_load <= 1;
                    settle_count <= 15;
                end else begin
                    error_reg <= error_reg + 1'b1;
                end
            end
        end
    end

    rgmii_rx_align u_align (
        .clk(rxc_global), .rst(rx_rst), .enable(receiver_enable),
        .raw_data(raw_byte), .raw_dv(raw_dv), .raw_er(raw_er),
        .force_mode(force_mode), .forced_mode(forced_mode),
        .frame_start(frame_start), .frame_data(frame_data),
        .frame_valid(frame_valid), .frame_end(frame_end),
        .frame_good(align_frame_good), .frame_bad(align_frame_bad),
        .detected_mode(detected_mode),
        .candidate0(debug_candidate0), .candidate1(debug_candidate1),
        .candidate2(debug_candidate2), .candidate3(debug_candidate3),
        .candidate4(debug_candidate4), .candidate5(debug_candidate5),
        .debug_preamble_count(debug_preamble_count),
        .debug_crc(debug_crc)
    );
endmodule

`default_nettype wire
