`timescale 1ns / 1ps
`default_nettype none

module fpga_adc_udp_flash_param_top #(
    parameter integer SIMULATION = 0,
    parameter integer CLOCK_STABLE_CYCLES = 32000,
    // Diagnostic-only build option.  When set, the FPGA still boots from
    // QSPI, but the post-configuration user SPI/STARTUPE2 parameter manager is
    // removed.  Default network parameters are handed to the network core.
    // The normal Release build keeps this at zero.
    parameter integer BYPASS_FLASH = 0,
    parameter integer ARP_START_DELAY_CYCLES = 375000000,
    parameter integer ADC_POWERUP_WAIT_CYCLES = 320000,
    parameter integer ADC_SAMPLE_DIV = 64,
    parameter [31:0] UDP_SAMPLE_RATE = 32'd500000,
    parameter integer ADC_PIPELINED_CAPTURE = 1,
    parameter integer DEBUG_FLASH_RETRY = 0
)(
    input  wire clk32m,
    input  wire sw1_n,
    input  wire sw2_n,
    output wire phy_nrst,
    output wire sample_monitor,
    output wire system_status_led_n,
    output wire capture_led_n,
    output wire flash_cs_n,
    inout  wire [3:0] flash_dq,

    input wire rgmii_rxc, input wire [3:0] rgmii_rxd,
    input wire rgmii_rx_ctl, output wire [3:0] rgmii_txd,
    output wire rgmii_tx_ctl, output wire rgmii_txc,

    input wire adc1_busy, input wire adc1_frstdata, inout wire [15:0] adc1_db,
    output wire [2:0] adc1_os,
    output wire adc1_par_ser_sel, adc1_nstby, adc1_range,
    output wire adc1_convst, adc1_rst, adc1_ncs, adc1_nwr, adc1_nrd,

    input wire adc2_busy, input wire adc2_frstdata, inout wire [15:0] adc2_db,
    output wire [2:0] adc2_os,
    output wire adc2_par_ser_sel, adc2_nstby, adc2_range,
    output wire adc2_convst, adc2_rst, adc2_ncs, adc2_nwr, adc2_nrd,

    input wire adc3_busy, input wire adc3_frstdata, inout wire [15:0] adc3_db,
    output wire [2:0] adc3_os,
    output wire adc3_par_ser_sel, adc3_nstby, adc3_range,
    output wire adc3_convst, adc3_rst, adc3_ncs, adc3_nwr, adc3_nrd
);
    wire clk32, clk125, clk125_90, clk200, mmcm_locked;
    wire rst_async, rst32, rst125, rst125_90, rst200;
    wire start_pulse, stop_pulse, sw1_stable_n, sw2_stable_n;
    wire [383:0] sample_group_data;
    wire sample_group_valid, sample_group_ready;
    wire adc_init_done, adc_idle, adc_error;
    wire [7:0] adc_error_code;
    wire [2:0] done_mask, debug_sample_valid;
    wire [11:0] debug_capture_state;
    wire sample_start;
    wire session_active, fifo_flush_req, fifo_ready, adc_stop_req;
    wire arp_valid_125, arp_valid_32;
    wire udp_idle_125, udp_idle_32;
    wire network_error, system_ready, system_error;
    wire [3:0] system_state;
    wire led_system_ok;
    wire [9:0] fifo_wr_count, fifo_rd_count;
    wire [31:0] udp_packets_sent;
    wire flash_dq0_o,flash_dq1_i,startup_eos;
    wire flash_boot_done,flash_boot_done_runtime,flash_busy_32,flash_error_32;
    wire [7:0] flash_error_code_32;wire [23:0] flash_jedec_32;
    wire [7:0] flash_error_code_125;wire [23:0] flash_jedec_125;
    wire [223:0] flash_active_cfg_32,boot_cfg_125,save_cfg_125,save_cfg_32,active_cfg_125;
    wire flash_cfg_from_32,boot_valid_125,boot_ready_125,boot_from_125;
    wire [31:0] flash_seq_32,boot_seq_125,save_seq_125;
    wire [1:0] boot_copy_125,flash_copy_runtime_125;
    wire [1:0] flash_copy_32,save_copy_125;
    wire save_req_125,save_req_32,save_done_32,save_done_125;
    wire [3:0] save_status_32,save_status_125;
    wire flash_busy_125,flash_error_125;wire config_reprepare_32;
    wire software_start_pulse_32, software_stop_pulse_32;
    wire software_command_done_32;
    wire [3:0] software_command_status_32;
    wire config_update_125;
    wire [31:0] adc_sample_rate_32;
    wire [7:0] adc_sample_div_32;
    wire adc_rate_update_32;
    reg [7:0] adc_sample_div_125;

    always @(*) begin
        case (active_cfg_125[95:64])
            32'd250000:  adc_sample_div_125 = 8'd128;
            32'd1000000: adc_sample_div_125 = 8'd32;
            default:    adc_sample_div_125 = 8'd64;
        endcase
    end
    localparam [223:0] FLASH_BYPASS_DEFAULT_CONFIG = {
        32'hC0A80002,32'hFFFFFF00,32'hC0A80003,16'd56555,16'd0,
        32'd500000,32'h00FFFFFF,32'd30};
    reg bypass_boot_done_32;
    reg flash_busy_src_32;
    wire flash_dbg_eos_seen,flash_dbg_cs_active,flash_dbg_spi_clk;
    wire flash_dbg_byte_start,flash_dbg_byte_busy,flash_dbg_byte_done;
    wire [6:0] flash_dbg_state,flash_dbg_byte_index;
    wire [7:0] flash_dbg_tx_byte,flash_dbg_rx_byte;
    wire [3:0] flash_dbg_edge_count;
    wire [31:0] flash_dbg_attempt_count;

    // One clk32-wide pulse means that one complete 24-channel sample group
    // was accepted by the asynchronous FIFO. Its repetition frequency is the
    // selected 250/500/1000 kSPS acquisition rate.
    assign sample_monitor = sample_group_valid && sample_group_ready;

    clock_reset_ctrl #(.CLOCK_STABLE_CYCLES(CLOCK_STABLE_CYCLES)) u_clock_reset (
        .clk32m(clk32m), .clk32(clk32), .clk125(clk125),
        .clk125_90(clk125_90), .clk200(clk200),
        .rst_async(rst_async), .rst32(rst32), .rst125(rst125),
        .rst125_90(rst125_90), .rst200(rst200),
        .phy_nrst(phy_nrst), .mmcm_locked(mmcm_locked));

    button_debounce u_start_button (
        .clk(clk32),.rst(rst32),.button_n(sw1_n),
        .press_pulse(start_pulse),.stable_n(sw1_stable_n));
    button_debounce u_stop_button (
        .clk(clk32),.rst(rst32),.button_n(sw2_n),
        .press_pulse(stop_pulse),.stable_n(sw2_stable_n));

    system_run_ctrl u_run_ctrl (
        .clk(clk32),.rst(rst32),.start_pulse(start_pulse),
        .stop_pulse(stop_pulse),.software_start_pulse(software_start_pulse_32),
        .software_stop_pulse(software_stop_pulse_32),
        .reconfigure_pulse(config_reprepare_32),.adc_init_done(adc_init_done && flash_boot_done),
        .adc_idle(adc_idle),.adc_error(adc_error),
        .arp_valid(arp_valid_32),.udp_idle(udp_idle_32),
        .fifo_ready(fifo_ready),.network_error(network_error),
        .session_active(session_active),.fifo_flush_req(fifo_flush_req),
        .adc_stop_req(adc_stop_req),.ready(system_ready),
        .error(system_error),.state(system_state),
        .software_command_done(software_command_done_32),
        .software_command_status(software_command_status_32));

    assign led_system_ok = flash_boot_done && !flash_error_32 &&
                           !adc_error && !network_error && !system_error &&
                           ((system_state == 4'd3) || (system_state == 4'd4));
    led_status_blink #(.SYSTEM_HALF_PERIOD_CYCLES(16000000),
                       .CAPTURE_HALF_PERIOD_CYCLES(8000000)) u_status_led_blink (
        .clk(clk32), .rst(rst32), .system_enable(led_system_ok),
        .capture_enable(session_active && led_system_ok),
        .system_led_n(system_status_led_n), .capture_led_n(capture_led_n));

    adc_capture_24ch #(.SAMPLE_DIV(ADC_SAMPLE_DIV),
        .POWERUP_WAIT_CYCLES(ADC_POWERUP_WAIT_CYCLES),
        .PIPELINED_CAPTURE(ADC_PIPELINED_CAPTURE)) u_adc_capture (
        .clk(clk32),.rst(rst32),.run_enable(session_active),
        .sample_div_runtime(adc_sample_div_32),
        .stop_req(adc_stop_req),.group_data(sample_group_data),
        .group_valid(sample_group_valid),.group_ready(sample_group_ready),
        .init_done(adc_init_done),.capture_idle(adc_idle),
        .error(adc_error),.error_code(adc_error_code),
        .done_mask(done_mask),.sample_start(sample_start),
        .adc1_busy(adc1_busy),.adc1_frstdata(adc1_frstdata),.adc1_db(adc1_db),.adc1_os(adc1_os),
        .adc1_par_ser_sel(adc1_par_ser_sel),.adc1_nstby(adc1_nstby),
        .adc1_range(adc1_range),.adc1_convst(adc1_convst),.adc1_rst(adc1_rst),
        .adc1_ncs(adc1_ncs),.adc1_nwr(adc1_nwr),.adc1_nrd(adc1_nrd),
        .adc2_busy(adc2_busy),.adc2_frstdata(adc2_frstdata),.adc2_db(adc2_db),.adc2_os(adc2_os),
        .adc2_par_ser_sel(adc2_par_ser_sel),.adc2_nstby(adc2_nstby),
        .adc2_range(adc2_range),.adc2_convst(adc2_convst),.adc2_rst(adc2_rst),
        .adc2_ncs(adc2_ncs),.adc2_nwr(adc2_nwr),.adc2_nrd(adc2_nrd),
        .adc3_busy(adc3_busy),.adc3_frstdata(adc3_frstdata),.adc3_db(adc3_db),.adc3_os(adc3_os),
        .adc3_par_ser_sel(adc3_par_ser_sel),.adc3_nstby(adc3_nstby),
        .adc3_range(adc3_range),.adc3_convst(adc3_convst),.adc3_rst(adc3_rst),
        .adc3_ncs(adc3_ncs),.adc3_nwr(adc3_nwr),.adc3_nrd(adc3_nrd),
        .debug_sample_valid(debug_sample_valid),
        .debug_capture_state(debug_capture_state));

    generate
      if (!BYPASS_FLASH) begin : g_flash_runtime
        // DQ0 is MOSI, DQ1 is MISO. DQ2/DQ3 stay high impedance in runtime x1 mode.
        IOBUF u_flash_dq0(.I(flash_dq0_o),.T(1'b0),.O(),.IO(flash_dq[0]));
        IOBUF u_flash_dq1(.I(1'b0),.T(1'b1),.O(flash_dq1_i),.IO(flash_dq[1]));
        IOBUF u_flash_dq2(.I(1'b0),.T(1'b1),.O(),.IO(flash_dq[2]));
        IOBUF u_flash_dq3(.I(1'b0),.T(1'b1),.O(),.IO(flash_dq[3]));

        flash_param_manager #(
            .DEBUG_JEDEC_RETRY(DEBUG_FLASH_RETRY),
            .DEBUG_RETRY_CYCLES(16000000)) u_flash_params(
            .clk(clk32),.rst(rst32),.save_req(save_req_32),.save_config(save_cfg_32),.save_done(save_done_32),
            .save_status(save_status_32),.boot_done(flash_boot_done_runtime),.active_config(flash_active_cfg_32),
            .config_from_flash(flash_cfg_from_32),.active_sequence(flash_seq_32),.active_copy(flash_copy_32),
            .jedec_id(flash_jedec_32),.flash_error(flash_error_32),.flash_error_code(flash_error_code_32),
            .flash_busy(flash_busy_32),.flash_cs_n(flash_cs_n),.flash_dq0(flash_dq0_o),.flash_dq1(flash_dq1_i),.startup_eos(startup_eos),
            .debug_eos_seen(flash_dbg_eos_seen),.debug_state(flash_dbg_state),.debug_cs_active(flash_dbg_cs_active),
            .debug_spi_clk(flash_dbg_spi_clk),.debug_byte_start(flash_dbg_byte_start),.debug_byte_busy(flash_dbg_byte_busy),
            .debug_byte_done(flash_dbg_byte_done),.debug_tx_byte(flash_dbg_tx_byte),.debug_rx_byte(flash_dbg_rx_byte),
            .debug_edge_count(flash_dbg_edge_count),.debug_byte_index(flash_dbg_byte_index),
            .debug_jedec_attempt_count(flash_dbg_attempt_count));
      end else begin : g_flash_bypass
        // Keep every configuration-flash user pin released in this build.
        // This isolates QSPI boot and the network clocks from STARTUPE2 and
        // the post-configuration SPI transaction engine.
        IOBUF u_flash_dq0(.I(1'b0),.T(1'b1),.O(),.IO(flash_dq[0]));
        IOBUF u_flash_dq1(.I(1'b0),.T(1'b1),.O(),.IO(flash_dq[1]));
        IOBUF u_flash_dq2(.I(1'b0),.T(1'b1),.O(),.IO(flash_dq[2]));
        IOBUF u_flash_dq3(.I(1'b0),.T(1'b1),.O(),.IO(flash_dq[3]));
        assign flash_cs_n = 1'b1;
        assign flash_dq0_o = 1'b1;
        assign flash_dq1_i = 1'b0;
        assign startup_eos = 1'b0;
        assign flash_dbg_eos_seen = 1'b0;
        assign flash_dbg_state = 7'd10;
        assign flash_dbg_cs_active = 1'b0;
        assign flash_dbg_spi_clk = 1'b0;
        assign flash_dbg_byte_start = 1'b0;
        assign flash_dbg_byte_busy = 1'b0;
        assign flash_dbg_byte_done = 1'b0;
        assign flash_dbg_tx_byte = 8'hff;
        assign flash_dbg_rx_byte = 8'h00;
        assign flash_dbg_edge_count = 4'd0;
        assign flash_dbg_byte_index = 7'd0;
        assign flash_dbg_attempt_count = 32'd0;
        assign flash_active_cfg_32 = FLASH_BYPASS_DEFAULT_CONFIG;
        assign flash_cfg_from_32 = 1'b0;
        assign flash_seq_32 = 32'd0;
        assign flash_copy_32 = 2'd0;
        assign flash_jedec_32 = 24'd0;
        assign flash_error_32 = 1'b0;
        assign flash_error_code_32 = 8'd0;
        assign flash_busy_32 = 1'b0;
        assign save_done_32 = save_req_32;
        assign save_status_32 = 4'd7;
        always @(posedge clk32) begin
          if (rst32) bypass_boot_done_32 <= 1'b0;
          else bypass_boot_done_32 <= 1'b1;
        end
      end
    endgenerate
    assign flash_boot_done = BYPASS_FLASH ? bypass_boot_done_32 : flash_boot_done_runtime;

    flash_config_cdc_bridge u_flash_cdc(
        .clk32(clk32),.rst32(rst32),.clk125(clk125),.rst125(rst125),.flash_boot_done(flash_boot_done),
        .flash_active_config(flash_active_cfg_32),.flash_config_from_flash(flash_cfg_from_32),.flash_active_sequence(flash_seq_32),.flash_active_copy_32(flash_copy_32),
        .boot_config_valid(boot_valid_125),.boot_config_ready(boot_ready_125),.boot_config(boot_cfg_125),.boot_from_flash(boot_from_125),.boot_sequence(boot_seq_125),.boot_copy(boot_copy_125),
        .save_req_125(save_req_125),.save_config_125(save_cfg_125),.flash_save_req_32(save_req_32),.flash_save_config_32(save_cfg_32),
        .flash_save_done_32(save_done_32),.flash_save_status_32(save_status_32),.flash_sequence_32(flash_seq_32),.flash_copy_32(flash_copy_32),
        .save_result_valid_125(save_done_125),.save_status_125(save_status_125),.save_sequence_125(save_seq_125),.save_copy_125(save_copy_125));
    reg [1:0] flash_copy_runtime_reg;
    assign flash_copy_runtime_125 = flash_copy_runtime_reg;
    always @(posedge clk125) begin
        if (rst125) flash_copy_runtime_reg <= 0;
        else if (boot_ready_125) flash_copy_runtime_reg <= boot_copy_125;
        else if (save_done_125 && save_status_125 == 0) flash_copy_runtime_reg <= save_copy_125;
    end
    // Register derived status before the synchronizer.  This prevents glitches
    // from the state-decode expression from entering a CDC chain.
    always @(posedge clk32) begin
        if (rst32) flash_busy_src_32 <= 1'b1;
        else       flash_busy_src_32 <= flash_busy_32;
    end
    cdc_bit_sync #(.INIT(1'b1))u_flash_busy_sync(.dst_clk(clk125),.dst_rst(rst125),.async_in(flash_busy_src_32),.sync_out(flash_busy_125));
    cdc_bit_sync #(.INIT(1'b0))u_flash_error_sync(.dst_clk(clk125),.dst_rst(rst125),.async_in(flash_error_32),.sync_out(flash_error_125));
    xpm_cdc_array_single #(.DEST_SYNC_FF(2),.SRC_INPUT_REG(1),.WIDTH(24)) u_flash_jedec_sync(
        .src_clk(clk32),.src_in(flash_jedec_32),.dest_clk(clk125),.dest_out(flash_jedec_125));
    xpm_cdc_array_single #(.DEST_SYNC_FF(2),.SRC_INPUT_REG(1),.WIDTH(8)) u_flash_error_code_sync(
        .src_clk(clk32),.src_in(flash_error_code_32),.dest_clk(clk125),.dest_out(flash_error_code_125));

    network_flash_control_core #(.SIMULATION(SIMULATION),.ARP_START_DELAY_CYCLES(ARP_START_DELAY_CYCLES)) u_network (
        .sample_clk(clk32),.sample_group_data(sample_group_data),
        .sample_group_valid(sample_group_valid),
        .sample_group_ready(sample_group_ready),
        .session_active(session_active),.fifo_flush_req(fifo_flush_req),
        .system_ready_32(system_ready),.system_state_32(system_state),.adc_error_32(adc_error),
        .boot_config_valid(boot_valid_125),.boot_config_ready(boot_ready_125),.boot_config(boot_cfg_125),.boot_from_flash(boot_from_125),.boot_sequence(boot_seq_125),
        .flash_save_req(save_req_125),.flash_save_config(save_cfg_125),.flash_save_done(save_done_125),
        .flash_save_status(save_status_125),.flash_sequence(save_seq_125),.flash_active_copy(flash_copy_runtime_125),
        .flash_jedec_id(flash_jedec_125),.flash_error(flash_error_125),.flash_error_code(flash_error_code_125),.flash_busy(flash_busy_125),
        .config_reprepare_32(config_reprepare_32),.config_update_125(config_update_125),
        .software_start_pulse_32(software_start_pulse_32),.software_stop_pulse_32(software_stop_pulse_32),
        .software_command_done_32(software_command_done_32),.software_command_status_32(software_command_status_32),
        .active_config_125(active_cfg_125),
        .fifo_ready(fifo_ready),.arp_valid_125(arp_valid_125),
        .arp_valid_32(arp_valid_32), .udp_idle_125(udp_idle_125),
        .udp_idle_32(udp_idle_32),.session_error(network_error),
        .debug_fifo_wr_count(fifo_wr_count),.debug_fifo_rd_count(fifo_rd_count),
        .debug_udp_packets_sent(udp_packets_sent),
        .clk125(clk125),.clk125_90(clk125_90),.clk200(clk200),
        .rst_async(rst_async), .rst32(rst32), .rst125(rst125),
        .rst125_90(rst125_90), .rst200(rst200),
        .rgmii_rxc(rgmii_rxc),.rgmii_rxd(rgmii_rxd),
        .rgmii_rx_ctl(rgmii_rx_ctl),.rgmii_txd(rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl),.rgmii_txc(rgmii_txc),
        .manual_enable(1'b0),.manual_tap(5'd31),
        .manual_align(3'd0),.rescan(1'b0));

    // Runtime sample cadence is transferred as one coherent payload. The
    // destination update is intentionally not used as a free-running clock;
    // adc_capture_24ch latches it only while the session is stopped.
    sample_rate_config_cdc u_sample_rate_cdc (
        .src_clk(clk125), .src_rst(rst125), .src_update(config_update_125),
        .src_sample_rate(active_cfg_125[95:64]),
        .src_sample_div(adc_sample_div_125), .src_busy(),
        .dst_clk(clk32), .dst_rst(rst32),
        .dst_sample_rate(adc_sample_rate_32),
        .dst_sample_div(adc_sample_div_32),
        .dst_update(adc_rate_update_32));

    // Stable hierarchical names used by the debug build Tcl.
    (* KEEP="TRUE" *) wire [3:0] dbg_system_state = system_state;
    (* KEEP="TRUE" *) wire dbg_ready = system_ready;
    (* KEEP="TRUE" *) wire dbg_error = system_error;
    (* KEEP="TRUE" *) wire dbg_start = start_pulse;
    (* KEEP="TRUE" *) wire dbg_stop = stop_pulse;
    (* KEEP="TRUE" *) wire dbg_sample_start = sample_start;
    (* KEEP="TRUE" *) wire [2:0] dbg_sample_valid = debug_sample_valid;
    (* KEEP="TRUE" *) wire [2:0] dbg_done_mask = done_mask;
    (* KEEP="TRUE" *) wire [11:0] dbg_capture_state = debug_capture_state;
    (* KEEP="TRUE" *) wire [7:0] dbg_adc_error_code = adc_error_code;
    // A compact first-three-channel preview keeps the ILA build practical in
    // Vivado 2019.2; the complete 384-bit word remains observable at the FIFO
    // write interface when a wider custom probe is needed.
    (* KEEP="TRUE" *) wire [47:0] dbg_group_preview = sample_group_data[47:0];
    (* KEEP="TRUE" *) wire [9:0] dbg_fifo_wr_count = fifo_wr_count;
    (* KEEP="TRUE" *) wire [9:0] dbg_fifo_rd_count = fifo_rd_count;
    (* KEEP="TRUE" *) wire dbg_arp_valid = arp_valid_125;
    (* KEEP="TRUE" *) wire dbg_udp_idle = udp_idle_125;
    (* KEEP="TRUE" *) wire [31:0] dbg_packets = udp_packets_sent;
    // Stable names consumed by scripts/build_debug.tcl after synthesis.
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_startup_eos = startup_eos;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_eos_seen = flash_dbg_eos_seen;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire [6:0] dbg_flash_state = flash_dbg_state;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_cs_active = flash_dbg_cs_active;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_cs_n = flash_cs_n;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_spi_clk = flash_dbg_spi_clk;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_dq0 = flash_dq0_o;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_dq1 = flash_dq1_i;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_byte_start = flash_dbg_byte_start;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_byte_busy = flash_dbg_byte_busy;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_byte_done = flash_dbg_byte_done;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire [7:0] dbg_flash_tx_byte = flash_dbg_tx_byte;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire [7:0] dbg_flash_rx_byte = flash_dbg_rx_byte;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire [3:0] dbg_flash_edge_count = flash_dbg_edge_count;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire [6:0] dbg_flash_byte_index = flash_dbg_byte_index;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire [23:0] dbg_flash_jedec = flash_jedec_32;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire dbg_flash_error = flash_error_32;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire [7:0] dbg_flash_error_code = flash_error_code_32;
    (* KEEP="TRUE", MARK_DEBUG="TRUE" *) wire [31:0] dbg_flash_attempt_count = flash_dbg_attempt_count;
endmodule

`default_nettype wire
