//==============================================================================
// File   : uart_rx_tb.v
// Purpose: Unit-level testbench for uart_rx ONLY (no uart_tx). Frames are
//          driven directly onto dedicated "rx" pins by bit-banging tasks in
//          this testbench, independent of uart_tx entirely. This is where
//          the bulk of this phase's fault injection lives: bad parity, bad
//          stop bit, glitches, and break conditions of various durations,
//          none of which a working uart_tx could ever produce on its own.
//
// Two DUT instances are used, one per parity mode under active test
// (EVEN and ODD); NONE-parity behavior is already covered by the main
// loopback testbench and by uart_tx_tb.v.
//==============================================================================

`timescale 1ns/1ps
`include "uart_defs.vh"

module uart_rx_tb;

    localparam CLKS_PER_BIT = 10;

    reg clk = 0;
    reg reset = 1;

    reg rx_line_even = 1'b1;
    reg rx_line_odd  = 1'b1;

    wire [7:0] rx_data_even, rx_data_odd;
    wire rx_valid_even, rx_busy_even, parity_error_even, framing_error_even, break_detected_even;
    wire rx_valid_odd,  rx_busy_odd,  parity_error_odd,  framing_error_odd,  break_detected_odd;

    always #5 clk = ~clk;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT), .PARITY_MODE(`UART_PARITY_EVEN)) dut_even (
        .clk(clk), .reset(reset), .rx(rx_line_even),
        .rx_data(rx_data_even), .rx_valid(rx_valid_even), .rx_busy(rx_busy_even),
        .parity_error(parity_error_even), .framing_error(framing_error_even),
        .break_detected(break_detected_even));

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT), .PARITY_MODE(`UART_PARITY_ODD)) dut_odd (
        .clk(clk), .reset(reset), .rx(rx_line_odd),
        .rx_data(rx_data_odd), .rx_valid(rx_valid_odd), .rx_busy(rx_busy_odd),
        .parity_error(parity_error_odd), .framing_error(framing_error_odd),
        .break_detected(break_detected_odd));

    // uart_tasks.v naming contract -- point it at the EVEN instance by
    // default; ODD-specific checks reference dut_odd's signals directly.
    wire [7:0] rx_data       = rx_data_even;
    wire       rx_valid      = rx_valid_even;
    wire       rx_busy       = rx_busy_even;
    wire       parity_error  = parity_error_even;
    wire       framing_error = framing_error_even;
    wire       break_detected = break_detected_even;
    reg  [7:0] tx_data = 8'h00;
    reg        tx_start = 1'b0, tx_busy = 1'b0, tx_done = 1'b0;
    wire       tx_line = rx_line_even;

    `include "uart_tasks.v"

    //--------------------------------------------------------------------
    // Bit-level drivers. Each holds a value for exactly CLKS_PER_BIT
    // cycles, driven from negedge so it is stable well before uart_rx's
    // midpoint sample.
    //
    // NOTE on rx_busy lingering after a frame: whenever a frame's LAST
    // driven value is 0 (a bad stop bit, or the trailing edge of a break
    // hold), releasing the line to 1 takes 2 extra cycles to reach rx_s
    // through the input synchronizer. In that gap, uart_rx's own S_IDLE
    // state can see rx_s still 0, correctly (by design) treat it as a
    // candidate new start bit, and enter S_START for a few cycles before
    // its own half-bit glitch filter clears it back to idle. This is
    // harmless in isolation, but the frame driver tasks below wait for
    // rx_busy to fully clear before starting the NEXT frame specifically
    // to avoid overlapping a brand-new (real) start bit with that tail-end
    // transient from the previous one.
    //--------------------------------------------------------------------
    task drive_bit_even(input v);
        begin
            @(negedge clk); rx_line_even = v;
            repeat (CLKS_PER_BIT - 1) @(negedge clk);
        end
    endtask
    task drive_bit_odd(input v);
        begin
            @(negedge clk); rx_line_odd = v;
            repeat (CLKS_PER_BIT - 1) @(negedge clk);
        end
    endtask

    // Full frame driver, EVEN-parity DUT. inject_bad_parity / inject_bad_stop
    // deliberately corrupt exactly one field so each fault can be isolated.
    task drive_frame_even(input [7:0] data, input inject_bad_parity, input inject_bad_stop);
        integer i;
        reg p;
        begin
            wait (rx_busy_even == 1'b0); // don't start until fully idle; see comment above
            p = model_parity_bit(data, `UART_PARITY_EVEN);
            if (inject_bad_parity) p = ~p;
            drive_bit_even(1'b0);                    // start
            for (i = 0; i < 8; i = i + 1) drive_bit_even(data[i]);
            drive_bit_even(p);                        // parity (maybe corrupted)
            drive_bit_even(inject_bad_stop ? 1'b0 : 1'b1); // stop (maybe corrupted)
            rx_line_even = 1'b1;                       // release to idle -- immediately;
                                                          // drive_bit_even already ended
                                                          // exactly at this bit's boundary
        end
    endtask

    task drive_frame_odd(input [7:0] data, input inject_bad_parity, input inject_bad_stop);
        integer i;
        reg p;
        begin
            wait (rx_busy_odd == 1'b0);
            p = model_parity_bit(data, `UART_PARITY_ODD);
            if (inject_bad_parity) p = ~p;
            drive_bit_odd(1'b0);
            for (i = 0; i < 8; i = i + 1) drive_bit_odd(data[i]);
            drive_bit_odd(p);
            drive_bit_odd(inject_bad_stop ? 1'b0 : 1'b1);
            rx_line_odd = 1'b1;
        end
    endtask

    // A start-bit-shaped pulse shorter than half a bit period: should be
    // silently rejected as noise (see uart_rx.v "Glitch filtering").
    task drive_glitch_even;
        begin
            @(negedge clk); rx_line_even = 1'b0;
            repeat (CLKS_PER_BIT/2 - 2) @(negedge clk); // well under half-bit
            rx_line_even = 1'b1;
        end
    endtask

    // Holds the line low for exactly n_cycles clocks, then releases high.
    task hold_low_even(input integer n_cycles);
        integer k;
        begin
            @(negedge clk); rx_line_even = 1'b0;
            for (k = 1; k < n_cycles; k = k + 1) @(negedge clk);
            rx_line_even = 1'b1;
        end
    endtask

    task wait_for_rx_outcome_odd(output got_valid, output got_perr, output got_ferr);
        integer timeout;
        begin
            timeout = 0; got_valid = 0; got_perr = 0; got_ferr = 0;
            while (!got_valid && !got_perr && !got_ferr && (timeout < 200000)) begin
                @(negedge clk);
                if (rx_valid_odd)      got_valid = 1'b1;
                if (parity_error_odd)  got_perr  = 1'b1;
                if (framing_error_odd) got_ferr  = 1'b1;
                timeout = timeout + 1;
            end
        end
    endtask

    //--------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------
    integer i;
    reg [7:0] bytes [0:4];
    reg got_valid, got_perr, got_ferr;
    reg got_valid_o, got_perr_o, got_ferr_o;

    // BREAK_THRESHOLD_BITS default for an 11-bit EVEN frame is
    // (1+8+1+1)+1 = 12 bits -> 120 cycles at CLKS_PER_BIT=10.
    localparam integer FRAME_BITS_EVEN     = 11;
    localparam integer BREAK_CYCLES        = CLKS_PER_BIT * (FRAME_BITS_EVEN + 1);

    // Optional VCD waveform dump, enabled with `make waves TB=uart_rx_tb`.
    // Off by default so ordinary regression runs don't pay the (small but
    // nonzero) cost of dumping every signal on every run.
`ifdef WAVES
    initial begin
        $dumpfile("uart_rx_tb.vcd");
        $dumpvars(0, uart_rx_tb);
    end
`endif

    initial begin
        $display("----------------------------------------");
        $display("UART RX UNIT TEST (parity / framing / break fault injection)");
        $display("----------------------------------------");

        repeat (3) @(posedge clk);
        @(negedge clk);
        check_cond("Reset: rx_busy low (EVEN)",  rx_busy_even  === 1'b0);
        check_cond("Reset: rx_valid low (EVEN)", rx_valid_even === 1'b0);
        check_cond("Reset: no errors (EVEN)",
                    (parity_error_even === 1'b0) && (framing_error_even === 1'b0) &&
                    (break_detected_even === 1'b0));
        reset = 0;
        @(posedge clk);

        //================================================================
        // NORMAL OPERATION (EVEN parity), several byte patterns
        //================================================================
        bytes[0] = 8'h00; bytes[1] = 8'hFF; bytes[2] = 8'h55;
        bytes[3] = 8'hAA; bytes[4] = 8'h01;
        for (i = 0; i < 5; i = i + 1) begin
            fork
                drive_frame_even(bytes[i], 1'b0, 1'b0);
                wait_for_rx_outcome(got_valid, got_perr, got_ferr);
            join
            check_cond("Good EVEN frame -> clean rx_valid", got_valid && !got_perr && !got_ferr);
            check_byte("Good EVEN frame -> correct byte", bytes[i], last_rx_data);
        end

        //================================================================
        // PARITY FAULT INJECTION (EVEN)
        //================================================================
        for (i = 0; i < 5; i = i + 1) begin
            fork
                drive_frame_even(bytes[i], 1'b1, 1'b0); // bad parity, good stop
                wait_for_rx_outcome(got_valid, got_perr, got_ferr);
            join
            check_cond("Injected bad parity -> parity_error, no rx_valid",
                        got_perr && !got_valid && !got_ferr);
        end

        //================================================================
        // PARITY FAULT INJECTION (ODD DUT, independent instance)
        //================================================================
        for (i = 0; i < 5; i = i + 1) begin
            fork
                drive_frame_odd(bytes[i], 1'b0, 1'b0); // correct ODD frame
                wait_for_rx_outcome_odd(got_valid_o, got_perr_o, got_ferr_o);
            join
            check_cond("Good ODD frame -> clean rx_valid", got_valid_o && !got_perr_o);
            check_byte("Good ODD frame -> correct byte", bytes[i], rx_data_odd);

            fork
                drive_frame_odd(bytes[i], 1'b1, 1'b0); // bad parity
                wait_for_rx_outcome_odd(got_valid_o, got_perr_o, got_ferr_o);
            join
            check_cond("ODD: injected bad parity -> parity_error", got_perr_o && !got_valid_o);
        end

        //================================================================
        // FRAMING FAULT INJECTION (EVEN)
        //================================================================
        for (i = 0; i < 5; i = i + 1) begin
            fork
                drive_frame_even(bytes[i], 1'b0, 1'b1); // good parity, bad stop
                wait_for_rx_outcome(got_valid, got_perr, got_ferr);
            join
            check_cond("Injected bad stop bit -> framing_error, no rx_valid",
                        got_ferr && !got_valid && !got_perr);
        end

        //================================================================
        // COMBINED PARITY + FRAMING ERROR
        //================================================================
        fork
            drive_frame_even(8'h3C, 1'b1, 1'b1); // both corrupted
            begin : combined_wait
                integer t;
                reg gv, gp, gf;
                gv = 0; gp = 0; gf = 0;
                for (t = 0; t < 20*CLKS_PER_BIT; t = t + 1) begin
                    @(negedge clk);
                    if (rx_valid_even)      gv = 1'b1;
                    if (parity_error_even)  gp = 1'b1;
                    if (framing_error_even) gf = 1'b1;
                end
                check_cond("Parity+framing both wrong -> both errors pulse, no rx_valid",
                            gp && gf && !gv);
            end
        join

        //================================================================
        // BACK-TO-BACK FRAMES, NO IDLE GAP, MIXED GOOD/BAD
        //================================================================
        fork
            begin
                drive_frame_even(8'hDE, 1'b0, 1'b0); // good
                drive_frame_even(8'hAD, 1'b1, 1'b0); // bad parity
                drive_frame_even(8'hBE, 1'b0, 1'b0); // good
            end
            begin : b2b_watch
                integer n_valid, n_perr, t;
                reg [7:0] seen [0:1];
                n_valid = 0; n_perr = 0;
                for (t = 0; t < 40*CLKS_PER_BIT; t = t + 1) begin
                    @(negedge clk);
                    if (rx_valid_even) begin
                        seen[n_valid] = rx_data_even;
                        n_valid = n_valid + 1;
                    end
                    if (parity_error_even) n_perr = n_perr + 1;
                end
                check_cond("Back-to-back: exactly 2 clean bytes received", n_valid == 2);
                check_cond("Back-to-back: exactly 1 parity error", n_perr == 1);
                if (n_valid == 2) begin
                    check_byte("Back-to-back frame 1 (good)", 8'hDE, seen[0]);
                    check_byte("Back-to-back frame 3 (good)", 8'hBE, seen[1]);
                end
            end
        join

        //================================================================
        // GLITCH (shorter than half a bit period) -> silently rejected
        //================================================================
        got_valid = 0; got_perr = 0; got_ferr = 0;
        fork
            drive_glitch_even;
            begin : glitch_watch
                integer t;
                for (t = 0; t < CLKS_PER_BIT * 3; t = t + 1) begin
                    @(negedge clk);
                    if (rx_valid_even)      got_valid = 1'b1;
                    if (parity_error_even)  got_perr  = 1'b1;
                    if (framing_error_even) got_ferr  = 1'b1;
                end
            end
        join
        check_cond("Sub-half-bit glitch -> no rx_valid and no error flags at all",
                    !got_valid && !got_perr && !got_ferr);

        //================================================================
        // BREAK DETECTION: below / at / above threshold
        //================================================================
        // Just below threshold: line released 1 cycle before the break
        // would be declared. As explained in docs/architecture.md, the
        // line will still have produced exactly one spurious framing_error
        // partway through this hold (from the "byte" made of all-zero bits
        // that necessarily elapses before the hold is long enough to be a
        // break) -- that is expected, not a bug: any receiver watching a
        // stuck-low line sees a garbage framed byte before it has enough
        // history to call it a break.
        begin : below_threshold
            integer t, n_ferr;
            n_ferr = 0;
            fork
                hold_low_even(BREAK_CYCLES - 1);
                for (t = 0; t < BREAK_CYCLES + 5; t = t + 1) begin
                    @(negedge clk);
                    if (framing_error_even) n_ferr = n_ferr + 1;
                end
            join
            check_cond("Just below break threshold -> break_detected never asserts",
                        !break_detected_even);
            check_cond("Just below break threshold -> exactly one leading framing_error",
                        n_ferr == 1);
        end

        repeat (10) @(posedge clk);

        // At/above threshold: line held low long enough to cross it.
        begin : at_threshold
            reg seen_break;
            seen_break = 1'b0;
            fork
                hold_low_even(BREAK_CYCLES + 20);
                begin : break_watch
                    integer t;
                    for (t = 0; t < BREAK_CYCLES + 30; t = t + 1) begin
                        @(negedge clk);
                        if (break_detected_even) seen_break = 1'b1;
                    end
                end
            join
            check_cond("At/above break threshold -> break_detected asserts", seen_break);
            check_cond("After line release -> break_detected clears", !break_detected_even);
        end

        repeat (10) @(posedge clk);

        //================================================================
        // BREAK FOLLOWED BY A VALID FRAME (recovery)
        //================================================================
        // Deliberately sequential, not forked: the break hold itself
        // produces one expected spurious framing_error partway through
        // (see the "just below threshold" test above for why). Starting
        // wait_for_rx_outcome concurrently with the hold would catch that
        // spurious pulse and return immediately, never seeing the actual
        // post-break frame's outcome. So the hold runs to completion
        // first, and only the real recovery frame is raced against the
        // outcome-waiter.
        hold_low_even(BREAK_CYCLES + 20);
        fork
            drive_frame_even(8'h5A, 1'b0, 1'b0);
            wait_for_rx_outcome(got_valid, got_perr, got_ferr);
        join
        check_cond("Valid frame immediately after a break -> clean rx_valid",
                    got_valid && !got_perr && !got_ferr);
        check_byte("Valid frame immediately after a break -> correct byte", 8'h5A, last_rx_data);

        //================================================================
        // RESET DURING RECEPTION
        //================================================================
        fork
            begin
                drive_bit_even(1'b0);           // start
                drive_bit_even(1'b1);           // data bit 0
                drive_bit_even(1'b0);           // data bit 1 -- reset lands here
            end
            begin
                repeat (2 * CLKS_PER_BIT + CLKS_PER_BIT/2) @(posedge clk);
                reset = 1'b1;
                @(posedge clk);
                reset = 1'b0;
                rx_line_even = 1'b1; // release the line the driver task abandoned
            end
        join
        @(negedge clk);
        check_cond("Reset mid-frame -> rx_busy clears", rx_busy_even === 1'b0);
        check_cond("Reset mid-frame -> no spurious rx_valid/errors",
                    (rx_valid_even === 1'b0) && (parity_error_even === 1'b0) &&
                    (framing_error_even === 1'b0));
        repeat (5) @(posedge clk);
        // Confirm the receiver is fully functional again after the reset.
        fork
            drive_frame_even(8'h99, 1'b0, 1'b0);
            wait_for_rx_outcome(got_valid, got_perr, got_ferr);
        join
        check_cond("Receiver functional again after mid-frame reset", got_valid);
        check_byte("Post-reset-recovery frame correct", 8'h99, last_rx_data);

        print_summary;
        $finish;
    end

    initial begin
        #2_000_000;
        $display("*** WATCHDOG TIMEOUT ***");
        $finish;
    end

endmodule
