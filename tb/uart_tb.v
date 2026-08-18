//==============================================================================
// File   : uart_tb.v
// Purpose: Top-level, self-checking UART loopback testbench.
//
//   uart_tx.tx  ---->  tx_line  ---->  uart_rx.rx
//
// Three DUT instances are used, one per PARITY_MODE (NONE/EVEN/ODD), since
// PARITY_MODE is an elaboration-time parameter and cannot be changed inside
// a single running simulation. Each DUT's own tx pin is wired directly back
// to its own rx pin (loopback).
//
// This testbench covers normal-operation traffic (the full 0x00-0xFF sweep,
// random bytes, back-to-back bytes, repeated bytes) across all three parity
// modes, plus reset-during-transmission/reception. Fault injection (bad
// parity, bad stop bit, glitches, break conditions) lives in
// tb/uart_rx_tb.v, since a working uart_tx cannot produce a malformed frame
// by itself -- see that file's header comment.
//==============================================================================

`timescale 1ns/1ps
`include "uart_defs.vh"

module uart_tb;

    localparam CLK_FREQ_HZ = 1000;
    localparam BAUD_RATE   = 100;     // CLKS_PER_BIT = 1000/100 = 10
    localparam CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam CLK_PERIOD_NS = 10;

    reg clk = 0;
    reg reset = 1;

    // ---- three parallel DUTs, one per parity mode -------------------------
    reg  [7:0] tx_data;
    reg        tx_start;

    wire tx_busy_none, tx_done_none, rx_valid_none, rx_busy_none;
    wire parity_error_none, framing_error_none, break_detected_none, rx_error_none;
    wire [7:0] rx_data_none;
    wire [2:0] rx_status_none;
    wire tx_none;

    wire tx_busy_even, tx_done_even, rx_valid_even, rx_busy_even;
    wire parity_error_even, framing_error_even, break_detected_even, rx_error_even;
    wire [7:0] rx_data_even;
    wire [2:0] rx_status_even;
    wire tx_even;

    wire tx_busy_odd, tx_done_odd, rx_valid_odd, rx_busy_odd;
    wire parity_error_odd, framing_error_odd, break_detected_odd, rx_error_odd;
    wire [7:0] rx_data_odd;
    wire [2:0] rx_status_odd;
    wire tx_odd;

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    uart #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE), .PARITY_MODE(`UART_PARITY_NONE)) dut_none (
        .clk(clk), .reset(reset), .tx_data(tx_data), .tx_start(tx_start),
        .tx_busy(tx_busy_none), .tx_done(tx_done_none),
        .rx_data(rx_data_none), .rx_valid(rx_valid_none), .rx_busy(rx_busy_none),
        .parity_error(parity_error_none), .framing_error(framing_error_none),
        .break_detected(break_detected_none), .rx_error(rx_error_none), .rx_status(rx_status_none),
        .tx(tx_none), .rx(tx_none));

    uart #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE), .PARITY_MODE(`UART_PARITY_EVEN)) dut_even (
        .clk(clk), .reset(reset), .tx_data(tx_data), .tx_start(tx_start),
        .tx_busy(tx_busy_even), .tx_done(tx_done_even),
        .rx_data(rx_data_even), .rx_valid(rx_valid_even), .rx_busy(rx_busy_even),
        .parity_error(parity_error_even), .framing_error(framing_error_even),
        .break_detected(break_detected_even), .rx_error(rx_error_even), .rx_status(rx_status_even),
        .tx(tx_even), .rx(tx_even));

    uart #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE), .PARITY_MODE(`UART_PARITY_ODD)) dut_odd (
        .clk(clk), .reset(reset), .tx_data(tx_data), .tx_start(tx_start),
        .tx_busy(tx_busy_odd), .tx_done(tx_done_odd),
        .rx_data(rx_data_odd), .rx_valid(rx_valid_odd), .rx_busy(rx_busy_odd),
        .parity_error(parity_error_odd), .framing_error(framing_error_odd),
        .break_detected(break_detected_odd), .rx_error(rx_error_odd), .rx_status(rx_status_odd),
        .tx(tx_odd), .rx(tx_odd));

    // uart_tasks.v naming contract points at the NONE-parity DUT by default
    // (matches phase-1 behavior exactly); EVEN/ODD-specific checks below
    // reference their own signals directly.
    wire       tx_busy  = tx_busy_none;
    wire       tx_done  = tx_done_none;
    wire [7:0] rx_data  = rx_data_none;
    wire       rx_valid = rx_valid_none;
    wire       rx_busy  = rx_busy_none;
    wire       parity_error  = parity_error_none;
    wire       framing_error = framing_error_none;
    wire       break_detected = break_detected_none;
    wire       tx_line = tx_none;

    `include "uart_tasks.v"

    //--------------------------------------------------------------------
    // capture_and_check_frame: samples the serial line for one full
    // NONE-parity frame (starting the cycle the line first goes low) and
    // checks every bit's duration and value against the byte that was
    // sent. Directly exercises start-bit duration, each data-bit duration,
    // stop-bit duration, LSB-first ordering, and total transmitted bit
    // count all at once.
    //--------------------------------------------------------------------
    localparam TOTAL_BITS_NONE    = 10;
    localparam TOTAL_SAMPLES_NONE = CLKS_PER_BIT * TOTAL_BITS_NONE;

    reg cap [0:255];
    integer ci;

    task capture_and_check_frame(input [7:0] data_byte);
        integer seg, samp, base;
        reg seg_ok, seg_val;
        begin
            wait (tx_line == 1'b0);
            @(negedge clk);
            for (ci = 0; ci < TOTAL_SAMPLES_NONE; ci = ci + 1) begin
                cap[ci] = tx_line;
                @(negedge clk);
            end
            for (seg = 0; seg < TOTAL_BITS_NONE; seg = seg + 1) begin
                base   = seg * CLKS_PER_BIT;
                seg_val = cap[base];
                seg_ok  = 1'b1;
                for (samp = 0; samp < CLKS_PER_BIT; samp = samp + 1) begin
                    if (cap[base + samp] !== seg_val)
                        seg_ok = 1'b0;
                end
                if (seg == 0) begin
                    check_cond("Start bit duration+value", seg_ok && (seg_val === 1'b0));
                end else if (seg <= 8) begin
                    check_cond("Data bit duration+value (LSB first)",
                                seg_ok && (seg_val === data_byte[seg-1]));
                end else begin
                    check_cond("Stop bit duration+value", seg_ok && (seg_val === 1'b1));
                end
            end
        end
    endtask

    // Generic loopback helpers, parameterized by which parity-mode DUT to
    // exercise (0=NONE,1=EVEN,2=ODD). Each set of three signals is a
    // separate DUT instance's ports (see naming contract note above on why
    // these are NOT passed as task "input" arguments -- Verilog task
    // inputs are sampled once at call time, not tracked live, which
    // silently breaks any `wait()`/polling done on them afterward).
    task send_none(input [7:0] b);
        begin
            wait (tx_busy_none == 1'b0);
            @(posedge clk); tx_data <= b; tx_start <= 1'b1;
            @(posedge clk); tx_start <= 1'b0;
        end
    endtask
    task wait_none(output [7:0] got);
        begin
            // tx_done and rx_valid don't reliably occur in a fixed order
            // relative to each other (see docs/architecture.md); waiting
            // for them sequentially can miss whichever one-cycle pulse
            // happens first. Fork/join waits for both concurrently.
            fork
                wait (tx_done_none == 1'b1);
                wait (rx_valid_none == 1'b1);
            join
            got = rx_data_none;
        end
    endtask

    task send_even(input [7:0] b);
        begin
            wait (tx_busy_even == 1'b0);
            @(posedge clk); tx_data <= b; tx_start <= 1'b1;
            @(posedge clk); tx_start <= 1'b0;
        end
    endtask
    task wait_even(output [7:0] got);
        begin
            // tx_done and rx_valid don't reliably occur in a fixed order
            // relative to each other (see docs/architecture.md); waiting
            // for them sequentially can miss whichever one-cycle pulse
            // happens first. Fork/join waits for both concurrently.
            fork
                wait (tx_done_even == 1'b1);
                wait (rx_valid_even == 1'b1);
            join
            got = rx_data_even;
        end
    endtask

    task send_odd(input [7:0] b);
        begin
            wait (tx_busy_odd == 1'b0);
            @(posedge clk); tx_data <= b; tx_start <= 1'b1;
            @(posedge clk); tx_start <= 1'b0;
        end
    endtask
    task wait_odd(output [7:0] got);
        begin
            // tx_done and rx_valid don't reliably occur in a fixed order
            // relative to each other (see docs/architecture.md); waiting
            // for them sequentially can miss whichever one-cycle pulse
            // happens first. Fork/join waits for both concurrently.
            fork
                wait (tx_done_odd == 1'b1);
                wait (rx_valid_odd == 1'b1);
            join
            got = rx_data_odd;
        end
    endtask

    //--------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------
    integer i;
    reg [7:0] pattern_bytes [0:3];
    reg [7:0] burst_bytes   [0:4];
    reg [7:0] rnd_byte;
    reg [7:0] got;
    reg [15:0] sweep;

    // Optional VCD waveform dump, enabled with `make waves TB=uart_tb`.
    // Off by default so ordinary regression runs don't pay the (small but
    // nonzero) cost of dumping every signal on every run.
`ifdef WAVES
    initial begin
        $dumpfile("uart_tb.vcd");
        $dumpvars(0, uart_tb);
    end
