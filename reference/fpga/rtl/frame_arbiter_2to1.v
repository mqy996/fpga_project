`timescale 1ns / 1ps
`default_nettype none

// Two-input frame-stream arbiter. Source 0 has priority. Once a frame is
// selected, ownership is held through the final data/ready handshake.
module frame_arbiter_2to1(
    input  wire       clk,
    input  wire       rst,

    input  wire [7:0] s0_data,
    input  wire       s0_valid,
    output wire       s0_ready,
    input  wire       s0_last,

    input  wire [7:0] s1_data,
    input  wire       s1_valid,
    output wire       s1_ready,
    input  wire       s1_last,

    output wire [7:0] m_data,
    output wire       m_valid,
    input  wire       m_ready,
    output wire       m_last,
    output wire [1:0] owner
);
    localparam [1:0] OWNER_NONE = 2'd0;
    localparam [1:0] OWNER_S0   = 2'd1;
    localparam [1:0] OWNER_S1   = 2'd2;

    reg [1:0] owner_reg;
    wire [1:0] selected_owner = (owner_reg != OWNER_NONE) ? owner_reg :
                                s0_valid ? OWNER_S0 :
                                s1_valid ? OWNER_S1 : OWNER_NONE;

    assign owner    = selected_owner;
    assign m_data   = (selected_owner == OWNER_S0) ? s0_data : s1_data;
    assign m_valid  = (selected_owner == OWNER_S0) ? s0_valid :
                      (selected_owner == OWNER_S1) ? s1_valid : 1'b0;
    assign m_last   = (selected_owner == OWNER_S0) ? s0_last :
                      (selected_owner == OWNER_S1) ? s1_last : 1'b0;
    assign s0_ready = (selected_owner == OWNER_S0) && m_ready;
    assign s1_ready = (selected_owner == OWNER_S1) && m_ready;

    always @(posedge clk) begin
        if (rst) begin
            owner_reg <= OWNER_NONE;
        end else begin
            if (owner_reg == OWNER_NONE) begin
                if (s0_valid)
                    owner_reg <= OWNER_S0;
                else if (s1_valid)
                    owner_reg <= OWNER_S1;
            end

            if (m_valid && m_ready && m_last)
                owner_reg <= OWNER_NONE;
        end
    end
endmodule

`default_nettype wire
