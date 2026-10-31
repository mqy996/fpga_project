`timescale 1ns / 1ps
`default_nettype none

// Purely combinational validation shared by boot loading and SET_CONFIG.
module config_validate(
    input  wire [31:0] local_ip,
    input  wire [31:0] netmask,
    input  wire [31:0] target_ip,
    input  wire [15:0] target_port,
    input  wire [31:0] sample_rate,
    input  wire [31:0] channel_mask,
    input  wire [31:0] groups_per_packet,
    output reg         valid,
    output reg  [5:0]  enabled_channels,
    output reg  [15:0] payload_length
);
    integer i;
    (* use_dsp = "no" *) reg [31:0] bytes;
    reg mask_contiguous;
    always @(*) begin
        enabled_channels = 0;
        for (i=0; i<24; i=i+1)
            enabled_channels = enabled_channels + channel_mask[i];
        bytes = 12 + (enabled_channels * groups_per_packet * 2);
        payload_length = bytes[15:0];
        // A legal IPv4 mask is contiguous ones followed by zeros.  The
        // expression below recognizes the common /1../32 masks; /0 is not
        // accepted for this same-subnet instrument.
        mask_contiguous = (netmask != 0) && (((~netmask) & ((~netmask)+1)) == 0);
        // The ADC scheduler supports exactly three clocks-per-sample values
        // at the 32 MHz acquisition clock.  Keep this check in the common
        // validator so boot records and SET_CONFIG use identical policy.
        valid = local_ip != 0 && local_ip != 32'hffff_ffff &&
                target_ip != 0 && target_ip != 32'hffff_ffff &&
                local_ip != target_ip && local_ip[31:28] != 4'he &&
                target_ip[31:28] != 4'he && mask_contiguous &&
                ((local_ip & netmask) == (target_ip & netmask)) &&
                target_port != 0 &&
                ((sample_rate == 32'd250000) ||
                 (sample_rate == 32'd500000) ||
                 (sample_rate == 32'd1000000)) &&
                channel_mask[31:24] == 0 && enabled_channels != 0 &&
                groups_per_packet >= 1 && groups_per_packet <= 30;
    end
endmodule

`default_nettype wire
