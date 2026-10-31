`timescale 1ns / 1ps
`default_nettype none

// Turns a stable receive descriptor and buffered request into one complete
// Ethernet frame stream (destination MAC through padding, excluding FCS).
module ping_reply_tx #(
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01
)(
    input wire [31:0] local_ip,
    input  wire        clk,
    input  wire        rst,
    input  wire        request_valid,
    output reg         request_done,
    input  wire [1:0]  request_type,
    input  wire [47:0] request_src_mac,
    input  wire [31:0] request_src_ip,
    input  wire [15:0] request_ip_length,
    input  wire [7:0]  request_ip_tos,
    input  wire [15:0] request_ip_id,
    input  wire [15:0] request_ip_flags,
    input  wire [15:0] request_ip_checksum,
    input  wire [15:0] request_icmp_checksum,

    output wire [10:0] ram_rd_addr,
    input  wire [7:0]  ram_rd_data,
    output reg  [7:0]  tx_data,
    output wire        tx_valid,
    input  wire        tx_ready,
    output wire        tx_last
);
    reg request_seen;
    reg active;
    reg [1:0] type_reg;
    reg [47:0] src_mac_reg;
    reg [31:0] src_ip_reg;
    reg [15:0] ip_length_reg, ip_id_reg, ip_flags_reg;
    reg [7:0] ip_tos_reg;
    reg [15:0] ip_checksum_reg, icmp_checksum_reg;
    reg [10:0] byte_index, frame_length;
    reg [7:0] tx_data_next;
    wire [10:0] next_index = byte_index + 1'b1;
    assign tx_valid = active;
    assign tx_last = active && (byte_index == frame_length - 1'b1);

    // ICMP bytes from identifier onward are copied from the receive frame.
    // Address 38 is prefetched throughout the generated headers.
    // The inferred block RAM has a registered, one-cycle read latency.  Keep
    // address 38 prefetched through the ICMP checksum, then look two stream
    // positions ahead so tx_data_next receives the required byte.
    assign ram_rd_addr = (!active || type_reg != 2 || byte_index < 37) ?
                         11'd38 : byte_index + 2'd2;

    always @(*) begin
        tx_data_next = 8'h00;
        begin
            // Common Ethernet header.
            case (next_index)
                0: tx_data_next = src_mac_reg[47:40];
                1: tx_data_next = src_mac_reg[39:32];
                2: tx_data_next = src_mac_reg[31:24];
                3: tx_data_next = src_mac_reg[23:16];
                4: tx_data_next = src_mac_reg[15:8];
                5: tx_data_next = src_mac_reg[7:0];
                6: tx_data_next = LOCAL_MAC[47:40];
                7: tx_data_next = LOCAL_MAC[39:32];
                8: tx_data_next = LOCAL_MAC[31:24];
                9: tx_data_next = LOCAL_MAC[23:16];
                10: tx_data_next = LOCAL_MAC[15:8];
                11: tx_data_next = LOCAL_MAC[7:0];
                12: tx_data_next = 8'h08;
                13: tx_data_next = (type_reg == 1) ? 8'h06 : 8'h00;
                default: begin
                    if (type_reg == 1) begin
                        case (next_index)
                            14: tx_data_next = 8'h00; 15: tx_data_next = 8'h01;
                            16: tx_data_next = 8'h08; 17: tx_data_next = 8'h00;
                            18: tx_data_next = 8'h06; 19: tx_data_next = 8'h04;
                            20: tx_data_next = 8'h00; 21: tx_data_next = 8'h02;
                            22: tx_data_next = LOCAL_MAC[47:40]; 23: tx_data_next = LOCAL_MAC[39:32];
                            24: tx_data_next = LOCAL_MAC[31:24]; 25: tx_data_next = LOCAL_MAC[23:16];
                            26: tx_data_next = LOCAL_MAC[15:8];  27: tx_data_next = LOCAL_MAC[7:0];
                            28: tx_data_next = local_ip[31:24]; 29: tx_data_next = local_ip[23:16];
                            30: tx_data_next = local_ip[15:8];  31: tx_data_next = local_ip[7:0];
                            32: tx_data_next = src_mac_reg[47:40]; 33: tx_data_next = src_mac_reg[39:32];
                            34: tx_data_next = src_mac_reg[31:24]; 35: tx_data_next = src_mac_reg[23:16];
                            36: tx_data_next = src_mac_reg[15:8];  37: tx_data_next = src_mac_reg[7:0];
                            38: tx_data_next = src_ip_reg[31:24]; 39: tx_data_next = src_ip_reg[23:16];
                            40: tx_data_next = src_ip_reg[15:8];  41: tx_data_next = src_ip_reg[7:0];
                            default: tx_data_next = 8'h00;
                        endcase
                    end else begin
                        case (next_index)
                            14: tx_data_next = 8'h45;
                            15: tx_data_next = ip_tos_reg;
                            16: tx_data_next = ip_length_reg[15:8];
                            17: tx_data_next = ip_length_reg[7:0];
                            18: tx_data_next = ip_id_reg[15:8];
                            19: tx_data_next = ip_id_reg[7:0];
                            20: tx_data_next = ip_flags_reg[15:8];
                            21: tx_data_next = ip_flags_reg[7:0];
                            22: tx_data_next = 8'h40;
                            23: tx_data_next = 8'h01;
                            24: tx_data_next = ip_checksum_reg[15:8];
                            25: tx_data_next = ip_checksum_reg[7:0];
                            26: tx_data_next = local_ip[31:24];
                            27: tx_data_next = local_ip[23:16];
                            28: tx_data_next = local_ip[15:8];
                            29: tx_data_next = local_ip[7:0];
                            30: tx_data_next = src_ip_reg[31:24];
                            31: tx_data_next = src_ip_reg[23:16];
                            32: tx_data_next = src_ip_reg[15:8];
                            33: tx_data_next = src_ip_reg[7:0];
                            34: tx_data_next = 8'h00;
                            35: tx_data_next = 8'h00;
                            36: tx_data_next = icmp_checksum_reg[15:8];
                            37: tx_data_next = icmp_checksum_reg[7:0];
                            default: begin
                                if (next_index < 14 + ip_length_reg)
                                    tx_data_next = ram_rd_data;
                                else
                                    tx_data_next = 8'h00;
                            end
                        endcase
                    end
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            request_seen <= 0; request_done <= 0; active <= 0;
            type_reg <= 0; src_mac_reg <= 0; src_ip_reg <= 0;
            ip_length_reg <= 0; ip_tos_reg <= 0; ip_id_reg <= 0;
            ip_flags_reg <= 0; ip_checksum_reg <= 0; icmp_checksum_reg <= 0;
            byte_index <= 0; frame_length <= 0;
            tx_data <= 0;
        end else begin
            // This is the destination acknowledgement of an
            // xpm_cdc_handshake with DEST_EXT_HSK=1.  Keep it high until the
            // source request falls; a one-cycle acknowledgement is unsafe
            // because RXC and clk125 are asynchronous.
            if (!request_valid) begin
                request_seen <= 1'b0;
                request_done <= 1'b0;
            end

            if (!active && request_valid && !request_seen) begin
                active <= 1;
                request_seen <= 1'b1;
                type_reg <= request_type;
                src_mac_reg <= request_src_mac;
                src_ip_reg <= request_src_ip;
                ip_length_reg <= request_ip_length;
                ip_tos_reg <= request_ip_tos;
                ip_id_reg <= request_ip_id;
                ip_flags_reg <= request_ip_flags;
                ip_checksum_reg <= request_ip_checksum;
                icmp_checksum_reg <= request_icmp_checksum;
                byte_index <= 0;
                tx_data <= request_src_mac[47:40];
                if (request_type == 1)
                    frame_length <= 60;
                else if (request_ip_length + 14 < 60)
                    frame_length <= 60;
                else
                    frame_length <= request_ip_length + 14;
            end else if (active && tx_ready) begin
                if (tx_last) begin
                    active <= 0;
                    request_done <= 1'b1;
                    byte_index <= 0;
                end else begin
                    byte_index <= byte_index + 1'b1;
                    tx_data <= tx_data_next;
                end
            end
        end
    end
endmodule

`default_nettype wire
