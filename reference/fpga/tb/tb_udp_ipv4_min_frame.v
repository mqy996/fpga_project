`timescale 1ns/1ps

// Regression for the 16-byte START/STOP control response.  It must retain
// UDP/IP logical lengths while emitting two Ethernet padding bytes so the
// physical frame reaches the 60-byte Ethernet minimum before FCS.
module tb_udp_ipv4_min_frame;
    reg clk=0,rst=1,start=0;
    integer payload_index=0,frame_count=0;
    reg [7:0] payload_data=0;
    reg payload_valid=0,payload_last=0,source_started=0;
    wire payload_ready,tx_valid,tx_last;
    wire [7:0] tx_data;

    always #4 clk=~clk;
    udp_ipv4_tx_runtime dut(
        .clk(clk),.rst(rst),.start(start),.src_ip(32'hc0a80002),
        .dst_mac(48'h001122334455),.dst_ip(32'hc0a80003),
        .src_port(16'd56556),.dst_port(16'd60000),.payload_length(16'd16),
        .busy(),.payload_data(payload_data),.payload_valid(payload_valid),
        .payload_ready(payload_ready),.payload_last(payload_last),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(1'b1),.tx_last(tx_last));

    always @(posedge clk) begin
        if (rst) begin
            payload_index <= 0;
            payload_data <= 0;
            payload_valid <= 0;
            payload_last <= 0;
            source_started <= 0;
        end else if (payload_ready) begin
            if (!source_started) begin
                source_started <= 1;
                payload_index <= 0;
                payload_data <= 0;
                payload_valid <= 1;
                payload_last <= 0;
            end else if (payload_valid) begin
                if (payload_index == 15) begin
                    payload_valid <= 0;
                    payload_last <= 0;
                end else begin
                    payload_index <= payload_index + 1;
                    payload_data <= payload_index + 1;
                    payload_last <= (payload_index == 14);
                end
            end
        end
    end

    always @(posedge clk) begin
        if (tx_valid) begin
            if (frame_count == 16 && tx_data != 8'd0)  $fatal(1,"IPv4 length byte mismatch");
            if (frame_count == 17 && tx_data != 8'd44) $fatal(1,"IPv4 length must remain 44");
            if (frame_count == 38 && tx_data != 8'd0)  $fatal(1,"UDP length byte mismatch");
            if (frame_count == 39 && tx_data != 8'd24) $fatal(1,"UDP length must remain 24");
            if (frame_count == 58 && tx_data != 0) $fatal(1,"first Ethernet pad byte must be zero");
            if (frame_count == 59 && tx_data != 0) $fatal(1,"second Ethernet pad byte must be zero");
            frame_count <= frame_count + 1;
            if (tx_last) begin
                if (frame_count != 59) $fatal(1,"short response frame was not padded to 60 bytes");
                $display("PASS: 16-byte control response has 60-byte Ethernet frame and unchanged UDP/IP lengths");
                $finish;
            end
        end
    end

    initial begin
        repeat(3) @(posedge clk); rst<=0;
        @(negedge clk); start<=1;
        @(negedge clk); start<=0;
        #20000; $fatal(1,"timeout");
    end
endmodule