`endif

    initial begin
        tx_data  = 8'h00;
        tx_start = 1'b0;

        $display("----------------------------------------");
        $display("UART LOOPBACK TEST (NONE / EVEN / ODD parity)");
        $display("CLK_FREQ_HZ=%0d BAUD_RATE=%0d CLKS_PER_BIT=%0d",
                   CLK_FREQ_HZ, BAUD_RATE, CLKS_PER_BIT);
        $display("----------------------------------------");

        // ---- Reset behavior --------------------------------------------
        reset = 1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        check_cond("Reset: tx idle high (NONE)", tx_none === 1'b1);
        check_cond("Reset: tx idle high (EVEN)", tx_even === 1'b1);
        check_cond("Reset: tx idle high (ODD)",  tx_odd  === 1'b1);
        check_cond("Reset: tx_busy low (NONE)",  tx_busy_none === 1'b0);
        check_cond("Reset: rx_busy low (NONE)",  rx_busy_none === 1'b0);
        check_cond("Reset: no errors asserted (EVEN)",
                    !parity_error_even && !framing_error_even && !break_detected_even);
        reset = 0;
        @(posedge clk);

        // ---- TX idle behavior --------------------------------------------
        repeat (5) @(posedge clk);
        check_cond("TX idle: line stays high with no tx_start (NONE)", tx_none === 1'b1);

        // ---- Protocol-level timing check (NONE parity) --------------------
        // rx_valid can land before capture_and_check_frame finishes (its
        // duration is bounded by the slower of the two), so rx_valid's
        // wait must run concurrently in the SAME fork, not sequentially
        // afterward -- see docs/architecture.md / README "lessons learned".
        fork
            capture_and_check_frame(8'hA5);
            send_none(8'hA5);
            wait (rx_valid_none == 1'b1);
        join
        check_byte("Single-byte TX->RX loopback, NONE (0xA5)", 8'hA5, rx_data_none);
        wait (tx_done_none == 1'b1);
        check_cond("tx_busy deasserted immediately after tx_done (NONE)", tx_busy_none === 1'b0);
        @(negedge clk);
        check_cond("tx_done is a single-cycle pulse (NONE)", tx_done_none === 1'b0);
        check_cond("No rx_error on a clean frame (NONE)", rx_error_none === 1'b0);

        // ---- tx_busy asserted throughout an entire frame (NONE) ----------
        send_none(8'h3C);
        @(negedge clk);
        check_cond("tx_busy asserted right after tx_start (NONE)", tx_busy_none === 1'b1);
        repeat (CLKS_PER_BIT * 5) begin
            @(negedge clk);
            check_cond("tx_busy stays high mid-frame (NONE)", tx_busy_none === 1'b1);
        end
        fork
            wait (tx_done_none == 1'b1);
            wait (rx_valid_none == 1'b1);
        join
        check_byte("Loopback after busy-timing check (NONE, 0x3C)", 8'h3C, rx_data_none);

        //====================================================================
        // NORMAL OPERATION: full 0x00-0xFF sweep, one parity mode at a time
        //====================================================================
        for (sweep = 0; sweep < 256; sweep = sweep + 1) begin
            send_none(sweep[7:0]);
            wait_none(got);
            check_byte("0x00-0xFF sweep (NONE)", sweep[7:0], got);
        end
        for (sweep = 0; sweep < 256; sweep = sweep + 1) begin
            send_even(sweep[7:0]);
            wait_even(got);
            check_byte("0x00-0xFF sweep (EVEN)", sweep[7:0], got);
            check_cond("0x00-0xFF sweep (EVEN) -> no parity_error", parity_error_even === 1'b0);
        end
        for (sweep = 0; sweep < 256; sweep = sweep + 1) begin
            send_odd(sweep[7:0]);
            wait_odd(got);
            check_byte("0x00-0xFF sweep (ODD)", sweep[7:0], got);
            check_cond("0x00-0xFF sweep (ODD) -> no parity_error", parity_error_odd === 1'b0);
        end

        //====================================================================
        // Required byte patterns, each parity mode
        //====================================================================
        pattern_bytes[0] = 8'h00; pattern_bytes[1] = 8'hFF;
        pattern_bytes[2] = 8'h55; pattern_bytes[3] = 8'hAA;
        for (i = 0; i < 4; i = i + 1) begin
            send_even(pattern_bytes[i]); wait_even(got);
            check_byte("Pattern byte loopback (EVEN)", pattern_bytes[i], got);
            send_odd(pattern_bytes[i]);  wait_odd(got);
            check_byte("Pattern byte loopback (ODD)", pattern_bytes[i], got);
        end

        //====================================================================
        // Multiple consecutive / back-to-back bytes (NONE)
        //====================================================================
        burst_bytes[0] = 8'h11; burst_bytes[1] = 8'h22; burst_bytes[2] = 8'h33;
        burst_bytes[3] = 8'h44; burst_bytes[4] = 8'h99;
        for (i = 0; i < 5; i = i + 1) begin
            send_none(burst_bytes[i]);
            wait_none(got);
            check_byte("Back-to-back burst byte (NONE)", burst_bytes[i], got);
        end

        //====================================================================
        // Repeated bytes (same value sent several times in a row)
        //====================================================================
        for (i = 0; i < 5; i = i + 1) begin
            send_even(8'h5A);
            wait_even(got);
            check_byte("Repeated byte 0x5A (EVEN)", 8'h5A, got);
        end

        //====================================================================
        // Random bytes, each parity mode
        //====================================================================
        for (i = 0; i < 10; i = i + 1) begin
            rnd_byte = $random;
            send_none(rnd_byte); wait_none(got);
            check_byte("Random byte loopback (NONE)", rnd_byte, got);
        end
        for (i = 0; i < 10; i = i + 1) begin
            rnd_byte = $random;
            send_even(rnd_byte); wait_even(got);
            check_byte("Random byte loopback (EVEN)", rnd_byte, got);
        end
        for (i = 0; i < 10; i = i + 1) begin
            rnd_byte = $random;
            send_odd(rnd_byte); wait_odd(got);
            check_byte("Random byte loopback (ODD)", rnd_byte, got);
        end

        //====================================================================
        // RESET DURING TX / RX (loopback: a single reset affects both ends
        // at once, since this design has one shared reset input -- see
        // docs/architecture.md for why independent TX/RX reset timing is
        // out of scope for this phase)
        //====================================================================
        send_none(8'hE7);
        repeat (2 * CLKS_PER_BIT + CLKS_PER_BIT/2) @(posedge clk); // mid-frame
        reset = 1'b1;
        @(posedge clk);
        reset = 1'b0;
        @(negedge clk);
        check_cond("Reset mid-TX/RX: tx_busy clears (NONE)", tx_busy_none === 1'b0);
        check_cond("Reset mid-TX/RX: rx_busy clears (NONE)", rx_busy_none === 1'b0);
        check_cond("Reset mid-TX/RX: tx returns to idle high (NONE)", tx_none === 1'b1);
        check_cond("Reset mid-TX/RX: no spurious tx_done (NONE)", tx_done_none === 1'b0);
        check_cond("Reset mid-TX/RX: no spurious rx_valid (NONE)", rx_valid_none === 1'b0);
        repeat (5) @(posedge clk);
        // Confirm the link is fully functional again after the reset.
        send_none(8'h42);
        wait_none(got);
        check_byte("Loopback functional again after mid-frame reset (NONE)", 8'h42, got);

        print_summary;
        $finish;
    end

    // Safety watchdog in case a task hangs unexpectedly.
    initial begin
        #6_000_000;
        $display("*** GLOBAL WATCHDOG TIMEOUT — simulation stuck ***");
        $finish;
    end

endmodule
