`timescale 1ns / 1ps
`default_nettype none

// Byte-oriented SPI mode-0 master for the configuration flash after EOS.
// clk is 32 MHz.  CLK_DIV=2 produces an 8 MHz serial clock.
// CCLK is driven through STARTUPE2; DQ0/DQ1 and CS# are user pins.
module flash_spi_byte_master #(
    parameter integer CLK_DIV = 2,
    parameter integer STARTUP_WAIT_CYCLES = 32000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,
    input  wire       cs_active,
    input  wire       byte_start,
    input  wire [7:0] tx_byte,
    output reg  [7:0] rx_byte,
    output reg        byte_done,
    output reg        busy,
    output wire       flash_cs_n,
    output wire       flash_dq0,
    input  wire       flash_dq1,
    output wire       flash_clk,
    output wire       eos,
    output reg        spi_ready,
    output wire [3:0] debug_edge_count
);
    reg spi_clk;
    reg [7:0] tx_shift;
    reg [7:0] rx_shift;
    reg [3:0] edge_count;
    reg [7:0] div_count;
    reg [4:0] warmup_count;
    reg [31:0] settle_count;

    assign flash_cs_n = ~(enable && spi_ready && cs_active);
    assign flash_dq0 = tx_shift[7];
    assign flash_clk = spi_clk;
    assign debug_edge_count = edge_count;

    // STARTUPE2 is the supported route from user logic to the dedicated CCLK.
    STARTUPE2 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) u_startup (
        .CFGCLK(), .CFGMCLK(), .EOS(eos), .PREQ(),
        .CLK(1'b0), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1),
        .PACK(1'b0), .USRCCLKO(spi_clk), .USRCCLKTS(~enable),
        .USRDONEO(1'b1), .USRDONETS(1'b1)
    );

    always @(posedge clk) begin
        if (rst) begin
            spi_clk <= 1'b0;
            tx_shift <= 8'hff;
            rx_shift <= 0;
            rx_byte <= 0;
            edge_count <= 0;
            div_count <= 0;
            byte_done <= 0;
            busy <= 0;
            spi_ready <= 0;
            warmup_count <= 0;
            settle_count <= 0;
        end else begin
            if (enable && !spi_ready) begin
                // UG470: the first three USRCCLKO cycles after EOS do not
                // reach CCLK. Consume them with CS# high, never in an opcode.
                tx_shift <= 8'hff;
                busy <= 0;
                byte_done <= 0;
                if (warmup_count < 16) begin
                    if (div_count == CLK_DIV-1) begin
                        div_count <= 0;
                        spi_clk <= ~spi_clk;
                        if (spi_clk) warmup_count <= warmup_count + 1'b1;
                    end else div_count <= div_count + 1'b1;
                end else begin
                    spi_clk <= 0;
                    if (settle_count == STARTUP_WAIT_CYCLES-1)
                        spi_ready <= 1;
                    else settle_count <= settle_count + 1'b1;
                end
            end else if (byte_done) begin
                // Hold busy high during the one-cycle done indication.  This
                // lets the transaction FSM consume done before it can launch
                // the following byte.
                byte_done <= 0;
                busy <= 0;
                spi_clk <= 0;
            end else if (!enable) begin
                spi_clk <= 0;
                busy <= 0;
                div_count <= 0;
            end else if (!busy) begin
                spi_clk <= 0;
                div_count <= 0;
                if (byte_start) begin
                    tx_shift <= tx_byte;
                    rx_shift <= 0;
                    edge_count <= 0;
                    busy <= 1;
                end
            end else if (div_count == CLK_DIV-1) begin
                div_count <= 0;
                if (!spi_clk) begin
                    // Rising edge: the flash and FPGA sample MOSI/MISO.
                    spi_clk <= 1;
                    rx_shift <= {rx_shift[6:0], flash_dq1};
                    edge_count <= edge_count + 1'b1;
                end else begin
                    // Falling edge: present the next MOSI bit.
                    spi_clk <= 0;
                    tx_shift <= {tx_shift[6:0], 1'b1};
                    if (edge_count == 8) begin
                        rx_byte <= rx_shift;
                        byte_done <= 1;
                    end
                end
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
