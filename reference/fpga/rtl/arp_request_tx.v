`timescale 1ns / 1ps
`default_nettype none

// Periodically asks for TARGET_IP until a validated ARP reply is learned.
// The output is a complete Ethernet frame without preamble or FCS.
module arp_request_tx #(
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP  = 32'hC0A8_0002,
    parameter [31:0] TARGET_IP = 32'hC0A8_0003,
    parameter integer START_DELAY_CYCLES = 375000000,
    parameter integer RETRY_CYCLES = 125000000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       arp_valid,
    output reg  [7:0] tx_data,
    output reg        tx_valid,
    input  wire       tx_ready,
    output reg        tx_last
);
    reg [31:0] timer;
    reg [5:0] index;
    reg sending;
    reg first_request_sent;

    wire timer_expired = !first_request_sent ?
        ((START_DELAY_CYCLES == 0) || (timer >= START_DELAY_CYCLES - 1)) :
        ((RETRY_CYCLES == 0) || (timer >= RETRY_CYCLES - 1));

    always @(*) begin
        tx_valid = sending;
        tx_last = sending && (index == 6'd59);
        tx_data = 8'h00;
        case (index)
            0,1,2,3,4,5: tx_data = 8'hFF;
            6:  tx_data = LOCAL_MAC[47:40];
            7:  tx_data = LOCAL_MAC[39:32];
            8:  tx_data = LOCAL_MAC[31:24];
            9:  tx_data = LOCAL_MAC[23:16];
            10: tx_data = LOCAL_MAC[15:8];
            11: tx_data = LOCAL_MAC[7:0];
            12: tx_data = 8'h08; 13: tx_data = 8'h06;
            14: tx_data = 8'h00; 15: tx_data = 8'h01;
            16: tx_data = 8'h08; 17: tx_data = 8'h00;
            18: tx_data = 8'h06; 19: tx_data = 8'h04;
            20: tx_data = 8'h00; 21: tx_data = 8'h01;
            22: tx_data = LOCAL_MAC[47:40];
            23: tx_data = LOCAL_MAC[39:32];
            24: tx_data = LOCAL_MAC[31:24];
            25: tx_data = LOCAL_MAC[23:16];
            26: tx_data = LOCAL_MAC[15:8];
            27: tx_data = LOCAL_MAC[7:0];
            28: tx_data = LOCAL_IP[31:24];
            29: tx_data = LOCAL_IP[23:16];
            30: tx_data = LOCAL_IP[15:8];
            31: tx_data = LOCAL_IP[7:0];
            38: tx_data = TARGET_IP[31:24];
            39: tx_data = TARGET_IP[23:16];
            40: tx_data = TARGET_IP[15:8];
            41: tx_data = TARGET_IP[7:0];
            default: tx_data = 8'h00;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            timer <= 0;
            index <= 0;
            sending <= 0;
            first_request_sent <= 0;
        end else if (sending) begin
            if (tx_valid && tx_ready) begin
                if (tx_last) begin
                    sending <= 0;
                    index <= 0;
                    timer <= 0;
                    first_request_sent <= 1;
                end else begin
                    index <= index + 1'b1;
                end
            end
        end else if (!arp_valid) begin
            if (timer_expired) begin
                sending <= 1;
                index <= 0;
            end else begin
                timer <= timer + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
