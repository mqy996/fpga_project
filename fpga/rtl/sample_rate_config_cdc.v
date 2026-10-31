`timescale 1ns/1ps
`default_nettype none

// Coherent transfer of the runtime acquisition cadence from the 125 MHz
// network/configuration domain to the 32 MHz ADC domain.  The payload is held
// until the destination acknowledges it; no configuration bit is synchronized
// independently.
module sample_rate_config_cdc (
    input  wire        src_clk,
    input  wire        src_rst,
    input  wire        src_update,
    input  wire [31:0] src_sample_rate,
    input  wire [7:0]  src_sample_div,
    output wire        src_busy,
    input  wire        dst_clk,
    input  wire        dst_rst,
    output reg  [31:0] dst_sample_rate,
    output reg  [7:0]  dst_sample_div,
    output reg         dst_update
);
    reg [39:0] src_payload;
    reg [39:0] src_pending_payload;
    reg src_pending;
    reg src_send_reg;
    wire src_rcv;
    wire [39:0] dst_payload;
    wire dst_req;
    reg dst_ack;
    reg dst_seen;

    assign src_busy = src_pending || src_send_reg;

    always @(posedge src_clk) begin
        if (src_rst) begin
            src_payload  <= {32'd500000,8'd64};
            src_pending_payload <= {32'd500000,8'd64};
            // The network configuration manager emits a persistent boot
            // update pulse after its own reset release. Do not launch a
            // speculative transfer during the QSPI/clock reset window.
            src_pending  <= 1'b0;
            src_send_reg <= 1'b0;
        end else begin
            if (src_update) begin
                src_pending_payload <= {src_sample_rate,src_sample_div};
                src_pending <= 1'b1;
            end
            if (src_send_reg) begin
                if (src_rcv)
                    src_send_reg <= 1'b0;
            end else if (!src_rcv && src_pending) begin
                src_payload <= src_pending_payload;
                src_pending <= 1'b0;
                src_send_reg <= 1'b1;
            end
        end
    end

    // XPM requires src_send to stay asserted until the destination handshake
    // returns; the held payload is stable for that entire interval.
    wire src_send = src_send_reg;

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_sample_rate <= 32'd500000;
            dst_sample_div  <= 8'd64;
            dst_update      <= 1'b0;
            dst_ack         <= 1'b0;
            dst_seen        <= 1'b0;
        end else begin
            dst_update <= 1'b0;
            if (!dst_req) begin
                dst_ack  <= 1'b0;
                dst_seen <= 1'b0;
            end else if (!dst_seen) begin
                dst_sample_rate <= dst_payload[39:8];
                dst_sample_div  <= dst_payload[7:0];
                dst_update      <= 1'b1;
                dst_ack         <= 1'b1;
                dst_seen        <= 1'b1;
            end
        end
    end

    xpm_cdc_handshake #(
        .DEST_EXT_HSK(1), .DEST_SYNC_FF(2), .INIT_SYNC_FF(1),
        .SIM_ASSERT_CHK(1), .SRC_SYNC_FF(2), .WIDTH(40)
    ) u_rate_cdc (
        .src_clk(src_clk), .src_in(src_payload), .src_send(src_send),
        .src_rcv(src_rcv), .dest_clk(dst_clk), .dest_out(dst_payload),
        .dest_req(dst_req), .dest_ack(dst_ack)
    );
endmodule

`default_nettype wire
