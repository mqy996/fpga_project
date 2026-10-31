`timescale 1ns / 1ps
`default_nettype none

// Adds preamble/SFD, Ethernet FCS and the 12-byte inter-frame gap.
module eth_mac_tx(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] s_data,
    input  wire       s_valid,
    output wire       s_ready,
    input  wire       s_last,
    output reg  [7:0] gmii_txd,
    output reg        gmii_tx_en,
    output wire       gmii_tx_er,
    output wire       busy
);
    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_PREAMBLE = 3'd1;
    localparam [2:0] ST_DATA     = 3'd2;
    localparam [2:0] ST_FCS      = 3'd3;
    localparam [2:0] ST_IFG      = 3'd4;

    reg [2:0] state;
    reg [3:0] count;
    reg [31:0] crc_reg;
    reg [31:0] fcs_reg;
    wire [31:0] crc_next;

    eth_crc32 u_crc32 (
        .crc_in(crc_reg), .data_in(s_data), .crc_out(crc_next)
    );

    assign s_ready    = (state == ST_DATA);
    assign gmii_tx_er = 1'b0;
    assign busy       = (state != ST_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE; count <= 0; crc_reg <= 32'hFFFF_FFFF;
            fcs_reg <= 0; gmii_txd <= 0; gmii_tx_en <= 0;
        end else begin
            gmii_txd <= 0;
            gmii_tx_en <= 0;
            case (state)
                ST_IDLE: begin
                    count <= 0;
                    crc_reg <= 32'hFFFF_FFFF;
                    if (s_valid) state <= ST_PREAMBLE;
                end
                ST_PREAMBLE: begin
                    gmii_tx_en <= 1;
                    gmii_txd <= (count < 7) ? 8'h55 : 8'hD5;
                    if (count == 7) begin count <= 0; state <= ST_DATA; end
                    else count <= count + 1'b1;
                end
                ST_DATA: begin
                    if (s_valid) begin
                        gmii_txd <= s_data;
                        gmii_tx_en <= 1;
                        crc_reg <= crc_next;
                        if (s_last) begin
                            fcs_reg <= ~crc_next;
                            count <= 0;
                            state <= ST_FCS;
                        end
                    end
                end
                ST_FCS: begin
                    gmii_tx_en <= 1;
                    case (count)
                        0: gmii_txd <= fcs_reg[7:0];
                        1: gmii_txd <= fcs_reg[15:8];
                        2: gmii_txd <= fcs_reg[23:16];
                        3: gmii_txd <= fcs_reg[31:24];
                        default: gmii_txd <= 0;
                    endcase
                    if (count == 3) begin count <= 0; state <= ST_IFG; end
                    else count <= count + 1'b1;
                end
                ST_IFG: begin
                    if (count == 11) begin count <= 0; state <= ST_IDLE; end
                    else count <= count + 1'b1;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
