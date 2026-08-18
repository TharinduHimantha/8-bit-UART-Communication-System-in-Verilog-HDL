//==============================================================================
// File: uart_tasks.v
//
// Shared, reusable testbench tasks and bookkeeping registers.
//
// This is plain Verilog, so there is no package/import mechanism to share
// code cleanly across testbench modules. The standard, portable way to
// share testbench code in pure Verilog is textual `include: this file is
// pasted verbatim into whichever testbench module includes it, so the reg
// declarations and tasks below become part of that module.
//
// CONTRACT: any testbench that includes this file must declare, at module
// scope, signals with exactly these names (all connected to the DUT):
//   clk, reset            - system clock / synchronous reset
//   tx_data, tx_start       - DUT TX inputs
//   tx_busy, tx_done         - DUT TX outputs
//   rx_data, rx_valid, rx_busy - DUT RX outputs
//   parity_error, framing_error, break_detected - DUT RX error outputs
//   tx_line                   - the serial wire between TX and RX (for
//                                loopback and protocol-level checks)
//==============================================================================

integer pass_count = 0;
integer fail_count = 0;
integer test_num   = 0;

reg [7:0] last_rx_data;

//------------------------------------------------------------------------
// Independent parity reference model.
//
// IMPORTANT: this is NOT the same code path as the RTL's parity formula.
// The RTL computes parity with a Verilog reduction-XOR (^data, one gate
// tree). This task instead walks the byte bit by bit with a for-loop and a
// running sum -- a different algorithm that happens to compute the same
// mathematical quantity (number of 1 bits, mod 2). Using a structurally
// different implementation is the point: if the RTL's reduction-XOR were
// ever wired up backwards, or an EVEN/ODD complement were swapped, this
// task computes the expected bit independently rather than by copying the
// DUT's own logic, so it would still catch the bug instead of silently
// agreeing with it.
//------------------------------------------------------------------------
function automatic model_parity_bit(input [7:0] data, input [1:0] mode);
    integer i;
    integer ones;
    begin
        ones = 0;
        for (i = 0; i < 8; i = i + 1)
            ones = ones + data[i];
        // mode: 0=NONE (unused), 1=EVEN, 2=ODD -- matches rtl/uart_defs.vh
        if (mode == 2'd2)
            model_parity_bit = (ones % 2 == 0) ? 1'b1 : 1'b0; // ODD
        else
            model_parity_bit = (ones % 2 == 0) ? 1'b0 : 1'b1; // EVEN
    end
endfunction

//------------------------------------------------------------------------
// send_byte: drives a single tx_start pulse with the given data byte.
// Assumes the caller has already confirmed tx_busy == 0.
//------------------------------------------------------------------------
task send_byte(input [7:0] data);
    begin
        @(posedge clk);
        tx_data  <= data;
        tx_start <= 1'b1;
        @(posedge clk);
        tx_start <= 1'b0;
    end
endtask

//------------------------------------------------------------------------
// wait_for_tx_done: blocks until the TX side finishes the current frame.
//------------------------------------------------------------------------
task wait_for_tx_done;
    integer timeout;
    begin
        timeout = 0;
        // Poll at negedge: DUT outputs update on posedge via nonblocking
        // assignments, so a read taken immediately at posedge can still
        // see the pre-update value (NBA updates settle a moment later).
        while ((tx_done !== 1'b1) && (timeout < 200000)) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 200000) begin
            $display("  *** TIMEOUT waiting for tx_done ***");
            fail_count = fail_count + 1;
        end
    end
endtask

//------------------------------------------------------------------------
// wait_for_rx_outcome: blocks until the RX side reaches SOME outcome for
// the current frame -- rx_valid (clean), parity_error, or framing_error --
// and reports which. Waiting for "any outcome" rather than only rx_valid
// is what lets a single task be reused for both positive and negative
// (fault-injection) tests.
//------------------------------------------------------------------------
task wait_for_rx_outcome(output got_valid, output got_perr, output got_ferr);
    integer timeout;
    begin
        timeout   = 0;
        got_valid = 1'b0;
        got_perr  = 1'b0;
        got_ferr  = 1'b0;
        while (!got_valid && !got_perr && !got_ferr && (timeout < 200000)) begin
            @(negedge clk);
            if (rx_valid)      got_valid = 1'b1;
            if (parity_error)  got_perr  = 1'b1;
            if (framing_error) got_ferr  = 1'b1;
            timeout = timeout + 1;
        end
        if (got_valid) last_rx_data = rx_data;
        if (timeout >= 200000) begin
            $display("  *** TIMEOUT waiting for an RX outcome ***");
            fail_count = fail_count + 1;
        end
    end
endtask

//------------------------------------------------------------------------
// wait_for_tx_and_rx: waits for BOTH tx_done and a clean rx_valid. These
// pulses do not necessarily occur in a fixed order relative to each other
// (rx_valid depends on the RX input synchronizer latency and its own
// independent bit-timing ladder, so it can land a cycle or two before or
// after tx_done). Waiting for them one after another sequentially can miss
// whichever one-cycle pulse happens first; waiting concurrently avoids
// that race entirely.
//------------------------------------------------------------------------
task wait_for_tx_and_rx;
    reg gv, gp, gf;
    begin
        fork
            wait_for_tx_done;
            wait_for_rx_outcome(gv, gp, gf);
        join
    end
endtask

//------------------------------------------------------------------------
// check_byte: compares an actual byte to an expected byte and logs a
// PASS/FAIL line. Also used for generic byte-valued checks.
//------------------------------------------------------------------------
task check_byte(input [8*52-1:0] name, input [7:0] expected, input [7:0] actual);
    begin
        test_num = test_num + 1;
        if (actual === expected) begin
            pass_count = pass_count + 1;
            $display("TEST %0d: %-50s PASS  (expected 0x%02h, got 0x%02h)",
                       test_num, name, expected, actual);
        end else begin
            fail_count = fail_count + 1;
            $display("TEST %0d: %-50s FAIL  (expected 0x%02h, got 0x%02h)",
                       test_num, name, expected, actual);
        end
    end
endtask

//------------------------------------------------------------------------
// check_cond: generic boolean/protocol-level check (not a byte compare).
//------------------------------------------------------------------------
task check_cond(input [8*52-1:0] name, input cond);
    begin
        test_num = test_num + 1;
        if (cond) begin
            pass_count = pass_count + 1;
            $display("TEST %0d: %-50s PASS", test_num, name);
        end else begin
            fail_count = fail_count + 1;
            $display("TEST %0d: %-50s FAIL", test_num, name);
        end
    end
endtask

//------------------------------------------------------------------------
// print_summary: final PASS/FAIL banner.
//------------------------------------------------------------------------
task print_summary;
    begin
        $display("----------------------------------------");
        $display("  %0d / %0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_count);
        $display("----------------------------------------");
    end
endtask
