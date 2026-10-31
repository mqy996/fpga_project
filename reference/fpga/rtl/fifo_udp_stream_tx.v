`timescale 1ns / 1ps
`default_nettype none

module fifo_udp_stream_tx #(
    parameter integer GROUPS_PER_PACKET = 10,
    parameter [31:0] SAMPLE_RATE = 32'd1000000,
    parameter [47:0] SRC_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] SRC_IP  = 32'hC0A8_0002,
    parameter [31:0] DST_IP  = 32'hC0A8_0003,
    parameter [15:0] SRC_PORT = 16'd56555,
    parameter [15:0] DST_PORT = 16'd56555
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         session_reset,
    input  wire         enable,
    input  wire [47:0]  dst_mac,
    input  wire [383:0] fifo_data,
    input  wire         fifo_empty,
    input  wire [9:0]   fifo_count,
    output wire         fifo_rd_en,
    output wire [7:0]   tx_data,
    output wire         tx_valid,
    input  wire         tx_ready,
    output wire         tx_last,
    output wire         busy,
    output reg  [31:0]  packets_sent,
    output wire         batch_done
);
    localparam integer PAYLOAD_LENGTH = 12 + GROUPS_PER_PACKET * 24 * 2;
    reg packet_start;
    reg [31:0] sequence_number;
    wire payload_busy, frame_busy;
    wire [7:0] payload_data;
    wire payload_valid, payload_ready, payload_last;
    wire frame_done = tx_valid && tx_ready && tx_last;

    assign batch_done = 1'b0;
    assign busy = frame_busy || payload_busy;

    always @(posedge clk) begin
        if (rst || session_reset) begin
            packet_start <= 0;
            packets_sent <= 0;
            sequence_number <= 1;
        end else begin
            packet_start <= 1'b0;
            if (frame_done) begin
                packets_sent <= packets_sent + 1'b1;
                sequence_number <= sequence_number + 1'b1;
            end
            if (enable && !frame_busy && !payload_busy &&
                fifo_count >= GROUPS_PER_PACKET)
                packet_start <= 1'b1;
        end
    end

    fifo_udp_payload_gen #(
        .GROUPS_PER_PACKET(GROUPS_PER_PACKET), .SAMPLE_RATE(SAMPLE_RATE)
    ) u_payload (
        .clk(clk), .rst(rst), .start(packet_start),
        .sequence_number(sequence_number), .busy(payload_busy),
        .fifo_data(fifo_data), .fifo_empty(fifo_empty),
        .fifo_rd_en(fifo_rd_en), .data(payload_data),
        .valid(payload_valid), .ready(payload_ready), .last(payload_last)
    );

    udp_ipv4_tx #(
        .SRC_MAC(SRC_MAC), .SRC_IP(SRC_IP), .DST_IP(DST_IP),
        .SRC_PORT(SRC_PORT), .DST_PORT(DST_PORT),
        .PAYLOAD_LENGTH(PAYLOAD_LENGTH)
    ) u_udp (
        .clk(clk), .rst(rst), .start(packet_start), .dst_mac(dst_mac),
        .busy(frame_busy), .payload_data(payload_data),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_last(payload_last), .tx_data(tx_data),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_last(tx_last)
    );
endmodule

`default_nettype wire
