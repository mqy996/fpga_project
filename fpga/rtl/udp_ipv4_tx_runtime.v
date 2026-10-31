`timescale 1ns / 1ps
`default_nettype none

// Runtime-addressed Ethernet/IPv4/UDP transmitter. UDP checksum is zero.
module udp_ipv4_tx_runtime #(
    parameter [47:0] SRC_MAC = 48'h02_00_00_00_00_01
)(
    input wire clk, input wire rst, input wire start,
    input wire [31:0] src_ip,
    input wire [47:0] dst_mac, input wire [31:0] dst_ip,
    input wire [15:0] src_port, input wire [15:0] dst_port,
    input wire [15:0] payload_length, output wire busy,
    input wire [7:0] payload_data, input wire payload_valid,
    output wire payload_ready, input wire payload_last,
    output reg [7:0] tx_data, output reg tx_valid,
    input wire tx_ready, output reg tx_last
);
    // Ethernet requires at least 60 bytes from destination MAC through the
    // final payload byte (FCS excluded).  The shortest legal IPv4/UDP control
    // response has a 16-byte protocol header, giving only 58 bytes.  Keep the
    // IPv4/UDP length fields at their logical values and append zero Ethernet
    // pad bytes outside the UDP datagram before FCS.
    localparam ST_IDLE=0, ST_PREP1=1, ST_PREP2=2, ST_HEADER=3,
               ST_PAYLOAD=4, ST_PAD=5;
    reg [2:0] state;
    reg [5:0] index;
    reg [47:0] dmac;
    reg [31:0] dip;
    reg [15:0] sport, dport, plen, ulen, ilen, ipcs;
    reg [31:0] sum_a,sum_b,sum_fold;
    reg [4:0] pad_index;

    assign busy=state!=ST_IDLE;
    assign payload_ready=(state==ST_PAYLOAD)&&tx_ready;
    always @(*) begin
        tx_data=0; tx_valid=0; tx_last=0;
        if(state==ST_HEADER) begin
            tx_valid=1;
            case(index)
              0:tx_data=dmac[47:40];1:tx_data=dmac[39:32];2:tx_data=dmac[31:24];
              3:tx_data=dmac[23:16];4:tx_data=dmac[15:8];5:tx_data=dmac[7:0];
              6:tx_data=SRC_MAC[47:40];7:tx_data=SRC_MAC[39:32];8:tx_data=SRC_MAC[31:24];
              9:tx_data=SRC_MAC[23:16];10:tx_data=SRC_MAC[15:8];11:tx_data=SRC_MAC[7:0];
              12:tx_data=8'h08;13:tx_data=8'h00;14:tx_data=8'h45;15:tx_data=0;
              16:tx_data=ilen[15:8];17:tx_data=ilen[7:0];18:tx_data=0;19:tx_data=0;
              20:tx_data=8'h40;21:tx_data=0;22:tx_data=8'h40;23:tx_data=8'h11;
              24:tx_data=ipcs[15:8];25:tx_data=ipcs[7:0];
              26:tx_data=src_ip[31:24];27:tx_data=src_ip[23:16];
              28:tx_data=src_ip[15:8];29:tx_data=src_ip[7:0];
              30:tx_data=dip[31:24];31:tx_data=dip[23:16];32:tx_data=dip[15:8];33:tx_data=dip[7:0];
              34:tx_data=sport[15:8];35:tx_data=sport[7:0];36:tx_data=dport[15:8];37:tx_data=dport[7:0];
              38:tx_data=ulen[15:8];39:tx_data=ulen[7:0];40:tx_data=0;41:tx_data=0;
              default:tx_data=0;
            endcase
        end else if(state==ST_PAYLOAD) begin
            tx_data=payload_data; tx_valid=payload_valid;
            // The logical UDP payload ends here, but for a short datagram
            // Ethernet padding still follows.  Only the final pad byte may
            // terminate the frame presented to eth_mac_tx.
            tx_last=payload_valid&&payload_last&&(plen>=18);
        end else if(state==ST_PAD) begin
            tx_data=0; tx_valid=1;
            // pad bytes = 18 - plen, so the final zero has index 17-plen.
            tx_last=(pad_index==(16'd17-plen));
        end
    end
    always @(posedge clk) begin
        if(rst) begin state<=ST_IDLE;index<=0;pad_index<=0;dmac<=0;dip<=0;sport<=0;dport<=0;plen<=0;ulen<=0;ilen<=0;ipcs<=0;sum_a<=0;sum_b<=0;sum_fold<=0;end
        else case(state)
          ST_IDLE:if(start) begin
              dmac<=dst_mac;dip<=dst_ip;sport<=src_port;dport<=dst_port;plen<=payload_length;
              ulen<=payload_length+8;ilen<=payload_length+28;
              index<=0;state<=ST_PREP1;
          end
          ST_PREP1:begin sum_a<=32'h4500+ilen+16'h4000+16'h4011;sum_b<=src_ip[31:16]+src_ip[15:0]+dip[31:16]+dip[15:0];state<=ST_PREP2;end
          ST_PREP2:begin sum_fold=sum_a+sum_b;sum_fold=sum_fold[15:0]+sum_fold[31:16];sum_fold=sum_fold[15:0]+sum_fold[31:16];ipcs<=~sum_fold[15:0];state<=ST_HEADER;end
          ST_HEADER:if(tx_valid&&tx_ready) begin if(index==41) state<=ST_PAYLOAD; else index<=index+1'b1; end
          // Transition on the logical UDP-payload end, not tx_last: for a
          // short datagram tx_last is intentionally withheld until ST_PAD.
          ST_PAYLOAD:if(payload_valid&&tx_ready&&payload_last) begin
              if(plen<18) begin pad_index<=0;state<=ST_PAD;end
              else state<=ST_IDLE;
          end
          ST_PAD:if(tx_valid&&tx_ready) begin
              if(tx_last) state<=ST_IDLE;
              else pad_index<=pad_index+1'b1;
          end
          default:state<=ST_IDLE;
        endcase
    end
endmodule
`default_nettype wire
