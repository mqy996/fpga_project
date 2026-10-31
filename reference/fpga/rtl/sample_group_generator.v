`timescale 1ns / 1ps
`default_nettype none

// Produces one complete 24-channel sample group every SAMPLE_DIV clocks.
// The counter advances even if the FIFO is full so any lost group is visible
// to the PC verifier as a discontinuity in the deterministic sample pattern.
module sample_group_generator #(
    parameter integer SAMPLE_DIV   = 32,
    parameter integer TOTAL_GROUPS = 1000
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         enable,
    output reg  [383:0] group_data,
    output reg          group_valid,
    output reg  [31:0]  groups_attempted,
    output wire         done
);
    reg [5:0] div_count;
    reg [15:0] base_sample;
    integer channel;

    assign done = (groups_attempted >= TOTAL_GROUPS);

    always @(posedge clk) begin
        if (rst) begin
            div_count        <= 0;
            base_sample      <= 0;
            group_data       <= 0;
            group_valid      <= 0;
            groups_attempted <= 0;
        end else begin
            group_valid <= 1'b0;
            if (enable && !done) begin
                if (div_count >= SAMPLE_DIV - 1) begin
                    div_count <= 0;
                    for (channel = 0; channel < 24; channel = channel + 1)
                        group_data[channel*16 +: 16] <= base_sample + channel;
                    group_valid <= 1'b1;
                    base_sample <= base_sample + 16'd24;
                    groups_attempted <= groups_attempted + 1'b1;
                end else begin
                    div_count <= div_count + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
