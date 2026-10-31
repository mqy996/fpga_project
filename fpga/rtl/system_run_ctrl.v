`timescale 1ns / 1ps
`default_nettype none

module system_run_ctrl #(
    parameter integer FLUSH_CYCLES = 16
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       start_pulse,
    input  wire       stop_pulse,
    // One-cycle, already-synchronised software command pulses.  They have
    // exactly the same authority as SW1/SW2; STOP wins when both are present.
    input  wire       software_start_pulse,
    input  wire       software_stop_pulse,
    input  wire       reconfigure_pulse,
    input  wire       adc_init_done,
    input  wire       adc_idle,
    input  wire       adc_error,
    input  wire       arp_valid,
    input  wire       udp_idle,
    input  wire       fifo_ready,
    input  wire       network_error,
    output reg        session_active,
    output reg        fifo_flush_req,
    output reg        adc_stop_req,
    output wire       ready,
    output reg        error,
    output reg [3:0]  state,
    // Completion is returned through run_control_cdc_bridge to the 125 MHz
    // control-plane manager.  Status values match runtime_config_manager.
    output reg        software_command_done,
    output reg [3:0]  software_command_status
);
    localparam [3:0] ST_WAIT = 0, ST_FLUSH_ASSERT = 1, ST_FLUSH_WAIT = 2,
        ST_READY = 3, ST_RUN = 4, ST_STOP_WAIT = 5, ST_ERROR = 6;
    reg [5:0] flush_count;
    reg return_error;

    localparam [3:0] CMD_OK = 4'd0, CMD_INVALID_STATE = 4'd4;

    assign ready = (state == ST_READY);

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_WAIT;
            session_active <= 0;
            fifo_flush_req <= 0;
            adc_stop_req <= 1;
            flush_count <= 0;
            return_error <= 0;
            error <= 0;
            software_command_done <= 1'b0;
            software_command_status <= CMD_OK;
        end else begin
            software_command_done <= 1'b0;
            case (state)
                ST_WAIT: begin
                    session_active <= 0; adc_stop_req <= 1; fifo_flush_req <= 0;
                    if (software_start_pulse || software_stop_pulse) begin
                        software_command_done <= 1'b1;
                        software_command_status <= CMD_INVALID_STATE;
                    end
                    if (adc_error || network_error) begin
                        return_error <= 1; state <= ST_FLUSH_ASSERT;
                    end else if (adc_init_done && arp_valid) begin
                        return_error <= 0; state <= ST_FLUSH_ASSERT;
                    end
                end
                ST_FLUSH_ASSERT: begin
                    session_active <= 0; adc_stop_req <= 1; fifo_flush_req <= 1;
                    if (software_start_pulse || software_stop_pulse) begin
                        software_command_done <= 1'b1;
                        software_command_status <= CMD_INVALID_STATE;
                    end
                    if (flush_count >= FLUSH_CYCLES-1) begin
                        flush_count <= 0; fifo_flush_req <= 0; state <= ST_FLUSH_WAIT;
                    end else flush_count <= flush_count + 1'b1;
                end
                ST_FLUSH_WAIT: begin
                    session_active <= 0; adc_stop_req <= 1; fifo_flush_req <= 0;
                    if (software_start_pulse || software_stop_pulse) begin
                        software_command_done <= 1'b1;
                        software_command_status <= CMD_INVALID_STATE;
                    end
                    if (fifo_ready) begin
                        if (return_error) begin error <= 1; state <= ST_ERROR; end
                        else state <= ST_READY;
                    end
                end
                ST_READY: begin
                    session_active <= 0; adc_stop_req <= 1;
                    if (reconfigure_pulse) begin
                        if (software_start_pulse || software_stop_pulse) begin
                            software_command_done <= 1'b1;
                            software_command_status <= CMD_INVALID_STATE;
                        end
                        state <= ST_WAIT;
                    end else if (adc_error || network_error) begin
                        if (software_start_pulse || software_stop_pulse) begin
                            software_command_done <= 1'b1;
                            software_command_status <= CMD_INVALID_STATE;
                        end
                        return_error <= 1; state <= ST_FLUSH_ASSERT;
                    end else if (stop_pulse || software_stop_pulse) begin
                        // STOP in READY is deliberately idempotent.  A
                        // physical STOP retains its historic FIFO-cleanup
                        // behaviour; a software STOP simply acknowledges.
                        if (software_stop_pulse) begin
                            software_command_done <= 1'b1;
                            software_command_status <= CMD_OK;
                        end
                        if (software_start_pulse) begin
                            software_command_done <= 1'b1;
                            software_command_status <= CMD_INVALID_STATE;
                        end
                        if (stop_pulse) begin
                        return_error <= 0; state <= ST_FLUSH_ASSERT;
                        end
                    end else if (start_pulse || software_start_pulse) begin
                        session_active <= 1; adc_stop_req <= 0; state <= ST_RUN;
                        if (software_start_pulse) begin
                            software_command_done <= 1'b1;
                            software_command_status <= CMD_OK;
                        end
                    end
                end
                ST_RUN: begin
                    fifo_flush_req <= 0;
                    if (adc_error || network_error) begin
                        if (software_start_pulse || software_stop_pulse) begin
                            software_command_done <= 1'b1;
                            software_command_status <= CMD_INVALID_STATE;
                        end
                        session_active <= 0; adc_stop_req <= 1;
                        return_error <= 1; state <= ST_STOP_WAIT;
                    end else if (stop_pulse || software_stop_pulse) begin
                        session_active <= 0; adc_stop_req <= 1;
                        return_error <= 0; state <= ST_STOP_WAIT;
                        if (software_stop_pulse) begin
                            software_command_done <= 1'b1;
                            software_command_status <= CMD_OK;
                        end
                        if (software_start_pulse) begin
                            software_command_done <= 1'b1;
                            software_command_status <= CMD_INVALID_STATE;
                        end
                    end else if (software_start_pulse) begin
                        // START while running is an idempotent success; it
                        // must never reset the active session or SeqNum.
                        software_command_done <= 1'b1;
                        software_command_status <= CMD_OK;
                    end
                end
                ST_STOP_WAIT: begin
                    session_active <= 0; adc_stop_req <= 1;
                    if (software_stop_pulse) begin
                        software_command_done <= 1'b1;
                        software_command_status <= CMD_OK;
                    end else if (software_start_pulse) begin
                        software_command_done <= 1'b1;
                        software_command_status <= CMD_INVALID_STATE;
                    end
                    if (adc_idle && udp_idle) state <= ST_FLUSH_ASSERT;
                end
                ST_ERROR: begin
                    session_active <= 0; adc_stop_req <= 1;
                    fifo_flush_req <= 0; error <= 1; state <= ST_ERROR;
                    if (software_start_pulse || software_stop_pulse) begin
                        software_command_done <= 1'b1;
                        software_command_status <= CMD_INVALID_STATE;
                    end
                end
                default: begin return_error <= 1; state <= ST_FLUSH_ASSERT; end
            endcase
        end
    end
endmodule

`default_nettype wire
