`timescale 1ns / 1ps
`default_nettype none

// Emits the formal 12-byte acquisition header followed by ten complete
// 24-channel sample groups.  All multi-byte fields are big-endian.
module fifo_udp_payload_gen #(
    parameter [31:0] SAMPLE_RATE = 32'd1000000,
    parameter [31:0] CHANNEL_MASK = 32'h00FF_FFFF,
    parameter integer GROUPS_PER_PACKET = 10
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [31:0]  sequence_number,
    output wire         busy,

    input  wire [383:0] fifo_data,
    input  wire         fifo_empty,
    output reg          fifo_rd_en,

    output reg  [7:0]   data,
    output reg          valid,
    input  wire         ready,
    output reg          last
);
    localparam [2:0] ST_IDLE = 0, ST_HEADER = 1, ST_DATA = 2;
    reg [2:0] state;
    reg [3:0] header_index;
    reg [4:0] channel_index;
    reg [5:0] group_index;
    reg       byte_low;
    reg [31:0] sequence_latched;
    reg [383:0] group_latched;
    reg [15:0] sample_word;

    assign busy = (state != ST_IDLE);

    always @(*) begin
        sample_word = group_latched[channel_index*16 +: 16];
        data = 8'h00;
        valid = 1'b0;
        last = 1'b0;
        if (state == ST_HEADER) begin
            valid = 1'b1;
            case (header_index)
                0: data = sequence_latched[31:24];
                1: data = sequence_latched[23:16];
                2: data = sequence_latched[15:8];
                3: data = sequence_latched[7:0];
                4: data = SAMPLE_RATE[31:24];
                5: data = SAMPLE_RATE[23:16];
                6: data = SAMPLE_RATE[15:8];
                7: data = SAMPLE_RATE[7:0];
                8: data = CHANNEL_MASK[31:24];
                9: data = CHANNEL_MASK[23:16];
                10: data = CHANNEL_MASK[15:8];
                11: data = CHANNEL_MASK[7:0];
                default: data = 0;
            endcase
        end else if (state == ST_DATA) begin
            valid = 1'b1;
            data = byte_low ? sample_word[7:0] : sample_word[15:8];
            last = byte_low && channel_index == 23 &&
                   group_index == GROUPS_PER_PACKET - 1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            header_index <= 0;
            channel_index <= 0;
            group_index <= 0;
            byte_low <= 0;
            sequence_latched <= 0;
            group_latched <= 0;
            fifo_rd_en <= 0;
        end else begin
            fifo_rd_en <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        sequence_latched <= sequence_number;
                        header_index <= 0;
                        group_index <= 0;
                        state <= ST_HEADER;
                    end
                end
                ST_HEADER: begin
                    if (valid && ready) begin
                        if (header_index == 11) begin
                            // All groups were reserved before start.  Pop and
                            // latch the first FWFT word on the final header
                            // handshake so Ethernet data remains continuous.
                            group_latched <= fifo_data;
                            fifo_rd_en <= 1'b1;
                            channel_index <= 0;
                            byte_low <= 0;
                            state <= ST_DATA;
                        end else header_index <= header_index + 1'b1;
                    end
                end
                ST_DATA: begin
                    if (valid && ready) begin
                        if (!byte_low) begin
                            byte_low <= 1'b1;
                        end else begin
                            byte_low <= 1'b0;
                            if (channel_index == 23) begin
                                channel_index <= 0;
                                if (group_index == GROUPS_PER_PACKET - 1) begin
                                    state <= ST_IDLE;
                                end else begin
                                    // The next FWFT word has been visible for
                                    // the whole current group.  Latch/pop it
                                    // without inserting an invalid GMII cycle.
                                    group_latched <= fifo_data;
                                    fifo_rd_en <= 1'b1;
                                    group_index <= group_index + 1'b1;
                                end
                            end else begin
                                channel_index <= channel_index + 1'b1;
                            end
                        end
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
