`timescale 1ns / 1ps
`default_nettype none

// Verified network transmit core.  The acquisition side supplies one complete
// 24-channel sample group (CH0 in bits 15:0 ... CH23 in bits 383:368).
module network_stream_core #(
    parameter integer SIMULATION = 0,
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP  = 32'hC0A8_0002,
    parameter [31:0] TARGET_IP = 32'hC0A8_0003,
    parameter integer ARP_START_DELAY_CYCLES = 375000000,
    parameter integer ARP_RETRY_CYCLES = 125000000,
    parameter integer GROUPS_PER_PACKET = 30,
    parameter [31:0] SAMPLE_RATE = 32'd500000
)(
    input  wire       sample_clk,
    input  wire [383:0] sample_group_data,
    input  wire         sample_group_valid,
    output wire         sample_group_ready,
    input  wire         session_active,
    input  wire         fifo_flush_req,
    output wire         fifo_ready,
    output wire         arp_valid_125,
    output wire         arp_valid_32,
    output wire         udp_idle_125,
    output wire         udp_idle_32,
    output reg          session_error,
    output wire [9:0]   debug_fifo_wr_count,
    output wire [9:0]   debug_fifo_rd_count,
    output wire [31:0]  debug_udp_packets_sent,
    input  wire       clk125,
    input  wire       clk125_90,
    input  wire       clk200,
    input  wire       rst_async,
    input  wire       rst32,
    input  wire       rst125,
    input  wire       rst125_90,
    input  wire       rst200,
    input  wire       rgmii_rxc,
    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_txc,

    input  wire       manual_enable,
    input  wire [4:0] manual_tap,
    input  wire [2:0] manual_align,
    input  wire       rescan,

    output wire       debug_rx_clk,
    output wire       debug_rx_ready,
    output wire [4:0] debug_current_tap,
    output wire [4:0] debug_tap_readback,
    output wire [2:0] debug_current_align,
    output wire       debug_cal_locked,
    output wire [3:0] debug_error_count,
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
    output wire       debug_frame_start,
    output wire [7:0] debug_frame_data,
    output wire       debug_frame_valid,
    output wire       debug_frame_good,
    output wire       debug_frame_bad,
    output wire [3:0] debug_align_preamble_count,
    output wire [31:0] debug_align_crc,
    output wire [1:0] debug_parser_state,
    output wire [10:0] debug_frame_index,
    output wire [31:0] debug_parser_crc,
    output wire [47:0] debug_dst_mac,
    output wire [47:0] debug_src_mac,
    output wire [15:0] debug_ether_type,
    output wire [15:0] debug_arp_oper,
    output wire [31:0] debug_arp_tpa,
    output wire       debug_request_toggle,
    output wire [1:0] debug_request_type
);
    wire rx_clk, rx_ready;
    wire frame_start, frame_valid, frame_end;
    wire [7:0] frame_data;
    wire frame_good, frame_bad, rx_rst;
    reg rst125_logic = 1'b1;

    wire ram_wr_en;
    wire [10:0] ram_wr_addr, ram_rd_addr;
    wire [7:0] ram_wr_data, ram_rd_data;
    wire request_send_rx, request_rcv_rx;
    wire request_valid_125, request_done_125;
    wire [1:0] request_type_rx, request_type;
    wire [47:0] request_src_mac_rx, request_src_mac;
    wire [31:0] request_src_ip_rx, request_src_ip;
    wire [15:0] request_ip_length_rx, request_ip_length;
    wire [7:0] request_ip_tos_rx, request_ip_tos;
    wire [15:0] request_ip_id_rx, request_ip_id;
    wire [15:0] request_ip_flags_rx, request_ip_flags;
    wire [15:0] request_ip_checksum_rx, request_ip_checksum;
    wire [15:0] request_icmp_checksum_rx, request_icmp_checksum;
    wire [169:0] request_descriptor_rx, request_descriptor_125;
    wire arp_learn_send_rx, arp_learn_rcv_rx;
    wire arp_learn_valid_125;
    wire [47:0] arp_learned_mac_rx;
    wire [47:0] arp_learned_mac_125;
    reg arp_learn_ack_125;
    reg arp_valid_reg;
    reg [47:0] learned_dst_mac;

    wire [383:0] fifo_group;
    wire fifo_full, fifo_prog_full, fifo_overflow, fifo_wr_busy;
    wire fifo_empty, fifo_underflow, fifo_rd_busy;
    wire [9:0] fifo_wr_count, fifo_rd_count;
    wire fifo_rd_en;
    reg fifo_rd_ready_125;
    wire fifo_rd_ready_32;
    reg fifo_reset_32 = 1'b1;
    wire session_active_125;
    reg session_sync_d;
    wire session_start_125 = session_active_125 && !session_sync_d;

    wire [7:0] reply_data, arp_request_data, control_data, udp_data, mac_data;
    wire reply_valid, reply_ready, reply_last;
    wire arp_request_valid, arp_request_ready, arp_request_last;
    wire control_valid, control_ready, control_last;
    wire udp_valid, udp_ready, udp_last;
    wire mac_valid, mac_ready, mac_last;
    wire udp_busy, udp_batch_done;
    reg udp_idle_reg;
    wire [31:0] udp_packets_sent;
    wire [1:0] control_owner, final_owner;
    wire [7:0] gmii_txd;
    wire gmii_tx_en, gmii_tx_er;
    wire [3:0] unused_preamble;
    wire [15:0] unused_arp_htype, unused_arp_ptype;
    wire [3:0] unused_parser_status;

    // Keep asynchronous assertion at the domain boundary, then use a purely
    // synchronous reset level for protocol state that controls block RAM.
    // This prevents an asynchronously controlled reset source from reaching
    // inferred RAM enable pins while retaining deterministic power-up reset.
    always @(posedge clk125)
        rst125_logic <= rst125;

    cdc_bit_sync #(.INIT(1'b0)) u_sync_arp_valid_32 (
        .dst_clk(sample_clk), .dst_rst(rst32),
        .async_in(arp_valid_reg), .sync_out(arp_valid_32));

    cdc_bit_sync #(.INIT(1'b1)) u_sync_udp_idle_32 (
        .dst_clk(sample_clk), .dst_rst(rst32),
        .async_in(udp_idle_reg), .sync_out(udp_idle_32));

    cdc_bit_sync #(.INIT(1'b0)) u_sync_fifo_rd_ready_32 (
        .dst_clk(sample_clk), .dst_rst(rst32),
        .async_in(fifo_rd_ready_125), .sync_out(fifo_rd_ready_32));

    cdc_bit_sync #(.INIT(1'b0)) u_sync_session_active_125 (
        .dst_clk(clk125), .dst_rst(rst125_logic),
        .async_in(session_active), .sync_out(session_active_125));

    // Backpressure is asserted until ARP learning and FIFO reset complete.
    // A group is accepted only on sample_group_valid && sample_group_ready.
    // Treat prog_full as a warning.  The acquisition valid/ready boundary
    // must pause before full and resume after the UDP packetizer drains data;
    // it must not turn a temporary network stall into a dropped sample group.
    assign sample_group_ready = session_active && arp_valid_32 &&
                                !fifo_reset_32 && !fifo_flush_req &&
                                !fifo_wr_busy && !fifo_full;
    assign fifo_ready = !fifo_flush_req && !fifo_wr_busy && fifo_rd_ready_32;
    assign arp_valid_125 = arp_valid_reg;
    assign udp_idle_125 = udp_idle_reg;
    assign debug_fifo_wr_count = fifo_wr_count;
    assign debug_fifo_rd_count = fifo_rd_count;
    assign debug_udp_packets_sent = udp_packets_sent;

    always @(posedge sample_clk) begin
        if (rst32) begin
            fifo_reset_32 <= 1'b1;
            session_error <= 1'b0;
        end else begin
            fifo_reset_32 <= fifo_flush_req;
            if (fifo_flush_req)
                session_error <= 1'b0;
            else if (fifo_overflow || fifo_underflow)
                session_error <= 1'b1;
        end
    end

    always @(posedge clk125) begin
        if (rst125_logic) begin
            session_sync_d <= 0;
            udp_idle_reg <= 1'b1;
            fifo_rd_ready_125 <= 1'b0;
        end else begin
            session_sync_d <= session_active_125;
            udp_idle_reg <= !udp_busy;
            fifo_rd_ready_125 <= !fifo_rd_busy;
        end
    end

    sample_group_async_fifo u_sample_fifo (
        .rst(fifo_reset_32),
        .wr_clk(sample_clk),
        .wr_en(sample_group_valid && sample_group_ready),
        .din(sample_group_data),
        .full(fifo_full), .prog_full(fifo_prog_full),
        .overflow(fifo_overflow), .wr_data_count(fifo_wr_count),
        .wr_rst_busy(fifo_wr_busy),
        .rd_clk(clk125), .rd_en(fifo_rd_en), .dout(fifo_group),
        .empty(fifo_empty), .underflow(fifo_underflow),
        .rd_data_count(fifo_rd_count), .rd_rst_busy(fifo_rd_busy)
    );

    assign debug_rx_clk = rx_clk;
    assign debug_rx_ready = rx_ready;
    assign debug_frame_start = frame_start;
    assign debug_frame_data = frame_data;
    assign debug_frame_valid = frame_valid;
    assign debug_request_toggle = request_valid_125;
    assign debug_request_type = request_type;

    rgmii_rx_adaptive #(.SIMULATION(SIMULATION)) u_rx (
        .rst_async(rst_async), .rst200(rst200), .clk200(clk200),
        .rgmii_rxc(rgmii_rxc),
        .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .manual_enable(manual_enable), .manual_tap(manual_tap),
        .manual_align(manual_align), .rescan(rescan),
        .rx_clk(rx_clk), .rx_rst(rx_rst), .rx_ready(rx_ready),
        .frame_start(frame_start), .frame_data(frame_data),
        .frame_valid(frame_valid), .frame_end(frame_end),
        .current_tap(debug_current_tap),
        .tap_readback(debug_tap_readback),
        .current_align(debug_current_align),
        .calibration_locked(debug_cal_locked),
        .error_count(debug_error_count),
        .debug_raw_rise(debug_raw_rise), .debug_raw_fall(debug_raw_fall),
        .debug_raw_byte(debug_raw_byte), .debug_raw_dv(debug_raw_dv),
        .debug_raw_er(debug_raw_er),
        .debug_candidate0(debug_candidate0), .debug_candidate1(debug_candidate1),
        .debug_candidate2(debug_candidate2), .debug_candidate3(debug_candidate3),
        .debug_candidate4(debug_candidate4), .debug_candidate5(debug_candidate5),
        .debug_preamble_count(debug_align_preamble_count),
        .debug_crc(debug_align_crc), .debug_frame_good(frame_good),
        .debug_frame_bad(frame_bad)
    );
    assign debug_frame_good = frame_good;
    assign debug_frame_bad = frame_bad;

    ping_rx_engine #(
        .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP), .TARGET_IP(TARGET_IP)
    ) u_parser (
        .rx_clk(rx_clk), .rx_rst(rx_rst), .clear_arp_learn(1'b0),
        .frame_start(frame_start),
        .gmii_rxd(frame_data), .gmii_rx_dv(frame_valid), .gmii_rx_er(1'b0),
        .ram_wr_en(ram_wr_en), .ram_wr_addr(ram_wr_addr),
        .ram_wr_data(ram_wr_data),
        .request_send(request_send_rx), .request_received(request_rcv_rx),
        .request_type(request_type_rx), .request_src_mac(request_src_mac_rx),
        .request_src_ip(request_src_ip_rx),
        .request_ip_length(request_ip_length_rx),
        .request_ip_tos(request_ip_tos_rx), .request_ip_id(request_ip_id_rx),
        .request_ip_flags(request_ip_flags_rx),
        .request_ip_checksum(request_ip_checksum_rx),
        .request_icmp_checksum(request_icmp_checksum_rx),
        .arp_learn_send(arp_learn_send_rx),
        .arp_learn_received(arp_learn_rcv_rx),
        .arp_learned_mac(arp_learned_mac_rx),
        .debug_state(debug_parser_state),
        .debug_preamble_count(unused_preamble),
        .debug_frame_index(debug_frame_index),
        .debug_crc(debug_parser_crc), .debug_dst_mac(debug_dst_mac),
        .debug_src_mac(debug_src_mac), .debug_ether_type(debug_ether_type),
        .debug_arp_htype(unused_arp_htype),
        .debug_arp_ptype(unused_arp_ptype), .debug_arp_oper(debug_arp_oper),
        .debug_arp_tpa(debug_arp_tpa), .debug_status(unused_parser_status)
    );

    assign request_descriptor_rx = {
        request_type_rx, request_src_mac_rx, request_src_ip_rx,
        request_ip_length_rx, request_ip_tos_rx, request_ip_id_rx,
        request_ip_flags_rx, request_ip_checksum_rx,
        request_icmp_checksum_rx
    };

    assign {
        request_type, request_src_mac, request_src_ip,
        request_ip_length, request_ip_tos, request_ip_id,
        request_ip_flags, request_ip_checksum, request_icmp_checksum
    } = request_descriptor_125;

    // Coherent descriptor transfer.  Source data remains stable while
    // request_send_rx is outstanding; destination acknowledges only after the
    // complete ARP/ICMP reply has left the reply stream.
    xpm_cdc_handshake #(
        .DEST_EXT_HSK(1), .DEST_SYNC_FF(2), .INIT_SYNC_FF(1),
        .SIM_ASSERT_CHK(1), .SRC_SYNC_FF(2), .WIDTH(170)
    ) u_request_descriptor_cdc (
        .src_clk(rx_clk), .src_in(request_descriptor_rx),
        .src_send(request_send_rx), .src_rcv(request_rcv_rx),
        .dest_clk(clk125), .dest_out(request_descriptor_125),
        .dest_req(request_valid_125), .dest_ack(request_done_125)
    );

    // The learned destination MAC is a separate one-shot coherent transfer.
    xpm_cdc_handshake #(
        .DEST_EXT_HSK(1), .DEST_SYNC_FF(2), .INIT_SYNC_FF(1),
        .SIM_ASSERT_CHK(1), .SRC_SYNC_FF(2), .WIDTH(48)
    ) u_arp_mac_cdc (
        .src_clk(rx_clk), .src_in(arp_learned_mac_rx),
        .src_send(arp_learn_send_rx), .src_rcv(arp_learn_rcv_rx),
        .dest_clk(clk125), .dest_out(arp_learned_mac_125),
        .dest_req(arp_learn_valid_125), .dest_ack(arp_learn_ack_125)
    );

    always @(posedge clk125) begin
        if (rst125_logic) begin
            arp_learn_ack_125 <= 0;
            arp_valid_reg <= 0;
            learned_dst_mac <= 0;
        end else begin
            arp_learn_ack_125 <= 1'b0;
            if (arp_learn_valid_125) begin
                if (!arp_valid_reg) begin
                    learned_dst_mac <= arp_learned_mac_125;
                    arp_valid_reg <= 1'b1;
                end
                arp_learn_ack_125 <= 1'b1;
            end
        end
    end

    frame_ram u_frame_ram (
        .wr_clk(rx_clk), .wr_en(ram_wr_en), .wr_addr(ram_wr_addr),
        .wr_data(ram_wr_data), .rd_clk(clk125), .rd_addr(ram_rd_addr),
        .rd_data(ram_rd_data)
    );

    ping_reply_tx #(.LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP)) u_reply (
        .clk(clk125), .rst(rst125_logic), .request_valid(request_valid_125),
        .request_done(request_done_125), .request_type(request_type),
        .request_src_mac(request_src_mac), .request_src_ip(request_src_ip),
        .request_ip_length(request_ip_length), .request_ip_tos(request_ip_tos),
        .request_ip_id(request_ip_id), .request_ip_flags(request_ip_flags),
        .request_ip_checksum(request_ip_checksum),
        .request_icmp_checksum(request_icmp_checksum),
        .ram_rd_addr(ram_rd_addr), .ram_rd_data(ram_rd_data),
        .tx_data(reply_data), .tx_valid(reply_valid),
        .tx_ready(reply_ready), .tx_last(reply_last)
    );

    arp_request_tx #(
        .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP), .TARGET_IP(TARGET_IP),
        .START_DELAY_CYCLES(ARP_START_DELAY_CYCLES),
        .RETRY_CYCLES(ARP_RETRY_CYCLES)
    ) u_arp_request (
        .clk(clk125), .rst(rst125_logic), .arp_valid(arp_valid_reg),
        .tx_data(arp_request_data), .tx_valid(arp_request_valid),
        .tx_ready(arp_request_ready), .tx_last(arp_request_last)
    );

    fifo_udp_stream_tx #(
        .GROUPS_PER_PACKET(GROUPS_PER_PACKET),
        .SAMPLE_RATE(SAMPLE_RATE),
        .SRC_MAC(LOCAL_MAC), .SRC_IP(LOCAL_IP)
    ) u_udp_batch (
        .clk(clk125), .rst(rst125_logic), .session_reset(session_start_125),
        .enable(arp_valid_reg && session_active_125 && !fifo_rd_busy),
        .dst_mac(learned_dst_mac), .tx_data(udp_data),
        .tx_valid(udp_valid), .tx_ready(udp_ready), .tx_last(udp_last),
        .fifo_data(fifo_group), .fifo_empty(fifo_empty),
        .fifo_count(fifo_rd_count), .fifo_rd_en(fifo_rd_en),
        .busy(udp_busy), .packets_sent(udp_packets_sent),
        .batch_done(udp_batch_done)
    );

    // First stage: protocol replies always beat our active ARP request.
    frame_arbiter_2to1 u_control_arbiter (
        .clk(clk125), .rst(rst125_logic),
        .s0_data(reply_data), .s0_valid(reply_valid),
        .s0_ready(reply_ready), .s0_last(reply_last),
        .s1_data(arp_request_data), .s1_valid(arp_request_valid),
        .s1_ready(arp_request_ready), .s1_last(arp_request_last),
        .m_data(control_data), .m_valid(control_valid),
        .m_ready(control_ready), .m_last(control_last), .owner(control_owner)
    );

    // Second stage: all ARP/ICMP traffic beats UDP.  Both arbiters retain
    // ownership through the last-byte handshake, so frames cannot interleave.
    frame_arbiter_2to1 u_final_arbiter (
        .clk(clk125), .rst(rst125_logic),
        .s0_data(control_data), .s0_valid(control_valid),
        .s0_ready(control_ready), .s0_last(control_last),
        .s1_data(udp_data), .s1_valid(udp_valid),
        .s1_ready(udp_ready), .s1_last(udp_last),
        .m_data(mac_data), .m_valid(mac_valid),
        .m_ready(mac_ready), .m_last(mac_last), .owner(final_owner)
    );

    eth_mac_tx u_mac_tx (
        .clk(clk125), .rst(rst125_logic), .s_data(mac_data),
        .s_valid(mac_valid), .s_ready(mac_ready),
        .s_last(mac_last), .gmii_txd(gmii_txd),
        .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er), .busy()
    );

    rgmii_tx u_rgmii_tx (
        .clk125(clk125), .clk125_90(clk125_90),
        .rst125(rst125), .rst125_90(rst125_90),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er), .rgmii_txd(rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txc(rgmii_txc)
    );
endmodule

`default_nettype wire
