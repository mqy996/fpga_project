`timescale 1ns / 1ps
`default_nettype none

module adc_capture_24ch #(
    parameter integer SAMPLE_DIV = 64,
    parameter integer POWERUP_WAIT_CYCLES = 320000,
    parameter integer PIPELINED_CAPTURE = 1
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         run_enable,
    input  wire         stop_req,
    input  wire [7:0]   sample_div_runtime,
    output reg  [383:0] group_data,
    output reg          group_valid,
    input  wire         group_ready,
    output wire         init_done,
    output wire         capture_idle,
    output reg          error,
    output reg  [7:0]   error_code,
    output reg  [2:0]   done_mask,
    output reg          sample_start,

    input  wire         adc1_busy,
    input  wire         adc1_frstdata,
    inout  wire [15:0]  adc1_db,
    output wire [2:0]   adc1_os,
    output wire adc1_par_ser_sel, adc1_nstby, adc1_range,
    output wire adc1_convst, adc1_rst, adc1_ncs, adc1_nwr, adc1_nrd,

    input  wire         adc2_busy,
    input  wire         adc2_frstdata,
    inout  wire [15:0]  adc2_db,
    output wire [2:0]   adc2_os,
    output wire adc2_par_ser_sel, adc2_nstby, adc2_range,
    output wire adc2_convst, adc2_rst, adc2_ncs, adc2_nwr, adc2_nrd,

    input  wire         adc3_busy,
    input  wire         adc3_frstdata,
    inout  wire [15:0]  adc3_db,
    output wire [2:0]   adc3_os,
    output wire adc3_par_ser_sel, adc3_nstby, adc3_range,
    output wire adc3_convst, adc3_rst, adc3_ncs, adc3_nwr, adc3_nrd,

    output wire [2:0]   debug_sample_valid,
    output wire [11:0]  debug_capture_state
);
    wire [127:0] data1, data2, data3;
    wire valid1, valid2, valid3;
    wire init1, init2, init3;
    wire idle1, idle2, idle3;
    wire ready1, ready2, ready3;
    wire err1, err2, err3;
    wire [7:0] errcode1, errcode2, errcode3;
    wire [3:0] state1, state2, state3;
    reg [7:0] sample_count;
    reg [7:0] sample_div_latched;
    wire [2:0] valid_mask = {valid3, valid2, valid1};

    assign init_done = init1 && init2 && init3;
    assign capture_idle = idle1 && idle2 && idle3 && !group_valid;
    assign debug_sample_valid = valid_mask;
    assign debug_capture_state = {state3,state2,state1};

    always @(posedge clk) begin
        if (rst) begin
            sample_count <= 0;
            sample_div_latched <= (SAMPLE_DIV < 1) ? 8'd1 : SAMPLE_DIV;
            sample_start <= 0;
            done_mask <= 0;
            group_data <= 0;
            group_valid <= 0;
            error <= 0;
            error_code <= 0;
        end else begin
            sample_start <= 0;
            // A running session keeps one divider value. Configuration is
            // accepted while stopped and takes effect on the next START.
            if (!run_enable && !group_valid && sample_div_runtime != 0)
                sample_div_latched <= sample_div_runtime;
            if (err1 || err2 || err3) begin
                error <= 1;
                if (err1)
                    error_code <= (errcode1 == 8'h03) ? 8'h31 : 8'h11;
                else if (err2)
                    error_code <= (errcode2 == 8'h03) ? 8'h32 : 8'h12;
                else
                    error_code <= (errcode3 == 8'h03) ? 8'h33 : 8'h13;
            end

            if (!run_enable || stop_req || error) begin
                sample_count <= 0;
                done_mask <= 0;
                group_valid <= 0;
            end else begin
                if (group_valid && group_ready)
                    group_valid <= 0;

                if (sample_count == 0) begin
                    if (!init_done || !ready1 || !ready2 || !ready3) begin
                        error <= 1;
                        error_code <= 8'h20;
                    end else if (!group_valid && group_ready) begin
                        // Do not launch another conversion while the
                        // completed 384-bit group is waiting for FIFO
                        // acceptance.  This is the acquisition-side
                        // backpressure boundary: a full/blocked FIFO pauses
                        // the cadence instead of dropping a group or
                        // overwriting group_data.
                        sample_start <= 1;
                        done_mask <= 0;
                        if (sample_div_latched > 1)
                            sample_count <= 1;
                        else
                            sample_count <= 0;
                    end
                end else if (sample_count >= sample_div_latched-1'b1) begin
                    sample_count <= 0;
                end else begin
                    sample_count <= sample_count + 1'b1;
                end

                if (valid1) done_mask[0] <= 1;
                if (valid2) done_mask[1] <= 1;
                if (valid3) done_mask[2] <= 1;
                if ((done_mask | valid_mask) == 3'b111) begin
                    if (group_valid) begin
                        error <= 1;
                        error_code <= 8'h21;
                    end else begin
                        group_data <= {data3, data2, data1};
                        group_valid <= 1;
                        done_mask <= 0;
                    end
                end
            end
        end
    end

    ad7606c_device_frontend #(.POWERUP_WAIT_CYCLES(POWERUP_WAIT_CYCLES),
        .PIPELINED_CAPTURE(PIPELINED_CAPTURE)) u_adc1 (
        .clk(clk),.rst(rst),.sample_start(sample_start),.stop(stop_req||error),
        .adc_busy(adc1_busy),.adc_frstdata(adc1_frstdata),.adc_db(adc1_db),.adc_os(adc1_os),
        .adc_par_ser_sel(adc1_par_ser_sel),.adc_nstby(adc1_nstby),
        .adc_range(adc1_range),.adc_convst(adc1_convst),.adc_rst(adc1_rst),
        .adc_ncs(adc1_ncs),.adc_nwr(adc1_nwr),.adc_nrd(adc1_nrd),
        .sample_data(data1),.sample_valid(valid1),.init_done(init1),
        .capture_idle(idle1),.sample_ready(ready1),.error(err1),
        .error_code(errcode1),.capture_state(state1));
    ad7606c_device_frontend #(.POWERUP_WAIT_CYCLES(POWERUP_WAIT_CYCLES),
        .PIPELINED_CAPTURE(PIPELINED_CAPTURE)) u_adc2 (
        .clk(clk),.rst(rst),.sample_start(sample_start),.stop(stop_req||error),
        .adc_busy(adc2_busy),.adc_frstdata(adc2_frstdata),.adc_db(adc2_db),.adc_os(adc2_os),
        .adc_par_ser_sel(adc2_par_ser_sel),.adc_nstby(adc2_nstby),
        .adc_range(adc2_range),.adc_convst(adc2_convst),.adc_rst(adc2_rst),
        .adc_ncs(adc2_ncs),.adc_nwr(adc2_nwr),.adc_nrd(adc2_nrd),
        .sample_data(data2),.sample_valid(valid2),.init_done(init2),
        .capture_idle(idle2),.sample_ready(ready2),.error(err2),
        .error_code(errcode2),.capture_state(state2));
    ad7606c_device_frontend #(.POWERUP_WAIT_CYCLES(POWERUP_WAIT_CYCLES),
        .PIPELINED_CAPTURE(PIPELINED_CAPTURE)) u_adc3 (
        .clk(clk),.rst(rst),.sample_start(sample_start),.stop(stop_req||error),
        .adc_busy(adc3_busy),.adc_frstdata(adc3_frstdata),.adc_db(adc3_db),.adc_os(adc3_os),
        .adc_par_ser_sel(adc3_par_ser_sel),.adc_nstby(adc3_nstby),
        .adc_range(adc3_range),.adc_convst(adc3_convst),.adc_rst(adc3_rst),
        .adc_ncs(adc3_ncs),.adc_nwr(adc3_nwr),.adc_nrd(adc3_nrd),
        .sample_data(data3),.sample_valid(valid3),.init_done(init3),
        .capture_idle(idle3),.sample_ready(ready3),.error(err3),
        .error_code(errcode3),.capture_state(state3));
endmodule

`default_nettype wire
