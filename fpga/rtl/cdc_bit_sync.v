`timescale 1ns / 1ps
`default_nettype none

// Destination-clock two-flop synchronizer for a stable single-bit level.
module cdc_bit_sync #(
    parameter INIT = 1'b0
)(
    input  wire dst_clk,
    input  wire dst_rst,
    input  wire async_in,
    output wire sync_out
);
    (* ASYNC_REG = "TRUE" *) reg sync_ff1 = INIT;
    (* ASYNC_REG = "TRUE" *) reg sync_ff2 = INIT;

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            sync_ff1 <= INIT;
            sync_ff2 <= INIT;
        end else begin
            sync_ff1 <= async_in;
            sync_ff2 <= sync_ff1;
        end
    end

    assign sync_out = sync_ff2;
endmodule

`default_nettype wire

