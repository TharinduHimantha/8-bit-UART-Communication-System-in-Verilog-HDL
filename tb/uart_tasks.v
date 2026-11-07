//==============================================================================
// File: uart_tasks.v
//
// Shared, reusable testbench tasks, `include`d by every testbench in this
// project (see docs/verification.md for the full verification
// architecture). Plain Verilog has no package/import mechanism, so
// textual `include is the standard, portable way to share this code.
//
// CONTRACT: any testbench that includes this file must declare, at module
// scope, a DUT-facing register bus with exactly these names:
//   clk, reset, addr, write_en, write_data, read_en, read_data, ready
// (ready is read but never driven by these tasks -- it is tied high in
// uart_top.v; see uart_regs.v's header for why no wait-state handling is
// implemented here).
//==============================================================================

`include "uart_defs.vh"

integer pass_count = 0;
integer fail_count = 0;
integer test_num   = 0;

//------------------------------------------------------------------------
// Independent parity reference model (see docs/verification.md for why
// this is a structurally different computation from the RTL's reduction-
// XOR, not a copy of it).
//------------------------------------------------------------------------
function automatic model_parity_bit(input [7:0] data, input [1:0] mode);
    integer i;
    integer ones;
    begin
        ones = 0;
        for (i = 0; i < 8; i = i + 1)
            ones = ones + data[i];
        if (mode == `UART_PARITY_ODD)
            model_parity_bit = (ones % 2 == 0) ? 1'b1 : 1'b0;
        else
            model_parity_bit = (ones % 2 == 0) ? 1'b0 : 1'b1;
    end
endfunction

//------------------------------------------------------------------------
// Register-bus driver tasks. IMPORTANT (see docs/verification.md
// "lessons learned"): `reset` transitions elsewhere in each testbench
// MUST use nonblocking assignment (reset <= 1'b1;), never blocking
// (reset = 1'b1;), if the transition can land on the same edge the DUT
// samples it -- a blocking assignment there is a genuine, simulator-
// order-dependent race against the DUT's own always @(posedge clk)
// block, found the hard way during this project's FIFO bring-up.
//------------------------------------------------------------------------
task reg_write(input [7:0] a, input [31:0] d);
    begin
        @(posedge clk);
        addr       <= a;
        write_data <= d;
        write_en   <= 1'b1;
        @(posedge clk);
        write_en   <= 1'b0;
    end
endtask

// Reads are combinational in this design (see uart_regs.v), but the value
// is only guaranteed settled a moment after the triggering posedge (NBA
// ordering -- see docs/verification.md), so this samples at negedge, not
// immediately after posedge.
task reg_read(input [7:0] a, output [31:0] d);
    begin
        @(posedge clk);
        addr    <= a;
        read_en <= 1'b1;
        @(negedge clk);
        d = read_data;
        @(posedge clk);
        read_en <= 1'b0;
    end
endtask

//------------------------------------------------------------------------
// check_byte / check_cond / check_word: shared PASS/FAIL bookkeeping.
//------------------------------------------------------------------------
task check_byte(input [8*60-1:0] name, input [7:0] expected, input [7:0] actual);
    begin
        test_num = test_num + 1;
        if (actual === expected) begin
            pass_count = pass_count + 1;
            $display("TEST %0d: %-56s PASS  (expected 0x%02h, got 0x%02h)",
                       test_num, name, expected, actual);
        end else begin
            fail_count = fail_count + 1;
            $display("TEST %0d: %-56s FAIL  (expected 0x%02h, got 0x%02h)",
                       test_num, name, expected, actual);
        end
    end
endtask

task check_word(input [8*60-1:0] name, input [31:0] expected, input [31:0] actual);
    begin
        test_num = test_num + 1;
        if (actual === expected) begin
            pass_count = pass_count + 1;
            $display("TEST %0d: %-56s PASS  (expected 0x%08h, got 0x%08h)",
                       test_num, name, expected, actual);
        end else begin
            fail_count = fail_count + 1;
            $display("TEST %0d: %-56s FAIL  (expected 0x%08h, got 0x%08h)",
                       test_num, name, expected, actual);
        end
    end
endtask

task check_cond(input [8*60-1:0] name, input cond);
    begin
        test_num = test_num + 1;
        if (cond) begin
            pass_count = pass_count + 1;
            $display("TEST %0d: %-56s PASS", test_num, name);
        end else begin
            fail_count = fail_count + 1;
            $display("TEST %0d: %-56s FAIL", test_num, name);
        end
    end
endtask

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
