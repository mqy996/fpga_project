`timescale 1ns / 1ps
`default_nettype none

// Receives Ethernet frames after RGMII conversion.  Bytes are stored from the
// destination MAC at address zero.  A reply request is published only after
// the complete frame and all relevant checksums have passed.
module ping_rx_engine #(
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01
)(
    input wire [31:0] local_ip,
    input wire [31:0] target_ip,
    input  wire        rx_clk,
    input  wire        rx_rst,
    // Configuration changes invalidate the learned destination MAC.  This
    // pulse is synchronized into the RXC domain by the network core.
    input  wire        clear_arp_learn,
    input  wire        frame_start,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_er,

    output reg         ram_wr_en,
    output reg  [10:0] ram_wr_addr,
    output reg  [7:0]  ram_wr_data,

    output reg         request_send,
    input  wire        request_received,
    output reg  [1:0]  request_type,       // 1=ARP, 2=ICMP
    output reg  [47:0] request_src_mac,
    output reg  [31:0] request_src_ip,
    output reg  [15:0] request_ip_length,
    output reg  [7:0]  request_ip_tos,
    output reg  [15:0] request_ip_id,
    output reg  [15:0] request_ip_flags,
    output reg  [15:0] request_ip_checksum,
    output reg  [15:0] request_icmp_checksum,

    output reg         arp_learn_send,
    input  wire        arp_learn_received,
    output reg  [47:0] arp_learned_mac,

    output wire [1:0]  debug_state,
    output wire [3:0]  debug_preamble_count,
    output wire [10:0] debug_frame_index,
    output wire [31:0] debug_crc,
    output wire [47:0] debug_dst_mac,
    output wire [47:0] debug_src_mac,
    output wire [15:0] debug_ether_type,
    output wire [15:0] debug_arp_htype,
    output wire [15:0] debug_arp_ptype,
    output wire [15:0] debug_arp_oper,
    output wire [31:0] debug_arp_tpa,
    output wire [3:0]  debug_status
);
    localparam [1:0] ST_IDLE = 0, ST_FRAME = 2;
    localparam [31:0] CRC_RESIDUE = 32'hDEBB_20E3;

    reg [1:0] state;
    reg [3:0] preamble_count;
    reg [10:0] frame_index;
    reg capture_frame;
    reg frame_overflow;
    reg rx_error_seen;

    reg request_pending;
    wire request_busy = request_pending;

    reg [31:0] crc_reg;
    wire [31:0] crc_next;
    eth_crc32 u_rx_crc (.crc_in(crc_reg), .data_in(gmii_rxd), .crc_out(crc_next));

    reg [47:0] dst_mac, src_mac;
    reg [15:0] ether_type;
    reg [15:0] arp_htype, arp_ptype, arp_oper;
    reg [7:0] arp_hlen, arp_plen;
    reg [47:0] arp_sha, arp_tha;
    reg [31:0] arp_spa, arp_tpa;
    reg arp_learned_rx;
    reg arp_learn_pending;

    reg [7:0] ip_version_ihl, ip_tos, ip_protocol;
    reg [15:0] ip_total_length, ip_id, ip_flags;
    reg [31:0] ip_src, ip_dst;
    reg [7:0] icmp_type, icmp_code;

    reg [7:0] ip_word_high, ip_reply_word_high;
    reg [7:0] icmp_word_high, reply_word_high;
    reg [31:0] ip_sum, ip_reply_sum, icmp_sum, reply_sum;
    reg ip_checksum_ok, icmp_checksum_ok;
    reg [15:0] reply_checksum;
    reg [31:0] sum_temp;

    function [15:0] fold_sum;
        input [31:0] value;
        reg [31:0] folded;
        begin
            folded = value[15:0] + value[31:16];
            folded = folded[15:0] + folded[31:16];
            fold_sum = folded[15:0];
        end
    endfunction

    // These ports are used only by fpga_ping_debug_top.  The release top
    // leaves them open, so Vivado removes the associated debug routing.
    assign debug_state          = state;
    assign debug_preamble_count = preamble_count;
    assign debug_frame_index    = frame_index;
    assign debug_crc            = crc_reg;
    assign debug_dst_mac        = dst_mac;
    assign debug_src_mac        = src_mac;
    assign debug_ether_type     = ether_type;
    assign debug_arp_htype      = arp_htype;
    assign debug_arp_ptype      = arp_ptype;
    assign debug_arp_oper       = arp_oper;
    assign debug_arp_tpa        = arp_tpa;
    assign debug_status         = {request_busy, capture_frame,
                                   frame_overflow, rx_error_seen};

    always @(posedge rx_clk) begin
        if (rx_rst) begin
            state <= ST_IDLE;
            preamble_count <= 0;
            frame_index <= 0;
            capture_frame <= 0;
            frame_overflow <= 0;
            rx_error_seen <= 0;
            ram_wr_en <= 0;
            ram_wr_addr <= 0;
            ram_wr_data <= 0;
            request_send <= 0;
            request_pending <= 0;
            request_type <= 0;
            request_src_mac <= 0;
            request_src_ip <= 0;
            request_ip_length <= 0;
            request_ip_tos <= 0;
            request_ip_id <= 0;
            request_ip_flags <= 0;
            request_ip_checksum <= 0;
            request_icmp_checksum <= 0;
            arp_learn_send <= 0;
            arp_learn_pending <= 0;
            arp_learned_mac <= 0;
            arp_learned_rx <= 0;
            crc_reg <= 32'hFFFF_FFFF;
            dst_mac <= 0; src_mac <= 0; ether_type <= 0;
            arp_htype <= 0; arp_ptype <= 0; arp_oper <= 0;
            arp_hlen <= 0; arp_plen <= 0; arp_sha <= 0; arp_tha <= 0;
            arp_spa <= 0; arp_tpa <= 0;
            ip_version_ihl <= 0; ip_tos <= 0; ip_protocol <= 0;
            ip_total_length <= 0; ip_id <= 0; ip_flags <= 0;
            ip_src <= 0; ip_dst <= 0; icmp_type <= 0; icmp_code <= 0;
            ip_word_high <= 0; ip_reply_word_high <= 0;
            icmp_word_high <= 0; reply_word_high <= 0;
            ip_sum <= 0; ip_reply_sum <= 0; icmp_sum <= 0; reply_sum <= 0;
            ip_checksum_ok <= 0; icmp_checksum_ok <= 0;
            reply_checksum <= 0; sum_temp <= 0;
        end else begin
            ram_wr_en <= 0;
            if (clear_arp_learn) begin
                // Allow a new validated ARP Reply after SET_CONFIG or
                // RESTORE_DEFAULT.  Previously this RXC-domain latch was
                // only cleared by rx_rst, so re-ARP could never complete.
                arp_learned_rx <= 1'b0;
                arp_learn_pending <= 1'b0;
                arp_learned_mac <= 48'd0;
            end else begin
                if (request_received) begin
                    request_pending <= 1'b0;
                    request_send <= 1'b0;
                end
                if (arp_learn_received) begin
                    arp_learn_pending <= 1'b0;
                    arp_learn_send <= 1'b0;
                end
            end

            case (state)
                ST_IDLE: begin
                    // rgmii_rx_align has already verified seven 0x55 bytes and
                    // the 0xD5 SFD.  The next valid byte is destination MAC[47:40].
                    if (frame_start) begin
                        state <= ST_FRAME;
                        frame_index <= 0;
                        capture_frame <= !request_busy;
                        frame_overflow <= 0;
                        rx_error_seen <= 0;
                        crc_reg <= 32'hFFFF_FFFF;
                        dst_mac <= 0; src_mac <= 0; ether_type <= 0;
                        arp_htype <= 0; arp_ptype <= 0; arp_oper <= 0;
                        arp_hlen <= 0; arp_plen <= 0; arp_sha <= 0; arp_tha <= 0;
                        arp_spa <= 0; arp_tpa <= 0;
                        ip_version_ihl <= 0; ip_tos <= 0; ip_protocol <= 0;
                        ip_total_length <= 0; ip_id <= 0; ip_flags <= 0;
                        ip_src <= 0; ip_dst <= 0; icmp_type <= 0; icmp_code <= 0;
                        ip_sum <= 0; ip_reply_sum <= 0;
                        icmp_sum <= 0; reply_sum <= 0;
                        ip_checksum_ok <= 0; icmp_checksum_ok <= 0;
                        reply_checksum <= 0;
                    end
                end

                ST_FRAME: begin
                    if (gmii_rx_dv) begin
                        if (capture_frame) begin
                            ram_wr_en <= 1;
                            ram_wr_addr <= frame_index;
                            ram_wr_data <= gmii_rxd;
                            crc_reg <= crc_next;
                            if (gmii_rx_er) rx_error_seen <= 1;
                            if (frame_index == 11'd2047) frame_overflow <= 1;
                            else frame_index <= frame_index + 1'b1;

                            case (frame_index)
                                0: dst_mac[47:40] <= gmii_rxd;
                                1: dst_mac[39:32] <= gmii_rxd;
                                2: dst_mac[31:24] <= gmii_rxd;
                                3: dst_mac[23:16] <= gmii_rxd;
                                4: dst_mac[15:8]  <= gmii_rxd;
                                5: dst_mac[7:0]   <= gmii_rxd;
                                6: src_mac[47:40] <= gmii_rxd;
                                7: src_mac[39:32] <= gmii_rxd;
                                8: src_mac[31:24] <= gmii_rxd;
                                9: src_mac[23:16] <= gmii_rxd;
                                10: src_mac[15:8] <= gmii_rxd;
                                11: src_mac[7:0] <= gmii_rxd;
                                12: ether_type[15:8] <= gmii_rxd;
                                13: ether_type[7:0] <= gmii_rxd;
                                14: begin arp_htype[15:8] <= gmii_rxd; ip_version_ihl <= gmii_rxd; end
                                15: begin arp_htype[7:0] <= gmii_rxd; ip_tos <= gmii_rxd; end
                                16: begin arp_ptype[15:8] <= gmii_rxd; ip_total_length[15:8] <= gmii_rxd; end
                                17: begin arp_ptype[7:0] <= gmii_rxd; ip_total_length[7:0] <= gmii_rxd; end
                                18: begin arp_hlen <= gmii_rxd; ip_id[15:8] <= gmii_rxd; end
                                19: begin arp_plen <= gmii_rxd; ip_id[7:0] <= gmii_rxd; end
                                20: begin arp_oper[15:8] <= gmii_rxd; ip_flags[15:8] <= gmii_rxd; end
                                21: begin arp_oper[7:0] <= gmii_rxd; ip_flags[7:0] <= gmii_rxd; end
                                22: arp_sha[47:40] <= gmii_rxd;
                                23: begin arp_sha[39:32] <= gmii_rxd; ip_protocol <= gmii_rxd; end
                                24: arp_sha[31:24] <= gmii_rxd;
                                25: arp_sha[23:16] <= gmii_rxd;
                                26: begin arp_sha[15:8] <= gmii_rxd; ip_src[31:24] <= gmii_rxd; end
                                27: begin arp_sha[7:0] <= gmii_rxd; ip_src[23:16] <= gmii_rxd; end
                                28: begin arp_spa[31:24] <= gmii_rxd; ip_src[15:8] <= gmii_rxd; end
                                29: begin arp_spa[23:16] <= gmii_rxd; ip_src[7:0] <= gmii_rxd; end
                                30: begin arp_spa[15:8] <= gmii_rxd; ip_dst[31:24] <= gmii_rxd; end
                                31: begin arp_spa[7:0] <= gmii_rxd; ip_dst[23:16] <= gmii_rxd; end
                                32: begin arp_tha[47:40] <= gmii_rxd; ip_dst[15:8] <= gmii_rxd; end
                                33: begin arp_tha[39:32] <= gmii_rxd; ip_dst[7:0] <= gmii_rxd; end
                                34: begin arp_tha[31:24] <= gmii_rxd; icmp_type <= gmii_rxd; end
                                35: begin arp_tha[23:16] <= gmii_rxd; icmp_code <= gmii_rxd; end
                                36: arp_tha[15:8] <= gmii_rxd;
                                37: arp_tha[7:0] <= gmii_rxd;
                                38: arp_tpa[31:24] <= gmii_rxd;
                                39: arp_tpa[23:16] <= gmii_rxd;
                                40: arp_tpa[15:8] <= gmii_rxd;
                                41: arp_tpa[7:0] <= gmii_rxd;
                                default: ;
                            endcase

                            // IPv4 header checksum, including its received checksum field.
                            if (frame_index >= 14 && frame_index <= 33) begin
                                if (frame_index[0] == 0) begin
                                    ip_word_high <= gmii_rxd;
                                    // Reply changes TTL/protocol to 16'h4001 and
                                    // clears the checksum field.  Swapping IP
                                    // addresses does not alter the word sum.
                                    if (frame_index == 22)
                                        ip_reply_word_high <= 8'h40;
                                    else if (frame_index == 24)
                                        ip_reply_word_high <= 8'h00;
                                    else
                                        ip_reply_word_high <= gmii_rxd;
                                end else begin
                                    sum_temp = ip_sum + {ip_word_high, gmii_rxd};
                                    ip_sum <= sum_temp;
                                    if (frame_index == 33)
                                        ip_checksum_ok <= (fold_sum(sum_temp) == 16'hFFFF);
                                    if (frame_index == 23)
                                        sum_temp = ip_reply_sum + {ip_reply_word_high, 8'h01};
                                    else if (frame_index == 25)
                                        sum_temp = ip_reply_sum + {ip_reply_word_high, 8'h00};
                                    else
                                        sum_temp = ip_reply_sum + {ip_reply_word_high, gmii_rxd};
                                    ip_reply_sum <= sum_temp;
                                    if (frame_index == 33)
                                        request_ip_checksum <= ~fold_sum(sum_temp);
                                end
                            end

                            // ICMP checksum and, in parallel, checksum for the reply.
                            if (frame_index >= 34 &&
                                frame_index < (14 + ip_total_length)) begin
                                if (frame_index[0] == 0) begin
                                    icmp_word_high <= gmii_rxd;
                                    if (frame_index == 34 || frame_index == 36)
                                        reply_word_high <= 8'h00;
                                    else
                                        reply_word_high <= gmii_rxd;
                                end else begin
                                    sum_temp = icmp_sum + {icmp_word_high, gmii_rxd};
                                    icmp_sum <= sum_temp;
                                    if (frame_index == 35 || frame_index == 37)
                                        reply_sum <= reply_sum + 16'h0000;
                                    else
                                        reply_sum <= reply_sum + {reply_word_high, gmii_rxd};
                                end

                                if (frame_index == (14 + ip_total_length - 1)) begin
                                    if (frame_index[0] == 0) begin
                                        sum_temp = icmp_sum + {gmii_rxd, 8'h00};
                                        icmp_checksum_ok <= (fold_sum(sum_temp) == 16'hFFFF);
                                        sum_temp = reply_sum + {gmii_rxd, 8'h00};
                                    end else begin
                                        sum_temp = icmp_sum + {icmp_word_high, gmii_rxd};
                                        icmp_checksum_ok <= (fold_sum(sum_temp) == 16'hFFFF);
                                        if (frame_index == 35 || frame_index == 37)
                                            sum_temp = reply_sum;
                                        else
                                            sum_temp = reply_sum + {reply_word_high, gmii_rxd};
                                    end
                                    reply_checksum <= ~fold_sum(sum_temp);
                                end
                            end
                        end
                    end else begin
                        // crc_reg contains destination MAC through received FCS.
                        if (capture_frame && !frame_overflow && !rx_error_seen &&
                            crc_reg == CRC_RESIDUE) begin
                            // Learn only one fully validated ARP reply.  The
                            // learned MAC remains stable until SW1 reset, so
                            // the toggle safely transfers it to clk125.
                            if (!clear_arp_learn && !arp_learned_rx && !arp_learn_pending &&
                                ether_type == 16'h0806 &&
                                dst_mac == LOCAL_MAC &&
                                arp_htype == 16'h0001 && arp_ptype == 16'h0800 &&
                                arp_hlen == 8'h06 && arp_plen == 8'h04 &&
                                arp_oper == 16'h0002 && arp_spa == target_ip &&
                                arp_tpa == local_ip && arp_tha == LOCAL_MAC &&
                                arp_sha == src_mac) begin
                                arp_learned_mac <= arp_sha;
                                arp_learn_send <= 1'b1;
                                arp_learn_pending <= 1'b1;
                                arp_learned_rx <= 1'b1;
                            end

                            if (!request_busy && ether_type == 16'h0806 &&
                                (dst_mac == 48'hFF_FF_FF_FF_FF_FF || dst_mac == LOCAL_MAC) &&
                                arp_htype == 16'h0001 && arp_ptype == 16'h0800 &&
                                arp_hlen == 8'h06 && arp_plen == 8'h04 &&
                                arp_oper == 16'h0001 && arp_tpa == local_ip) begin
                                request_type <= 1;
                                request_src_mac <= src_mac;
                                request_src_ip <= arp_spa;
                                request_send <= 1'b1;
                                request_pending <= 1'b1;
                            end else if (!request_busy && ether_type == 16'h0800 && dst_mac == LOCAL_MAC &&
                                ip_version_ihl == 8'h45 && ip_total_length >= 28 &&
                                ip_total_length <= 1500 && ip_dst == local_ip &&
                                ip_protocol == 8'h01 && (ip_flags & 16'h3FFF) == 0 &&
                                ip_checksum_ok && icmp_checksum_ok &&
                                icmp_type == 8'h08 && icmp_code == 8'h00) begin
                                request_type <= 2;
                                request_src_mac <= src_mac;
                                request_src_ip <= ip_src;
                                request_ip_length <= ip_total_length;
                                request_ip_tos <= ip_tos;
                                request_ip_id <= ip_id;
                                request_ip_flags <= ip_flags;
                                request_icmp_checksum <= reply_checksum;
                                request_send <= 1'b1;
                                request_pending <= 1'b1;
                            end
                        end
                        state <= ST_IDLE;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
