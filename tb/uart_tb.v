//==============================================================================
// File   : uart_tb.v
// Purpose: Top-level, self-checking UART loopback testbench.
//
//   uart_tx.tx  ---->  tx_line  ---->  uart_rx.rx
//
// The DUT's own tx pin is wired directly back to its own rx pin (a
// loopback), so any byte written in on tx_data should, a short time later,
// appear on rx_data with rx_valid pulsed.
//
// This testbench checks far more than "rx_data == tx_data": it inspects
// the actual serial line to verify start/data/stop bit widths and bit
// ordering, and it checks the timing of tx_busy, tx_done and rx_valid --
// not just their final values.
//
// Simulation-only baud parameters: a real design might use 50 MHz / 115200
// baud (see docs/architecture.md for that math), but that gives 434 clock
// cycles per bit, which would make this testbench slow to simulate for no
// benefit. Since TX and RX are always driven from the exact same
// CLKS_PER_BIT value (computed once, inside uart.v), functional
// correctness is completely independent of the actual numeric value
// chosen here. CLKS_PER_BIT = 10 keeps simulation fast and keeps the
// captured serial-line waveforms easy to reason about by eye if needed.
//==============================================================================

`timescale 1ns/1ps

module uart_tb;

    localparam CLK_FREQ_HZ = 1000;
    localparam BAUD_RATE   = 100;     // CLKS_PER_BIT = 1000/100 = 10
    localparam CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam CLK_PERIOD_NS = 10;

    localparam TOTAL_BITS    = 10;                       // start+8 data+stop
    localparam TOTAL_SAMPLES = CLKS_PER_BIT * TOTAL_BITS;

    reg clk = 0;
    reg reset = 1;

    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;
    wire       tx_done;

    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_busy;
    wire       rx_error;

    wire tx_line;

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    uart #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) dut (
        .clk      (clk),
        .reset    (reset),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx_busy  (tx_busy),
        .tx_done  (tx_done),
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .rx_busy  (rx_busy),
        .rx_error (rx_error),
        .tx       (tx_line),
        .rx       (tx_line)          // <-- loopback
    );

    `include "uart_tasks.v"

    //--------------------------------------------------------------------
    // capture_frame: samples the serial line for one full frame (starting
    // the cycle the line first goes low) and checks every bit's duration
    // and value against the byte that was sent. This directly exercises
    // start-bit duration, each data-bit duration, stop-bit duration,
    // LSB-first ordering, and total transmitted bit count all at once.
    //--------------------------------------------------------------------
    reg cap [0:255];
    integer ci;

    task capture_and_check_frame(input [7:0] data_byte);
        integer seg, samp, base;
        reg seg_ok;
        reg seg_val;
        begin
            // Wait for the line to fall (start bit leading edge), then
            // sample once per clock for the whole frame.
            // Sample once per bit-clock at negedge (safely mid-period, after
            // any posedge-triggered updates have settled) so each captured
            // sample reflects the value that was actually stable during
            // that clock period, not a stale pre-update value.
            wait (tx_line == 1'b0);
            @(negedge clk);
            for (ci = 0; ci < TOTAL_SAMPLES; ci = ci + 1) begin
                cap[ci] = tx_line;
                @(negedge clk);
            end

            for (seg = 0; seg < TOTAL_BITS; seg = seg + 1) begin
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

    //--------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------
    integer i;
    reg [7:0] pattern_bytes [0:3];
    reg [7:0] burst_bytes   [0:4];
    reg [7:0] rnd_byte;

    initial begin
        tx_data  = 8'h00;
        tx_start = 1'b0;

        $display("----------------------------------------");
        $display("UART LOOPBACK TEST");
        $display("CLK_FREQ_HZ=%0d BAUD_RATE=%0d CLKS_PER_BIT=%0d",
                   CLK_FREQ_HZ, BAUD_RATE, CLKS_PER_BIT);
        $display("----------------------------------------");

        // ---- Reset behavior --------------------------------------------
        reset = 1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        check_cond("Reset: tx idle high",   tx_line  === 1'b1);
        check_cond("Reset: tx_busy low",    tx_busy  === 1'b0);
        check_cond("Reset: rx_busy low",    rx_busy  === 1'b0);
        reset = 0;
        @(posedge clk);

        // ---- TX idle behavior (no activity requested) -------------------
        repeat (5) @(posedge clk);
        check_cond("TX idle: line stays high with no tx_start", tx_line === 1'b1);

        // ---- Protocol-level timing check (start/data/stop bit widths,
        //      LSB-first ordering) run concurrently with a real send -----
        // rx_valid is only asserted for a single cycle, and (because of the
        // RX input synchronizer plus its own independent bit-timing ladder)
        // it can land slightly before the TX-side line capture finishes.
        // All three must therefore run concurrently in the same fork/join,
        // or a narrow pulse can be missed entirely by the time a later,
        // sequential wait_for_rx_valid starts polling.
        fork
            capture_and_check_frame(8'hA5);
            send_byte(8'hA5);
            wait_for_rx_valid;
        join
        wait_for_tx_done;
        check_cond("tx_busy deasserted immediately after tx_done", tx_busy === 1'b0);
        @(negedge clk);
        check_cond("tx_done is a single-cycle pulse", tx_done === 1'b0);
        check_byte("Single-byte TX->RX loopback (0xA5)", 8'hA5, last_rx_data);
        @(negedge clk);
        check_cond("rx_valid is a single-cycle pulse", rx_valid === 1'b0);
        check_byte("rx_data holds after rx_valid falls", 8'hA5, rx_data);
        check_cond("No rx_error on a clean frame", rx_error === 1'b0);

        // ---- tx_busy asserted throughout an entire frame ----------------
        send_byte(8'h3C);
        @(negedge clk);
        check_cond("tx_busy asserted right after tx_start", tx_busy === 1'b1);
        repeat (CLKS_PER_BIT * 5) begin
            @(negedge clk);
            check_cond("tx_busy stays high mid-frame", tx_busy === 1'b1);
        end
        wait_for_tx_and_rx;
        check_byte("Loopback after busy-timing check (0x3C)", 8'h3C, last_rx_data);

        // ---- Required byte patterns --------------------------------------
        pattern_bytes[0] = 8'h00;
        pattern_bytes[1] = 8'hFF;
        pattern_bytes[2] = 8'h55;
        pattern_bytes[3] = 8'hAA;
        for (i = 0; i < 4; i = i + 1) begin
            check_cond("tx not busy before next send", tx_busy === 1'b0);
            send_byte(pattern_bytes[i]);
            wait_for_tx_and_rx;
            check_byte("Pattern byte loopback", pattern_bytes[i], last_rx_data);
        end

        // ---- Multiple consecutive / back-to-back bytes -------------------
        burst_bytes[0] = 8'h11;
        burst_bytes[1] = 8'h22;
        burst_bytes[2] = 8'h33;
        burst_bytes[3] = 8'h44;
        burst_bytes[4] = 8'h99;
        for (i = 0; i < 5; i = i + 1) begin
            send_byte(burst_bytes[i]);
            wait_for_tx_and_rx; // minimal gap: send next as soon as idle
            check_byte("Back-to-back burst byte", burst_bytes[i], last_rx_data);
        end

        // ---- Random bytes --------------------------------------------
        for (i = 0; i < 8; i = i + 1) begin
            rnd_byte = $random;
            check_cond("tx not busy before random send", tx_busy === 1'b0);
            send_byte(rnd_byte);
            wait_for_tx_and_rx;
            check_byte("Random byte loopback", rnd_byte, last_rx_data);
        end

        print_summary;
        $finish;
    end

    // Safety watchdog in case a task hangs unexpectedly.
    initial begin
        #2_000_000;
        $display("*** GLOBAL WATCHDOG TIMEOUT — simulation stuck ***");
        $finish;
    end

endmodule
