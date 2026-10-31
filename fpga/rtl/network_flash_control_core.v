`timescale 1ns / 1ps
`default_nettype none

// Verified network transmit core.  The acquisition side supplies one complete
// 24-channel sample group (CH0 in bits 15:0 ... CH23 in bits 383:368).
module network_flash_control_core #(
    parameter integer SIMULATION = 0,
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP = 32'hC0A8_0002,
    parameter [31:0] TARGET_IP = 32'hC0A8_0003,
    parameter integer ARP_START_DELAY_CYCLES = 375000000,
    parameter integer ARP_RETRY_CYCLES = 125000000,
    parameter integer GROUPS_PER_PACKET = 30,
    parameter [31:0] SAMPLE_RATE = 32'd500000,
    // 125 MHz cycles.  If the Flash/CDC path is still incomplete after this
    // interval, the reset-time default configuration is allowed to bring up
    // ARP/ICMP and the control port.  A later valid Flash transfer can still
    // replace the defaults atomically.
    parameter integer BOOT_CONFIG_TIMEOUT_CYCLES = 4000000
)(
    input  wire       sample_clk,
    input  wire [383:0] sample_group_data,
    input  wire         sample_group_valid,
    output wire         sample_group_ready,
    input  wire         session_active,
    input  wire         fifo_flush_req,
    input  wire         system_ready_32,
    input  wire [3:0]   system_state_32,
    input  wire         adc_error_32,
    input  wire         boot_config_valid,
    input  wire         boot_config_ready,
    input  wire [223:0] boot_config,
    input  wire         boot_from_flash,
    input  wire [31:0]  boot_sequence,
    output wire         flash_save_req,
    output wire [223:0] flash_save_config,
    input  wire         flash_save_done,
    input  wire [3:0]   flash_save_status,
    input  wire [31:0]  flash_sequence,
    input  wire [1:0]   flash_active_copy,
    input  wire [23:0]  flash_jedec_id,
    input  wire         flash_error,
    input  wire [7:0]   flash_error_code,
    input  wire         flash_busy,
    output wire         config_reprepare_32,
    // Software START/STOP cross the 125 MHz control plane to the 32 MHz
    // acquisition controller through run_control_cdc_bridge.
    output wire         software_start_pulse_32,
    output wire         software_stop_pulse_32,
    input  wire         software_command_done_32,
    input  wire [3:0]   software_command_status_32,
    // One-cycle pulse in clk125 whenever the boot/runtime configuration has
    // been atomically changed. The top-level rate bridge uses this pulse to
    // transfer the new sample cadence into the 32 MHz ADC domain.
    output wire         config_update_125,
    output wire [223:0] active_config_125,
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
    wire arp_clear_rx;
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

    wire [7:0] reply_data, response_data, arp_request_data, control_data, udp_data, mac_data;
    wire reply_valid, reply_ready, reply_last;
    wire arp_request_valid, arp_request_ready, arp_request_last;
    wire response_valid,response_ready,response_last,response_busy,response_stream_done;
    wire control_valid, control_ready, control_last;
    wire udp_valid, udp_ready, udp_last;
    wire mac_valid, mac_ready, mac_last;
    wire [7:0] final_data;wire final_valid,final_ready,final_last;
    wire udp_busy, udp_batch_done;
    reg udp_idle_reg;
    wire [31:0] udp_packets_sent;
    wire [1:0] control_owner, final_owner;
    wire [7:0] gmii_txd;
    wire gmii_tx_en, gmii_tx_er;
    wire [3:0] unused_preamble;
    wire [15:0] unused_arp_htype, unused_arp_ptype;
    wire [3:0] unused_parser_status;
    wire ctrl_send_rx,ctrl_rcv_rx,ctrl_valid_125,ctrl_done_125;
    wire [47:0] ctrl_smac_rx,ctrl_smac;wire [31:0] ctrl_sip_rx,ctrl_sip;wire [15:0] ctrl_sport_rx,ctrl_sport;
    wire [31:0] ctrl_cmd_rx,ctrl_cmd,ctrl_len_rx,ctrl_len,ctrl_tid_rx,ctrl_tid;
    wire [31:0] req_lip_rx,req_nmask_rx,req_dip_rx,req_rate_rx,req_mask_rx,req_groups_rx;
    wire [15:0] req_dport_rx,req_res_rx;wire [63:0] req_unused_rx;
    wire [223:0] ctrl_cfg_rx,ctrl_cfg;
    wire [415:0] ctrl_desc_rx,ctrl_desc_125;
    wire rsp_start;wire [47:0] rsp_dst_mac;wire [31:0] rsp_dst_ip,rsp_cmd,rsp_status,rsp_tid;wire [15:0] rsp_dst_port,rsp_len;
    // response_stream_done is asserted only when the final byte of this
    // specific control response has completed the frame-locked arbiter
    // handshake.  It is therefore a transaction-local completion event;
    // unlike a global MAC busy edge, it cannot be consumed by adjacent ADC
    // UDP frames.
    reg config_loaded_125;
    reg [31:0] boot_wait_count;
    wire [31:0] diag_frames_rx,diag_fcs_rx,diag_ip_rx,diag_udp_rx,diag_pub_rx,diag_drop_rx;
    wire system_ready_125,adc_error_125;
    wire stopping_125;
    reg system_ready_src_32,stopping_src_32;
    wire [3:0] system_state_125;
    wire config_change_125,arp_clear_125,fifo_reprepare_125;
    wire run_start_req_125,run_stop_req_125,run_command_busy_125;
    wire run_command_done_125;
    wire [3:0] run_command_status_125;
    wire [31:0] cfg_local_ip,cfg_netmask,cfg_target_ip,cfg_sample_rate,cfg_channel_mask,cfg_groups;
    wire [15:0] cfg_target_port,cfg_payload_length;
    wire cfg_from_flash;wire [31:0] cfg_sequence;
    wire [223:0] config_rx;wire config_rx_req,config_rx_rcv;
    reg config_rx_valid;
    reg config_rx_ack;
    reg config_send_pending;
    reg config_send_active;
    wire rx_ready_125;
    // XPM source send must stay high until config_rx_rcv.  The preceding
    // implementation passed only this start pulse to src_send, which is an
    // invalid use of xpm_cdc_handshake and makes the transfer phase-sensitive.
    wire config_send_start = config_send_pending && !config_send_active && rx_ready_125;
    // Before the RXC/IDELAY domain has accepted the first coherent config,
    // parse ARP/ICMP using the fixed startup defaults.  This prevents a lost
    // one-cycle boot pulse from leaving the receive parser with IP=0.
    wire [31:0] rx_local_ip=config_rx_valid ? config_rx[223:192] : LOCAL_IP;
    wire [31:0] rx_netmask=config_rx_valid ? config_rx[191:160] : 32'hFFFFFF00;
    wire [31:0] rx_target_ip=config_rx_valid ? config_rx[159:128] : TARGET_IP;
    assign cfg_local_ip=active_config_125[223:192];
    assign cfg_netmask=active_config_125[191:160];
    assign cfg_target_ip=active_config_125[159:128];
    assign cfg_target_port=active_config_125[127:112];
    assign cfg_sample_rate=active_config_125[95:64];
    assign cfg_channel_mask=active_config_125[63:32];
    assign cfg_groups=active_config_125[31:0];

    // Keep asynchronous assertion at the domain boundary, then use a purely
    // synchronous reset level for protocol state that controls block RAM.
    // This prevents an asynchronously controlled reset source from reaching
    // inferred RAM enable pins while retaining deterministic power-up reset.
    always @(posedge clk125)
        rst125_logic <= rst125;
    always @(posedge clk125)begin
        if(rst125_logic) begin
            config_loaded_125<=1'b0;
            boot_wait_count<=0;
        end else if(boot_config_ready || boot_config_valid) begin
            config_loaded_125<=1'b1;
            boot_wait_count<=0;
        end else if(!config_loaded_125) begin
            if(boot_wait_count < BOOT_CONFIG_TIMEOUT_CYCLES-1)
                boot_wait_count<=boot_wait_count+1'b1;
            else
                config_loaded_125<=1'b1;
        end
    end

    // Keep the configuration transfer pending until the RXC receiver is
    // ready.  The old implementation pulsed src_send at boot, which could
    // occur while rx_rst/IDELAY calibration was still active during QSPI
    // startup.  A level-pending request removes that phase dependency.
    always @(posedge clk125) begin
        if (rst125_logic) begin
            config_send_pending <= 1'b1;
            config_send_active <= 1'b0;
        end else begin
            if (config_change_125) config_send_pending <= 1'b1;
            if (config_send_start) config_send_active <= 1'b1;
            if (config_rx_rcv) begin
                config_send_pending <= 1'b0;
                config_send_active <= 1'b0;
            end
        end
    end

    // Explicit destination acknowledgement for the XPM handshake.  The
    // receive parser consumes the stable descriptor as soon as the request
    // arrives and holds ACK until the source request returns low.
    always @(posedge rx_clk) begin
        if (rx_rst) begin
            config_rx_valid <= 1'b0;
            config_rx_ack <= 1'b0;
        end else begin
            if (!config_rx_req) config_rx_ack <= 1'b0;
            else begin
                config_rx_valid <= 1'b1;
                config_rx_ack <= 1'b1;
            end
        end
    end

    cdc_bit_sync #(.INIT(1'b0)) u_sync_arp_valid_32 (
        .dst_clk(sample_clk), .dst_rst(rst32),
        .async_in(arp_valid_reg), .sync_out(arp_valid_32));

    // rx_ready is generated by the recovered RGMII RXC clock.  It must not
    // be used directly in the 125 MHz configuration-send condition.
    cdc_bit_sync #(.INIT(1'b0)) u_sync_rx_ready_125 (
        .dst_clk(clk125), .dst_rst(rst125_logic),
        .async_in(rx_ready), .sync_out(rx_ready_125));

    cdc_bit_sync #(.INIT(1'b1)) u_sync_udp_idle_32 (
        .dst_clk(sample_clk), .dst_rst(rst32),
        .async_in(udp_idle_reg), .sync_out(udp_idle_32));

    cdc_bit_sync #(.INIT(1'b0)) u_sync_fifo_rd_ready_32 (
        .dst_clk(sample_clk), .dst_rst(rst32),
        .async_in(fifo_rd_ready_125), .sync_out(fifo_rd_ready_32));

    cdc_bit_sync #(.INIT(1'b0)) u_sync_session_active_125 (
        .dst_clk(clk125), .dst_rst(rst125_logic),
        .async_in(session_active), .sync_out(session_active_125));
    always @(posedge sample_clk) begin
        if (rst32) begin
            system_ready_src_32 <= 1'b0;
            stopping_src_32 <= 1'b0;
        end else begin
            system_ready_src_32 <= system_ready_32;
            stopping_src_32 <= (system_state_32 == 4'd5);
        end
    end
    cdc_bit_sync #(.INIT(1'b0)) u_sync_system_ready_125(
        .dst_clk(clk125),.dst_rst(rst125_logic),.async_in(system_ready_src_32),.sync_out(system_ready_125));
    cdc_bit_sync #(.INIT(1'b0)) u_sync_adc_error_125(
        .dst_clk(clk125),.dst_rst(rst125_logic),.async_in(adc_error_32),.sync_out(adc_error_125));
    cdc_bit_sync #(.INIT(1'b0)) u_sync_stopping_125(
        .dst_clk(clk125),.dst_rst(rst125_logic),.async_in(stopping_src_32),.sync_out(stopping_125));
    xpm_cdc_array_single #(.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SIM_ASSERT_CHK(1),.SRC_INPUT_REG(1),.WIDTH(4))u_state_status_cdc(
        .src_clk(sample_clk),.src_in(system_state_32),.dest_clk(clk125),.dest_out(system_state_125));
    cdc_pulse_sync u_cfg_flush_sync(.src_clk(clk125),.src_rst(rst125_logic),.src_pulse(fifo_reprepare_125),
        .dst_clk(sample_clk),.dst_rst(rst32),.dst_pulse(config_reprepare_32));
    run_control_cdc_bridge u_run_control_cdc (
        .src_clk(clk125),.src_rst(rst125_logic),
        .src_start(run_start_req_125),.src_stop(run_stop_req_125),
        .src_busy(run_command_busy_125),.src_done(run_command_done_125),.src_status(run_command_status_125),
        .dst_clk(sample_clk),.dst_rst(rst32),
        .dst_start_pulse(software_start_pulse_32),.dst_stop_pulse(software_stop_pulse_32),
        .dst_done(software_command_done_32),.dst_status(software_command_status_32));
    // The RXC parser has a one-shot learned-MAC latch of its own.  Clear it
    // explicitly when the 125 MHz configuration manager invalidates ARP.
    cdc_pulse_sync u_arp_clear_rx_sync(.src_clk(clk125),.src_rst(rst125_logic),.src_pulse(arp_clear_125),
        .dst_clk(rx_clk),.dst_rst(rx_rst),.dst_pulse(arp_clear_rx));
    runtime_payload_length u_payload_length(.clk(clk125),.rst(rst125_logic),
        .channel_mask(cfg_channel_mask[23:0]),.groups(cfg_groups[4:0]),
        .length(cfg_payload_length));

    // Backpressure is asserted until ARP learning and FIFO reset complete.
    // A group is accepted only on sample_group_valid && sample_group_ready.
    // prog_full is an early-warning level, not a data-loss boundary.  The
    // acquisition side stops launching the next conversion when this ready
    // path is low, and resumes when the packetizer drains the FIFO.  Using
    // full (rather than prog_full) here preserves the last legal slot and
    // prevents an artificial session error during a short network stall.
    assign sample_group_ready = session_active && arp_valid_32 &&
                                !fifo_reset_32 && !fifo_flush_req &&
                                !fifo_wr_busy && !fifo_full;
    assign fifo_ready = !fifo_flush_req && !fifo_wr_busy && fifo_rd_ready_32;
    assign arp_valid_125 = arp_valid_reg;
    assign udp_idle_125 = udp_idle_reg;
    assign config_update_125 = fifo_reprepare_125;
    assign debug_fifo_wr_count = fifo_wr_count;
    assign debug_fifo_rd_count = fifo_rd_count;
    assign debug_udp_packets_sent = udp_packets_sent;

    always @(posedge sample_clk) begin
        if (rst32) begin
            fifo_reset_32 <= 1'b1;
            session_error <= 1'b0;
        end else begin
            fifo_reset_32 <= fifo_flush_req || config_reprepare_32;
            if (fifo_flush_req || config_reprepare_32)
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

    ping_rx_engine #(.LOCAL_MAC(LOCAL_MAC)) u_parser (
        .local_ip(rx_local_ip),.target_ip(rx_target_ip),
        .rx_clk(rx_clk), .rx_rst(rx_rst), .clear_arp_learn(arp_clear_rx),
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

    control_udp_rx_runtime #(.LOCAL_MAC(LOCAL_MAC)) u_control_rx(
        .rx_clk(rx_clk),.rx_rst(rx_rst),.frame_start(frame_start),.local_ip(rx_local_ip),.netmask(rx_netmask),
        .data(frame_data),.valid(frame_valid),.request_send(ctrl_send_rx),.request_received(ctrl_rcv_rx),
        .src_mac(ctrl_smac_rx),.src_ip(ctrl_sip_rx),.src_port(ctrl_sport_rx),.cmd(ctrl_cmd_rx),.status(),
        .length(ctrl_len_rx),.transaction_id(ctrl_tid_rx),.cfg_local_ip(req_lip_rx),.cfg_netmask(req_nmask_rx),
        .cfg_dst_ip(req_dip_rx),.cfg_dst_port(req_dport_rx),.cfg_reserved0(req_res_rx),.cfg_sample_rate(req_rate_rx),
        .cfg_channel_mask(req_mask_rx),.cfg_groups_per_packet(req_groups_rx),.cfg_reserved1(req_unused_rx),
        .diag_frames(diag_frames_rx),.diag_fcs_good(diag_fcs_rx),.diag_ipv4_good(diag_ip_rx),
        .diag_control_udp_good(diag_udp_rx),.diag_commands_published(diag_pub_rx),.diag_busy_drops(diag_drop_rx));
    assign ctrl_cfg_rx={req_lip_rx,req_nmask_rx,req_dip_rx,req_dport_rx,req_res_rx,req_rate_rx,req_mask_rx,req_groups_rx};
    assign ctrl_desc_rx={ctrl_smac_rx,ctrl_sip_rx,ctrl_sport_rx,ctrl_cmd_rx,ctrl_len_rx,ctrl_tid_rx,ctrl_cfg_rx};
    assign {ctrl_smac,ctrl_sip,ctrl_sport,ctrl_cmd,ctrl_len,ctrl_tid,ctrl_cfg}=ctrl_desc_125;
    xpm_cdc_handshake #(.DEST_EXT_HSK(1),.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SIM_ASSERT_CHK(1),.SRC_SYNC_FF(2),.WIDTH(416))u_ctrl_cdc(
        .src_clk(rx_clk),.src_in(ctrl_desc_rx),.src_send(ctrl_send_rx),.src_rcv(ctrl_rcv_rx),
        .dest_clk(clk125),.dest_out(ctrl_desc_125),.dest_req(ctrl_valid_125),.dest_ack(ctrl_done_125));

    // Every configuration image is transferred atomically to the RXC domain.
    xpm_cdc_handshake #(.DEST_EXT_HSK(1),.DEST_SYNC_FF(2),.INIT_SYNC_FF(1),.SIM_ASSERT_CHK(1),.SRC_SYNC_FF(2),.WIDTH(224))u_cfg_to_rx(
        .src_clk(clk125),.src_in(active_config_125),.src_send(config_send_active),.src_rcv(config_rx_rcv),
        .dest_clk(rx_clk),.dest_out(config_rx),.dest_req(config_rx_req),.dest_ack(config_rx_ack));

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
            if (arp_clear_125) begin
                arp_valid_reg <= 1'b0;
                learned_dst_mac <= 0;
                arp_learn_ack_125 <= 1'b0;
            end else if (!arp_learn_valid_125) begin
                // DEST_EXT_HSK requires ACK to return low only after the
                // macro has withdrawn dest_req.
                arp_learn_ack_125 <= 1'b0;
            end else if (arp_learn_valid_125) begin
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

    ping_reply_tx #(.LOCAL_MAC(LOCAL_MAC)) u_reply (
        .local_ip(cfg_local_ip),
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

    runtime_config_manager u_cfg_manager(
        .clk(clk125),.rst(rst125_logic),.boot_config_valid(boot_config_valid),.boot_config_ready(boot_config_ready),.boot_config(boot_config),
        .boot_from_flash(boot_from_flash),.boot_sequence(boot_sequence),.request_valid(ctrl_valid_125),.request_done(ctrl_done_125),
        .request_src_mac(ctrl_smac),.request_src_ip(ctrl_sip),.request_src_port(ctrl_sport),.request_cmd(ctrl_cmd),
        .request_len(ctrl_len),.request_tid(ctrl_tid),.request_config(ctrl_cfg),.system_ready(system_ready_125),
        .session_active(session_active_125),.stopping(stopping_125),.response_mac_done(response_stream_done),
        .run_command_busy(run_command_busy_125),.run_command_done(run_command_done_125),.run_command_status(run_command_status_125),
        .run_start_req(run_start_req_125),.run_stop_req(run_stop_req_125),
        .flash_busy(flash_busy),.flash_error(flash_error),.flash_save_done(flash_save_done),
        .flash_save_status(flash_save_status),.flash_sequence(flash_sequence),.flash_active_copy(flash_active_copy),
        .flash_save_req(flash_save_req),.flash_save_config(flash_save_config),.response_start(rsp_start),
        .response_dst_mac(rsp_dst_mac),.response_dst_ip(rsp_dst_ip),.response_dst_port(rsp_dst_port),
        .response_cmd(rsp_cmd),.response_status(rsp_status),.response_tid(rsp_tid),.response_data_len(rsp_len),
        .active_config(active_config_125),.config_from_flash(cfg_from_flash),.config_sequence(cfg_sequence),
        .config_change_pulse(config_change_125),.arp_clear_pulse(arp_clear_125),.fifo_reprepare_pulse(fifo_reprepare_125));

    control_response_tx_runtime #(.LOCAL_MAC(LOCAL_MAC))u_control_response(
        .clk(clk125),.rst(rst125_logic),.start(rsp_start),.dst_mac(rsp_dst_mac),.dst_ip(rsp_dst_ip),.dst_port(rsp_dst_port),
        .local_ip(cfg_local_ip),.netmask(cfg_netmask),.cmd(rsp_cmd),.status(rsp_status),.transaction_id(rsp_tid),.data_length(rsp_len),
        .device_state({28'd0,system_state_125}),.target_ip(cfg_target_ip),.target_port(cfg_target_port),.sample_rate(cfg_sample_rate),
        .channel_mask(cfg_channel_mask),.groups_per_packet(cfg_groups),.payload_length(cfg_payload_length),.arp_valid(arp_valid_reg),
        .learned_mac(learned_dst_mac),.config_from_flash(cfg_from_flash),.config_sequence(cfg_sequence),.jedec_id(flash_jedec_id),
        .active_copy(flash_active_copy),.flash_error(flash_error),.flash_error_code(flash_error_code),.flash_busy(flash_busy),
        .packets_sent(udp_packets_sent),.fifo_level(fifo_rd_count),.adc_error(adc_error_125),
        .tx_data(response_data),.tx_valid(response_valid),.tx_ready(response_ready),.tx_last(response_last),
        .busy(response_busy),.done(response_stream_done));

    arp_request_runtime #(.LOCAL_MAC(LOCAL_MAC),.RETRY_CYCLES(ARP_RETRY_CYCLES)) u_arp_request (
        .clk(clk125), .rst(rst125_logic), .enable(config_loaded_125),.arp_valid(arp_valid_reg),
        .local_ip(cfg_local_ip),.target_ip(cfg_target_ip),
        .tx_data(arp_request_data), .tx_valid(arp_request_valid),
        .tx_ready(arp_request_ready), .tx_last(arp_request_last)
    );

    fifo_udp_stream_runtime #(.SRC_MAC(LOCAL_MAC)) u_udp_batch (
        .clk(clk125), .rst(rst125_logic), .session_reset(session_start_125),
        .enable(arp_valid_reg && session_active_125 && !fifo_rd_busy),
        .src_ip(cfg_local_ip),.dst_mac(learned_dst_mac),.dst_ip(cfg_target_ip),.dst_port(cfg_target_port),
        .sample_rate(cfg_sample_rate),.channel_mask(cfg_channel_mask),.groups_per_packet(cfg_groups[5:0]),
        .payload_length(cfg_payload_length),.tx_data(udp_data),
        .tx_valid(udp_valid), .tx_ready(udp_ready), .tx_last(udp_last),
        .fifo_data(fifo_group), .fifo_empty(fifo_empty),
        .fifo_count(fifo_rd_count), .fifo_rd_en(fifo_rd_en),
        .busy(udp_busy),.packets_started(),.packets_completed(udp_packets_sent),.sequence_number()
    );

    frame_arbiter_4to1 u_final_arbiter (
        .clk(clk125),.rst(rst125_logic),
        .s0_data(reply_data), .s0_valid(reply_valid),
        .s0_ready(reply_ready), .s0_last(reply_last),
        .s1_data(response_data),.s1_valid(response_valid),.s1_ready(response_ready),.s1_last(response_last),
        .s2_data(arp_request_data),.s2_valid(arp_request_valid),.s2_ready(arp_request_ready),.s2_last(arp_request_last),
        .s3_data(udp_data),.s3_valid(udp_valid),.s3_ready(udp_ready),.s3_last(udp_last),
        .m_data(mac_data), .m_valid(mac_valid),
        .m_ready(mac_ready), .m_last(mac_last), .owner()
    );
    stream_pipeline u_tx_pipeline(.clk(clk125),.rst(rst125_logic),.s_data(mac_data),.s_valid(mac_valid),
        .s_ready(mac_ready),.s_last(mac_last),
        .m_data(final_data),.m_valid(final_valid),.m_ready(final_ready),.m_last(final_last));

    eth_mac_tx u_mac_tx (
        .clk(clk125), .rst(rst125_logic), .s_data(final_data),
        .s_valid(final_valid), .s_ready(final_ready),
        .s_last(final_last), .gmii_txd(gmii_txd),
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
