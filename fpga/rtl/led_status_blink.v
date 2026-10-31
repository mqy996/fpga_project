`timescale 1ns / 1ps
`default_nettype none

// Active-low LED blink generators in the existing clk32/rst32 domain.
module led_status_blink #(
    parameter integer SYSTEM_HALF_PERIOD_CYCLES = 16000000,
    parameter integer CAPTURE_HALF_PERIOD_CYCLES = 8000000
)(
    input wire clk, input wire rst,
    input wire system_enable, input wire capture_enable,
    output wire system_led_n, output wire capture_led_n
);
    localparam integer SYSTEM_COUNTER_WIDTH = (SYSTEM_HALF_PERIOD_CYCLES <= 1) ? 1 : $clog2(SYSTEM_HALF_PERIOD_CYCLES);
    localparam integer CAPTURE_COUNTER_WIDTH = (CAPTURE_HALF_PERIOD_CYCLES <= 1) ? 1 : $clog2(CAPTURE_HALF_PERIOD_CYCLES);
    reg [SYSTEM_COUNTER_WIDTH-1:0] system_count;
    reg [CAPTURE_COUNTER_WIDTH-1:0] capture_count;
    reg system_phase, capture_phase;
    wire system_tick = (SYSTEM_HALF_PERIOD_CYCLES <= 1) || (system_count == SYSTEM_HALF_PERIOD_CYCLES - 1);
    wire capture_tick = (CAPTURE_HALF_PERIOD_CYCLES <= 1) || (capture_count == CAPTURE_HALF_PERIOD_CYCLES - 1);

    always @(posedge clk) begin
        if (rst) begin
            system_count <= 0; capture_count <= 0;
            system_phase <= 1'b0; capture_phase <= 1'b0;
        end else begin
            if (system_tick) begin system_count <= 0; system_phase <= ~system_phase; end
            else system_count <= system_count + 1'b1;
            if (capture_tick) begin capture_count <= 0; capture_phase <= ~capture_phase; end
            else capture_count <= capture_count + 1'b1;
        end
    end

    assign system_led_n = !(system_enable && system_phase);
    assign capture_led_n = !(capture_enable && capture_phase);
endmodule

`default_nettype wire
