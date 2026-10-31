`timescale 1ns / 1ps
`default_nettype none

// One frame buffer.  Port A belongs to recovered RXC; port B belongs to the
// local 125 MHz transmit clock.  The request/ack handshake prevents overlap.
(* keep_hierarchy = "yes" *) module frame_ram(
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire [10:0] wr_addr,
    input  wire [7:0]  wr_data,
    input  wire        rd_clk,
    input  wire [10:0] rd_addr,
    output reg  [7:0]  rd_data
);
    (* ram_style = "block" *) reg [7:0] mem [0:2047];
    // Keep the read port permanently enabled.  Without the hierarchy/keep
    // attributes Vivado can absorb downstream reset gating into ENBWREN,
    // which makes a perfectly synchronous read port look as if it were
    // controlled by the asynchronous assertion side of rst125.
    (* keep = "true" *) wire [10:0] rd_addr_kept = rd_addr;
    always @(posedge wr_clk)
        if (wr_en) mem[wr_addr] <= wr_data;
    always @(posedge rd_clk)
        rd_data <= mem[rd_addr_kept];
endmodule

`default_nettype wire
