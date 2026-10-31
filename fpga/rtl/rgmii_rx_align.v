`timescale 1ns / 1ps
`default_nettype none

// Rebuilds an Ethernet byte stream from the raw IDDR output.
//
// T11 is not a clock-capable FPGA pin.  The additional clock insertion can
// make one IDDR half-nibble appear one cycle early or late.  Six inexpensive
// candidate streams cover the normal, swapped, and adjacent-cycle pairings.
// A candidate is accepted only after seven 0x55 bytes followed by 0xD5.
module rgmii_rx_align(
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,
    input  wire [7:0] raw_data,
    input  wire       raw_dv,
    input  wire       raw_er,
    input  wire       force_mode,
    input  wire [2:0] forced_mode,

    output reg        frame_start,
    output reg  [7:0] frame_data,
    output reg        frame_valid,
    output reg        frame_end,
    output reg        frame_good,
    output reg        frame_bad,
    output reg  [2:0] detected_mode,

    output wire [7:0] candidate0,
    output wire [7:0] candidate1,
    output wire [7:0] candidate2,
    output wire [7:0] candidate3,
    output wire [7:0] candidate4,
    output wire [7:0] candidate5,
    output reg  [3:0] debug_preamble_count,
    output reg  [31:0] debug_crc
);
    localparam [31:0] CRC_RESIDUE = 32'hDEBB_20E3;

    reg [7:0] raw_previous;
    reg       dv_previous;
    reg       er_previous;
    reg       raw_frame_active;
    reg       aligned_frame_active;
    reg       frame_error_seen;
    reg [2:0] frame_mode;
    reg [3:0] count0, count1, count2, count3, count4, count5;
    reg [31:0] crc_reg;
    reg [7:0] selected_byte;

    // All candidates are normalized to the previous nominal byte time.  This
    // keeps frame_valid aligned even for a candidate using a current nibble.
    assign candidate0 = raw_previous;
    assign candidate1 = {raw_previous[3:0], raw_previous[7:4]};
    assign candidate2 = {raw_data[3:0], raw_previous[7:4]};
    assign candidate3 = {raw_data[7:4], raw_previous[3:0]};
    assign candidate4 = {raw_previous[3:0], raw_data[7:4]};
    assign candidate5 = {raw_previous[7:4], raw_data[3:0]};

    wire [31:0] crc_next;
    eth_crc32 u_crc (
        .crc_in(crc_reg), .data_in(selected_byte), .crc_out(crc_next)
    );

    // Saturating preamble counter update is written as a function so all six
    // candidate detectors have exactly the same behavior.
    function [3:0] next_count;
        input [3:0] count;
        input [7:0] value;
        begin
            if (value == 8'h55)
                next_count = (count < 7) ? count + 1'b1 : count;
            else
                next_count = 0;
        end
    endfunction

    // Keep the candidates in the explicit sensitivity cone.  This is also
    // easier for Vivado 2019.2 to optimize than a function which reads nets
    // declared outside its argument list.
    always @(*) begin
        case (frame_mode)
            3'd0: selected_byte = candidate0;
            3'd1: selected_byte = candidate1;
            3'd2: selected_byte = candidate2;
            3'd3: selected_byte = candidate3;
            3'd4: selected_byte = candidate4;
            default: selected_byte = candidate5;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            raw_previous <= 0;
            dv_previous <= 0;
            er_previous <= 0;
            raw_frame_active <= 0;
            aligned_frame_active <= 0;
            frame_error_seen <= 0;
            frame_mode <= 0;
            detected_mode <= 0;
            count0 <= 0; count1 <= 0; count2 <= 0;
            count3 <= 0; count4 <= 0; count5 <= 0;
            crc_reg <= 32'hFFFF_FFFF;
            frame_start <= 0;
            frame_data <= 0;
            frame_valid <= 0;
            frame_end <= 0;
            frame_good <= 0;
            frame_bad <= 0;
            debug_preamble_count <= 0;
            debug_crc <= 32'hFFFF_FFFF;
        end else begin
            raw_previous <= raw_data;
            dv_previous <= raw_dv;
            er_previous <= raw_er;
            frame_start <= 0;
            frame_valid <= 0;
            frame_end <= 0;
            frame_good <= 0;
            frame_bad <= 0;

            if (!enable) begin
                raw_frame_active <= 0;
                aligned_frame_active <= 0;
                count0 <= 0; count1 <= 0; count2 <= 0;
                count3 <= 0; count4 <= 0; count5 <= 0;
                crc_reg <= 32'hFFFF_FFFF;
                debug_preamble_count <= 0;
            end else if (dv_previous) begin
                if (!raw_frame_active) begin
                    raw_frame_active <= 1;
                    aligned_frame_active <= 0;
                    frame_error_seen <= 0;
                    count0 <= 0; count1 <= 0; count2 <= 0;
                    count3 <= 0; count4 <= 0; count5 <= 0;
                    crc_reg <= 32'hFFFF_FFFF;
                    debug_preamble_count <= 0;
                end

                if (!aligned_frame_active) begin
                    // A forced mode is used after calibration lock or while
                    // VIO manual override is active.
                    if (force_mode) begin
                        case (forced_mode)
                            3'd0: begin
                                if (candidate0 == 8'hD5 && count0 == 7) begin
                                    frame_mode <= 0; detected_mode <= 0;
                                    aligned_frame_active <= 1; frame_start <= 1;
                                    crc_reg <= 32'hFFFF_FFFF;
                                end
                                count0 <= next_count(count0, candidate0);
                                debug_preamble_count <= count0;
                            end
                            3'd1: begin
                                if (candidate1 == 8'hD5 && count1 == 7) begin
                                    frame_mode <= 1; detected_mode <= 1;
                                    aligned_frame_active <= 1; frame_start <= 1;
                                    crc_reg <= 32'hFFFF_FFFF;
                                end
                                count1 <= next_count(count1, candidate1);
                                debug_preamble_count <= count1;
                            end
                            3'd2: begin
                                if (candidate2 == 8'hD5 && count2 == 7) begin
                                    frame_mode <= 2; detected_mode <= 2;
                                    aligned_frame_active <= 1; frame_start <= 1;
                                    crc_reg <= 32'hFFFF_FFFF;
                                end
                                count2 <= next_count(count2, candidate2);
                                debug_preamble_count <= count2;
                            end
                            3'd3: begin
                                if (candidate3 == 8'hD5 && count3 == 7) begin
                                    frame_mode <= 3; detected_mode <= 3;
                                    aligned_frame_active <= 1; frame_start <= 1;
                                    crc_reg <= 32'hFFFF_FFFF;
                                end
                                count3 <= next_count(count3, candidate3);
                                debug_preamble_count <= count3;
                            end
                            3'd4: begin
                                if (candidate4 == 8'hD5 && count4 == 7) begin
                                    frame_mode <= 4; detected_mode <= 4;
                                    aligned_frame_active <= 1; frame_start <= 1;
                                    crc_reg <= 32'hFFFF_FFFF;
                                end
                                count4 <= next_count(count4, candidate4);
                                debug_preamble_count <= count4;
                            end
                            default: begin
                                if (candidate5 == 8'hD5 && count5 == 7) begin
                                    frame_mode <= 5; detected_mode <= 5;
                                    aligned_frame_active <= 1; frame_start <= 1;
                                    crc_reg <= 32'hFFFF_FFFF;
                                end
                                count5 <= next_count(count5, candidate5);
                                debug_preamble_count <= count5;
                            end
                        endcase
                    end else begin
                        // Priority matters only for the impossible case where
                        // several candidates produce an SFD simultaneously.
                        if (candidate0 == 8'hD5 && count0 == 7) begin
                            frame_mode <= 0; detected_mode <= 0;
                            aligned_frame_active <= 1; frame_start <= 1;
                        end else if (candidate1 == 8'hD5 && count1 == 7) begin
                            frame_mode <= 1; detected_mode <= 1;
                            aligned_frame_active <= 1; frame_start <= 1;
                        end else if (candidate2 == 8'hD5 && count2 == 7) begin
                            frame_mode <= 2; detected_mode <= 2;
                            aligned_frame_active <= 1; frame_start <= 1;
                        end else if (candidate3 == 8'hD5 && count3 == 7) begin
                            frame_mode <= 3; detected_mode <= 3;
                            aligned_frame_active <= 1; frame_start <= 1;
                        end else if (candidate4 == 8'hD5 && count4 == 7) begin
                            frame_mode <= 4; detected_mode <= 4;
                            aligned_frame_active <= 1; frame_start <= 1;
                        end else if (candidate5 == 8'hD5 && count5 == 7) begin
                            frame_mode <= 5; detected_mode <= 5;
                            aligned_frame_active <= 1; frame_start <= 1;
                        end
                        count0 <= next_count(count0, candidate0);
                        count1 <= next_count(count1, candidate1);
                        count2 <= next_count(count2, candidate2);
                        count3 <= next_count(count3, candidate3);
                        count4 <= next_count(count4, candidate4);
                        count5 <= next_count(count5, candidate5);
                        if (count0 > debug_preamble_count) debug_preamble_count <= count0;
                        if (count1 > debug_preamble_count) debug_preamble_count <= count1;
                        if (count2 > debug_preamble_count) debug_preamble_count <= count2;
                        if (count3 > debug_preamble_count) debug_preamble_count <= count3;
                        if (count4 > debug_preamble_count) debug_preamble_count <= count4;
                        if (count5 > debug_preamble_count) debug_preamble_count <= count5;
                    end
                end else begin
                    frame_data <= selected_byte;
                    frame_valid <= 1;
                    crc_reg <= crc_next;
                    debug_crc <= crc_next;
                    // raw_er belongs to the next nominal byte at a frame
                    // boundary.  The stream itself is normalized to the
                    // previous byte time, therefore use er_previous here.
                    if (er_previous) frame_error_seen <= 1;
                end
            end else if (raw_frame_active) begin
                raw_frame_active <= 0;
                frame_end <= aligned_frame_active;
                if (aligned_frame_active && !frame_error_seen &&
                    crc_reg == CRC_RESIDUE)
                    frame_good <= 1;
                else
                    frame_bad <= 1;
                aligned_frame_active <= 0;
                count0 <= 0; count1 <= 0; count2 <= 0;
                count3 <= 0; count4 <= 0; count5 <= 0;
            end
        end
    end
endmodule

`default_nettype wire
