//==============================================================================
// File: uart_tasks.v
//
// Shared, reusable testbench tasks and bookkeeping registers.
//
// This is plain Verilog, so there is no package/import mechanism to share
// code cleanly across testbench modules. The standard, portable way to
// share testbench code in pure Verilog is textual `include: this file is
// pasted verbatim into whichever testbench module includes it, so the
// reg declarations and tasks below become part of that module.
//
// CONTRACT: any testbench that includes this file must declare, at module
// scope, signals with exactly these names (all connected to the DUT):
//   clk, reset          - system clock / synchronous reset
//   tx_data, tx_start    - DUT TX inputs
//   tx_busy, tx_done      - DUT TX outputs
//   rx_data, rx_valid, rx_busy, rx_error - DUT RX outputs
//   tx_line               - the serial wire between TX and RX (for loopback
//                            and protocol-level checks)
//
// This is analogous to a lightweight informal "interface" and is a common,
// well-understood pattern in pure-Verilog verification environments that
// predate SystemVerilog.
//==============================================================================

integer pass_count = 0;
integer fail_count = 0;
integer test_num   = 0;

reg [7:0] last_rx_data;

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
// Includes a timeout so a broken DUT hangs the simulation loudly instead
// of silently forever.
//------------------------------------------------------------------------
task wait_for_tx_done;
    integer timeout;
    begin
        timeout = 0;
        // Poll at negedge: DUT outputs update on posedge via nonblocking
        // assignments, so a read taken immediately at posedge can still
        // see the pre-update value (NBA updates settle a moment later).
        // negedge is comfortably past that settling point.
        while ((tx_done !== 1'b1) && (timeout < 100000)) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 100000) begin
            $display("  *** TIMEOUT waiting for tx_done ***");
            fail_count = fail_count + 1;
        end
    end
endtask

//------------------------------------------------------------------------
// wait_for_rx_valid: blocks until the RX side produces a new byte, and
// captures it into last_rx_data.
//------------------------------------------------------------------------
task wait_for_rx_valid;
    integer timeout;
    begin
        timeout = 0;
        while ((rx_valid !== 1'b1) && (timeout < 100000)) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 100000) begin
            $display("  *** TIMEOUT waiting for rx_valid ***");
            fail_count = fail_count + 1;
        end else begin
            last_rx_data = rx_data;
        end
    end
endtask

//------------------------------------------------------------------------
// wait_for_tx_and_rx: waits for BOTH tx_done and rx_valid. These two
// pulses do not necessarily occur in a fixed order relative to each
// other (rx_valid depends on the RX input synchronizer latency and its
// own independent bit-timing ladder, so it can land a cycle or two before
// or after tx_done). Waiting for them one after another sequentially can
// therefore miss whichever one-cycle pulse happens first, since polling
// for it wouldn't even start until the other wait has already returned.
// Waiting for both concurrently avoids that race entirely.
//------------------------------------------------------------------------
task wait_for_tx_and_rx;
    begin
        fork
            wait_for_tx_done;
            wait_for_rx_valid;
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
