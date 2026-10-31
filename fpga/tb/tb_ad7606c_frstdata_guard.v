`timescale 1ns/1ps

module tb_ad7606c_frstdata_guard;
    localparam integer BUSY_HIGH_CYCLES = 21;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg stop = 1'b0;
    reg busy = 1'b0;
    reg [15:0] db_model = 16'h5A5A;
    reg frstdata_model = 1'b0; // Deliberately wrong for the first V1 read.

    wire convst, cs_n, rd_n, sample_valid, busy_timeout;
    wire adc_reset, db_oe, start_ready, capture_idle;
    wire frame_alignment_error;
    wire [127:0] sample_data;
    wire [3:0] state;

    integer busy_countdown = 0;

    always #15.625 clk = ~clk;

    ad7606c_pipelined_controller dut (
        .clk(clk), .rst(rst), .start(start), .stop(stop), .busy_i(busy),
        .db_i(db_model), .frstdata_i(frstdata_model),
        .adc_reset(adc_reset), .convst(convst), .cs_n(cs_n),
        .rd_n(rd_n), .db_oe(db_oe), .sample_data(sample_data),
        .sample_valid(sample_valid), .busy_timeout(busy_timeout),
        .frame_alignment_error(frame_alignment_error),
        .start_ready(start_ready), .capture_idle(capture_idle), .state(state)
    );

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            busy_countdown <= 0;
        end else if (convst) begin
            if (busy || busy_countdown != 0)
                $fatal(1, "CONVST overlapped an unfinished conversion");
            busy <= 1'b1;
            busy_countdown <= BUSY_HIGH_CYCLES;
        end else if (busy_countdown > 0) begin
            busy_countdown <= busy_countdown - 1;
            if (busy_countdown == 1)
                busy <= 1'b0;
        end
    end

    always @(negedge rd_n) begin
        if (!rst && cs_n)
            $fatal(1, "RD asserted while CS was inactive");
    end

    always @(posedge clk) begin
        if (!rst) begin
            if (sample_valid)
                $fatal(1, "misaligned frame was published before the FRSTDATA error");
            if (frame_alignment_error) begin
                if (busy_timeout)
                    $fatal(1, "FRSTDATA mismatch was misreported as a BUSY timeout");
                if (state != 4'hF)
                    $fatal(1, "controller did not stop in its error state");
                $display("PASS: FRSTDATA mismatch rejected; no sample_valid was published");
                $finish;
            end
        end
    end

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);
        if (!start_ready)
            $fatal(1, "controller not ready for misalignment test");
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    end

    initial begin
        #5000;
        $fatal(1, "simulation timeout waiting for FRSTDATA mismatch detection");
    end
endmodule
