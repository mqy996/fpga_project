`timescale 1ns / 1ps
`default_nettype none

// Reset synchronizer: asynchronous assertion, synchronous deassertion.
module reset_sync #(
    parameter integer STAGES = 4
)(
    input  wire clk,
    input  wire arst,
    output wire srst
);
    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync_ff = {STAGES{1'b1}};

    always @(posedge clk or posedge arst) begin
        if (arst)
            sync_ff <= {STAGES{1'b1}};
        else
            sync_ff <= {sync_ff[STAGES-2:0], 1'b0};
    end

    assign srst = sync_ff[STAGES-1];
endmodule

`default_nettype wire

