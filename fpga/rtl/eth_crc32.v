`timescale 1ns / 1ps
`default_nettype none

// One-byte reflected Ethernet CRC32 update.
module eth_crc32(
    input  wire [31:0] crc_in,
    input  wire [7:0]  data_in,
    output reg  [31:0] crc_out
);
    integer bit_index;
    always @(*) begin
        crc_out = crc_in;
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            if (crc_out[0] ^ data_in[bit_index])
                crc_out = (crc_out >> 1) ^ 32'hEDB8_8320;
            else
                crc_out = crc_out >> 1;
        end
    end
endmodule

`default_nettype wire
