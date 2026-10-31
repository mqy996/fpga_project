`timescale 1ns/1ps
`default_nettype none

// Exercises single-bit CDC and per-domain reset release with unrelated clock
// periods and phases.  This is a structural smoke test, not a metastability
// analog model.
module tb_cdc_status;
    reg src_clk = 0;
    reg dst_clk = 0;
    reg rst_async = 1;
    reg src_level = 0;
    wire dst_rst;
    wire dst_level;

    always #15.625 src_clk = ~src_clk; // 32 MHz
    initial begin
        #2.3;
        forever #4.0 dst_clk = ~dst_clk; // 125 MHz, unrelated initial phase
    end

    reset_sync u_reset (.clk(dst_clk), .arst(rst_async), .srst(dst_rst));
    cdc_bit_sync u_sync (.dst_clk(dst_clk), .dst_rst(dst_rst),
                         .async_in(src_level), .sync_out(dst_level));

    initial begin
        #47.1 rst_async = 0;
        wait (!dst_rst);
        @(posedge src_clk); src_level <= 1;
        repeat (5) @(posedge dst_clk);
        if (dst_level !== 1) $fatal(1, "CDC high transition missing");
        @(posedge src_clk); src_level <= 0;
        repeat (5) @(posedge dst_clk);
        if (dst_level !== 0) $fatal(1, "CDC low transition missing");

        // Asynchronous assertion must be immediate; release must wait for the
        // destination clock synchronizer.
        #1.7 rst_async = 1;
        #0.1 if (dst_rst !== 1) $fatal(1, "reset did not assert asynchronously");
        #9.3 rst_async = 0;
        repeat (5) @(posedge dst_clk);
        if (dst_rst !== 0) $fatal(1, "reset did not release synchronously");
        $display("PASS: asynchronous phase CDC/reset smoke test");
        $finish;
    end
endmodule

`default_nettype wire
