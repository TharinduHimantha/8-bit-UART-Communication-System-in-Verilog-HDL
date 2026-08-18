//==============================================================================
// File   : uart_tx_tb.v
// Purpose: Unit-level testbench for uart_tx + baud_gen ONLY (no uart_rx).
//          Verifies line-level protocol timing AND parity-bit generation
//          for NONE/EVEN/ODD, by sampling the tx pin directly and checking
//          each segment against an independently computed expected value.
//==============================================================================

`timescale 1ns/1ps
`include "uart_defs.vh"

module uart_tx_tb;

    localparam CLKS_PER_BIT   = 10;
    localparam CLK_PERIOD_NS  = 10;

    reg        clk = 0;
    reg        reset = 1;
    reg        tx_start;
    reg  [7:0] tx_data;

    // ---- three DUT instances, one per parity mode ------------------------
    wire tx_none, tx_busy_none, tx_done_none, tick_none, restart_none;
    wire tx_even, tx_busy_even, tx_done_even, tick_even, restart_even;
    wire tx_odd,  tx_busy_odd,  tx_done_odd,  tick_odd,  restart_odd;

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    baud_gen #(.CLKS_PER_BIT(CLKS_PER_BIT)) bg_none (.clk(clk), .reset(reset), .restart(restart_none), .tick(tick_none));
    uart_tx  #(.PARITY_MODE(`UART_PARITY_NONE)) dut_none (
        .clk(clk), .reset(reset), .tx_start(tx_start), .tx_data(tx_data),
        .baud_tick(tick_none), .baud_restart(restart_none),
        .tx(tx_none), .tx_busy(tx_busy_none), .tx_done(tx_done_none));

    baud_gen #(.CLKS_PER_BIT(CLKS_PER_BIT)) bg_even (.clk(clk), .reset(reset), .restart(restart_even), .tick(tick_even));
    uart_tx  #(.PARITY_MODE(`UART_PARITY_EVEN)) dut_even (
        .clk(clk), .reset(reset), .tx_start(tx_start), .tx_data(tx_data),
        .baud_tick(tick_even), .baud_restart(restart_even),
        .tx(tx_even), .tx_busy(tx_busy_even), .tx_done(tx_done_even));

    baud_gen #(.CLKS_PER_BIT(CLKS_PER_BIT)) bg_odd (.clk(clk), .reset(reset), .restart(restart_odd), .tick(tick_odd));
    uart_tx  #(.PARITY_MODE(`UART_PARITY_ODD)) dut_odd (
        .clk(clk), .reset(reset), .tx_start(tx_start), .tx_data(tx_data),
        .baud_tick(tick_odd), .baud_restart(restart_odd),
        .tx(tx_odd), .tx_busy(tx_busy_odd), .tx_done(tx_done_odd));

    // uart_tasks.v's naming contract: main DUT-under-test-for-tasks aliases
    wire tx_line  = tx_none;
    wire tx_busy  = tx_busy_none;
    wire tx_done  = tx_done_none;
    reg  [7:0] rx_data = 8'h00;
    reg        rx_valid = 1'b0, rx_busy = 1'b0, parity_error = 1'b0, framing_error = 1'b0;

    `include "uart_tasks.v"

    reg cap [0:511];
    integer ci;

    // NOTE: a single task taking the target line as an "input" argument was
    // tried first and does not work here -- Verilog task "input" arguments
    // are sampled ONCE, at the moment the task is called, not continuously
    // tracked like a signal reference. A `wait(line == 0)` inside such a
    // task would silently wait on a frozen, stale copy of the wire's value
    // from call time, hanging forever if it happened to already be 1. Three
    // concrete tasks (a little repetitive, but each referencing its DUT's
    // line directly) avoids that trap entirely.
    task capture_and_check_none(input [7:0] data_byte);
        integer seg, samp, base, total_bits;
        reg seg_ok, seg_val;
        begin
            total_bits = 10;
            wait (tx_none == 1'b0);
            @(negedge clk);
            for (ci = 0; ci < total_bits * CLKS_PER_BIT; ci = ci + 1) begin
                cap[ci] = tx_none;
                @(negedge clk);
            end
            for (seg = 0; seg < total_bits; seg = seg + 1) begin
                base    = seg * CLKS_PER_BIT;
                seg_val = cap[base];
                seg_ok  = 1'b1;
                for (samp = 0; samp < CLKS_PER_BIT; samp = samp + 1)
                    if (cap[base + samp] !== seg_val) seg_ok = 1'b0;
                if (seg == 0)
                    check_cond("NONE: start bit", seg_ok && (seg_val === 1'b0));
                else if (seg <= 8)
                    check_cond("NONE: data bit (LSB first)", seg_ok && (seg_val === data_byte[seg-1]));
                else
                    check_cond("NONE: stop bit", seg_ok && (seg_val === 1'b1));
            end
        end
    endtask

    task capture_and_check_even(input [7:0] data_byte);
        integer seg, samp, base, total_bits;
        reg seg_ok, seg_val, exp_parity;
        begin
            total_bits = 11;
            exp_parity = model_parity_bit(data_byte, `UART_PARITY_EVEN);
            wait (tx_even == 1'b0);
            @(negedge clk);
            for (ci = 0; ci < total_bits * CLKS_PER_BIT; ci = ci + 1) begin
                cap[ci] = tx_even;
                @(negedge clk);
            end
            for (seg = 0; seg < total_bits; seg = seg + 1) begin
                base    = seg * CLKS_PER_BIT;
                seg_val = cap[base];
                seg_ok  = 1'b1;
                for (samp = 0; samp < CLKS_PER_BIT; samp = samp + 1)
                    if (cap[base + samp] !== seg_val) seg_ok = 1'b0;
                if (seg == 0)
                    check_cond("EVEN: start bit", seg_ok && (seg_val === 1'b0));
                else if (seg <= 8)
                    check_cond("EVEN: data bit (LSB first)", seg_ok && (seg_val === data_byte[seg-1]));
                else if (seg == 9)
                    check_cond("EVEN: parity bit", seg_ok && (seg_val === exp_parity));
                else
                    check_cond("EVEN: stop bit", seg_ok && (seg_val === 1'b1));
            end
        end
    endtask

    task capture_and_check_odd(input [7:0] data_byte);
        integer seg, samp, base, total_bits;
        reg seg_ok, seg_val, exp_parity;
        begin
            total_bits = 11;
            exp_parity = model_parity_bit(data_byte, `UART_PARITY_ODD);
            wait (tx_odd == 1'b0);
            @(negedge clk);
            for (ci = 0; ci < total_bits * CLKS_PER_BIT; ci = ci + 1) begin
                cap[ci] = tx_odd;
                @(negedge clk);
            end
            for (seg = 0; seg < total_bits; seg = seg + 1) begin
                base    = seg * CLKS_PER_BIT;
                seg_val = cap[base];
                seg_ok  = 1'b1;
                for (samp = 0; samp < CLKS_PER_BIT; samp = samp + 1)
                    if (cap[base + samp] !== seg_val) seg_ok = 1'b0;
                if (seg == 0)
                    check_cond("ODD: start bit", seg_ok && (seg_val === 1'b0));
                else if (seg <= 8)
                    check_cond("ODD: data bit (LSB first)", seg_ok && (seg_val === data_byte[seg-1]));
                else if (seg == 9)
                    check_cond("ODD: parity bit", seg_ok && (seg_val === exp_parity));
                else
                    check_cond("ODD: stop bit", seg_ok && (seg_val === 1'b1));
            end
        end
    endtask

    task send_none(input [7:0] b);
        begin
            wait (tx_busy_none == 1'b0);
            @(posedge clk); tx_data <= b; tx_start <= 1'b1;
            @(posedge clk); tx_start <= 1'b0;
            wait (tx_done_none == 1'b1);
        end
    endtask
    task send_even(input [7:0] b);
        begin
            wait (tx_busy_even == 1'b0);
            @(posedge clk); tx_data <= b; tx_start <= 1'b1;
            @(posedge clk); tx_start <= 1'b0;
            wait (tx_done_even == 1'b1);
        end
    endtask
    task send_odd(input [7:0] b);
        begin
            wait (tx_busy_odd == 1'b0);
            @(posedge clk); tx_data <= b; tx_start <= 1'b1;
            @(posedge clk); tx_start <= 1'b0;
            wait (tx_done_odd == 1'b1);
        end
    endtask

    integer i;
    reg [7:0] bytes [0:6];

    // Optional VCD waveform dump, enabled with `make waves TB=uart_tx_tb`.
    // Off by default so ordinary regression runs don't pay the (small but
    // nonzero) cost of dumping every signal on every run.
`ifdef WAVES
    initial begin
        $dumpfile("uart_tx_tb.vcd");
        $dumpvars(0, uart_tx_tb);
    end
`endif

    initial begin
        tx_start = 0; tx_data = 0;
        $display("----------------------------------------");
        $display("UART TX UNIT TEST (NONE / EVEN / ODD parity)");
        $display("----------------------------------------");

        repeat (3) @(posedge clk);
        @(negedge clk);
        check_cond("Reset: tx idle high (NONE inst)", tx_none === 1'b1);
        check_cond("Reset: tx idle high (EVEN inst)", tx_even === 1'b1);
        check_cond("Reset: tx idle high (ODD inst)",  tx_odd  === 1'b1);
        check_cond("Reset: tx_busy low (NONE inst)",  tx_busy_none === 1'b0);
        reset = 0;
        @(posedge clk);

        bytes[0] = 8'h00;
        bytes[1] = 8'hFF;
        bytes[2] = 8'h55;
        bytes[3] = 8'hAA;
        bytes[4] = 8'hC3;
        bytes[5] = 8'h01;  // single 1 bit -- exercises the "odd data" edge case
        bytes[6] = 8'hFE;  // seven 1 bits -- another odd-count edge case

        for (i = 0; i < 7; i = i + 1) begin
            fork
                capture_and_check_none(bytes[i]);
                send_none(bytes[i]);
            join
        end

        for (i = 0; i < 7; i = i + 1) begin
            fork
                capture_and_check_even(bytes[i]);
                send_even(bytes[i]);
            join
        end

        for (i = 0; i < 7; i = i + 1) begin
            fork
                capture_and_check_odd(bytes[i]);
                send_odd(bytes[i]);
            join
        end

        print_summary;
        $finish;
    end

    initial begin
        #2_000_000;
        $display("*** WATCHDOG TIMEOUT ***");
        $finish;
    end

endmodule
