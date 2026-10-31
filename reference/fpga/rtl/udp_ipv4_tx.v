`timescale 1ns / 1ps
`default_nettype none

module udp_ipv4_tx #(
    parameter [47:0] SRC_MAC        = 48'h02_00_00_00_00_01,
    parameter [31:0] SRC_IP         = 32'hC0A8_0002,
    parameter [31:0] DST_IP         = 32'hC0A8_0003,
    parameter [15:0] SRC_PORT       = 16'd8080,
    parameter [15:0] DST_PORT       = 16'd8080,
    parameter integer PAYLOAD_LENGTH = 480
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [47:0] dst_mac,
    output wire       busy,

    input  wire [7:0] payload_data,
    input  wire       payload_valid,
    output wire       payload_ready,
    input  wire       payload_last,

    output reg  [7:0] tx_data,
    output reg        tx_valid,
    input  wire       tx_ready,
    output reg        tx_last
);

    // Output stream contains the 14-byte Ethernet header, 20-byte IPv4
    // header, 8-byte UDP header and payload.  Preamble/FCS are added later.

    localparam [1:0] ST_IDLE    = 2'd0;
    localparam [1:0] ST_HEADER  = 2'd1;
    localparam [1:0] ST_PAYLOAD = 2'd2;
    localparam [15:0] UDP_LENGTH = PAYLOAD_LENGTH + 8;
    localparam [15:0] IP_LENGTH  = PAYLOAD_LENGTH + 28;
    localparam [15:0] IP_ID      = 16'h0000;

    reg [1:0] state;
    reg [5:0] header_index;
    reg [47:0] dst_mac_latched;
    wire [15:0] ip_checksum;

    // IPv4 checksum for the fixed, non-option IPv4 header used here.
    function [15:0] calc_ipv4_checksum;
        input [15:0] total_length;
        input [15:0] identification;
        input [31:0] source_ip;
        input [31:0] destination_ip;
        reg [31:0] sum;
        begin
            sum = 32'h0000_4500 + total_length + identification +
                  16'h4000 + 16'h4011 + source_ip[31:16] +
                  source_ip[15:0] + destination_ip[31:16] +
                  destination_ip[15:0];
            sum = sum[15:0] + sum[31:16];
            sum = sum[15:0] + sum[31:16];
            calc_ipv4_checksum = ~sum[15:0];
        end
    endfunction

    assign ip_checksum   = calc_ipv4_checksum(IP_LENGTH, IP_ID, SRC_IP, DST_IP);
    assign busy          = (state != ST_IDLE);
    assign payload_ready = (state == ST_PAYLOAD) && tx_ready;

    always @(*) begin
        tx_data  = 8'h00;
        tx_valid = 1'b0;
        tx_last  = 1'b0;

        if (state == ST_HEADER) begin
            tx_valid = 1'b1;
            case (header_index)
                6'd0:  tx_data = dst_mac_latched[47:40];
                6'd1:  tx_data = dst_mac_latched[39:32];
                6'd2:  tx_data = dst_mac_latched[31:24];
                6'd3:  tx_data = dst_mac_latched[23:16];
                6'd4:  tx_data = dst_mac_latched[15:8];
                6'd5:  tx_data = dst_mac_latched[7:0];
                6'd6:  tx_data = SRC_MAC[47:40];
                6'd7:  tx_data = SRC_MAC[39:32];
                6'd8:  tx_data = SRC_MAC[31:24];
                6'd9:  tx_data = SRC_MAC[23:16];
                6'd10: tx_data = SRC_MAC[15:8];
                6'd11: tx_data = SRC_MAC[7:0];
                6'd12: tx_data = 8'h08;
                6'd13: tx_data = 8'h00;
                6'd14: tx_data = 8'h45;
                6'd15: tx_data = 8'h00;
                6'd16: tx_data = IP_LENGTH[15:8];
                6'd17: tx_data = IP_LENGTH[7:0];
                6'd18: tx_data = IP_ID[15:8];
                6'd19: tx_data = IP_ID[7:0];
                6'd20: tx_data = 8'h40;
                6'd21: tx_data = 8'h00;
                6'd22: tx_data = 8'h40;
                6'd23: tx_data = 8'h11;
                6'd24: tx_data = ip_checksum[15:8];
                6'd25: tx_data = ip_checksum[7:0];
                6'd26: tx_data = SRC_IP[31:24];
                6'd27: tx_data = SRC_IP[23:16];
                6'd28: tx_data = SRC_IP[15:8];
                6'd29: tx_data = SRC_IP[7:0];
                6'd30: tx_data = DST_IP[31:24];
                6'd31: tx_data = DST_IP[23:16];
                6'd32: tx_data = DST_IP[15:8];
                6'd33: tx_data = DST_IP[7:0];
                6'd34: tx_data = SRC_PORT[15:8];
                6'd35: tx_data = SRC_PORT[7:0];
                6'd36: tx_data = DST_PORT[15:8];
                6'd37: tx_data = DST_PORT[7:0];
                6'd38: tx_data = UDP_LENGTH[15:8];
                6'd39: tx_data = UDP_LENGTH[7:0];
                6'd40: tx_data = 8'h00;
                6'd41: tx_data = 8'h00;
                default: tx_data = 8'h00;
            endcase
        end else if (state == ST_PAYLOAD) begin
            tx_data  = payload_data;
            tx_valid = payload_valid;
            tx_last  = payload_valid && payload_last;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state        <= ST_IDLE;
            header_index <= 6'd0;
            dst_mac_latched <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    header_index <= 6'd0;
                    if (start) begin
                        dst_mac_latched <= dst_mac;
                        state <= ST_HEADER;
                    end
                end
                ST_HEADER: begin
                    if (tx_valid && tx_ready) begin
                        if (header_index == 6'd41) begin
                            header_index <= 6'd0;
                            state        <= ST_PAYLOAD;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end
                end
                ST_PAYLOAD: begin
                    if (tx_valid && tx_ready && tx_last)
                        state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
