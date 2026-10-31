`timescale 1ns / 1ps
`default_nettype none

module button_debounce #(
    parameter integer STABLE_CYCLES = 640000
)(
    input  wire clk,
    input  wire rst,
    input  wire button_n,
    output reg  press_pulse,
    output reg  stable_n
);
    (* ASYNC_REG = "TRUE" *) reg sync1, sync2;
    reg [19:0] count;
    always @(posedge clk) begin
        if (rst) begin
            sync1 <= 1; sync2 <= 1; stable_n <= 1;
            count <= 0; press_pulse <= 0;
        end else begin
            sync1 <= button_n;
            sync2 <= sync1;
            press_pulse <= 0;
            if (sync2 == stable_n) begin
                count <= 0;
            end else if (count >= STABLE_CYCLES-1) begin
                stable_n <= sync2;
                count <= 0;
                if (!sync2) press_pulse <= 1;
            end else begin
                count <= count + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
