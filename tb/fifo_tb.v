//==============================================================================
// File   : fifo_tb.v
// Purpose: Standalone, self-checking testbench for uart_fifo.v in
//          isolation (no UART logic at all -- this is a pure data-
//          structure test). Covers every case listed in the assignment's
//          FIFO requirements, plus a randomized-traffic test checked
//          against an independent software reference queue (a Verilog
//          dynamic array used purely as an oracle, not as part of the
//          design under test).
//==============================================================================

`timescale 1ns/1ps

module fifo_tb;

    localparam DW    = 8;
    localparam DEPTH = 4; // small depth: makes full/wraparound easy to hit fast

    reg  clk = 0;
    reg  reset = 1;
    reg  wr_en = 0, rd_en = 0;
    reg  [DW-1:0] wr_data = 0;
    wire full, empty;
    wire [DW-1:0] rd_data;
    wire [$clog2(DEPTH+1)-1:0] count;

    always #5 clk = ~clk;

    uart_fifo #(.DATA_WIDTH(DW), .DEPTH(DEPTH)) dut (
        .clk(clk), .reset(reset), .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .rd_en(rd_en), .rd_data(rd_data), .empty(empty), .count(count)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num   = 0;

    task chk(input [8*56-1:0] name, input cond);
        begin
            test_num = test_num + 1;
            if (cond) begin
                pass_count = pass_count + 1;
                $display("TEST %0d: %-52s PASS", test_num, name);
            end else begin
                fail_count = fail_count + 1;
                $display("TEST %0d: %-52s FAIL", test_num, name);
            end
        end
    endtask

    // One clean write, settled and checked at negedge (see
    // docs/verification.md "lessons learned" on NBA-settle timing).
    task do_write(input [DW-1:0] d);
        begin
            @(posedge clk); wr_en <= 1'b1; wr_data <= d;
            @(posedge clk); wr_en <= 1'b0;
            @(negedge clk);
        end
    endtask

    task do_read;
        begin
            @(posedge clk); rd_en <= 1'b1;
            @(posedge clk); rd_en <= 1'b0;
            @(negedge clk);
        end
    endtask

    // Optional VCD waveform dump, enabled with `make waves TB=fifo_tb`.
`ifdef WAVES
    initial begin
        $dumpfile("fifo_tb.vcd");
        $dumpvars(0, fifo_tb);
    end
`endif

    initial begin
        $display("----------------------------------------");
        $display("UART_FIFO STANDALONE TEST (DATA_WIDTH=%0d, DEPTH=%0d)", DW, DEPTH);
        $display("----------------------------------------");

        repeat (3) @(posedge clk);
        reset <= 1'b0; @(posedge clk);
        @(negedge clk);

        //---- Reset ----------------------------------------------------
        chk("Reset: empty",       empty === 1'b1);
        chk("Reset: not full",    full  === 1'b0);
        chk("Reset: count == 0",  count === 0);

        //---- First write / first read -----------------------------------
        do_write(8'h11);
        chk("First write: not empty",  empty === 1'b0);
        chk("First write: count == 1", count === 1);
        @(negedge clk);
        chk("First write: FWFT peek shows 0x11 before any read", rd_data === 8'h11);

        do_read;
        chk("First read: empty again", empty === 1'b1);
        chk("First read: count == 0",  count === 0);

        //---- FWFT peek semantics, explicitly ------------------------------
        do_write(8'h77);
        @(negedge clk);
        chk("FWFT: rd_data valid without rd_en", rd_data === 8'h77);
        do_read; // drain it back out before continuing
        chk("FWFT: drained back to empty", empty === 1'b1);

        //---- Fill to exactly DEPTH entries -----------------------------------
        do_write(8'h11); do_write(8'h22); do_write(8'h33); do_write(8'h44);
        chk("Filled to DEPTH: full",           full  === 1'b1);
        chk("Filled to DEPTH: count == DEPTH", count === DEPTH);
        chk("Filled to DEPTH: not empty",      empty === 1'b0);

        //---- DEPTH+1 write (write while full) -> ignored -----------------------
        do_write(8'hFF);
        chk("Write while full: count unchanged", count === DEPTH);
        chk("Write while full: still full",      full  === 1'b1);

        //---- Drain and verify FIFO order (0x11,0x22,0x33,0x44) -------------------
        @(negedge clk);
        chk("Drain order 1/4: rd_data == 0x11", rd_data === 8'h11);
        do_read;
        chk("Drain order 2/4: rd_data == 0x22", rd_data === 8'h22);
        do_read;
        chk("Drain order 3/4: rd_data == 0x33", rd_data === 8'h33);
        do_read;
        chk("Drain order 4/4: rd_data == 0x44", rd_data === 8'h44);
        do_read;
        chk("After full drain: empty",   empty === 1'b1);
        chk("After full drain: count==0", count === 0);

        //---- Empty read (rd_en && empty) -> ignored, rd_data reads 0 -------------
        chk("Empty read: rd_data == 0 (FWFT, no valid entry)", rd_data === 8'h00);
        do_read; // should be a no-op
        chk("Empty read: still empty after no-op read", empty === 1'b1);

        //---- Pointer wraparound: many fill/drain cycles past DEPTH*4 --------------
        begin : wrap_test
            integer i;
            reg [DW-1:0] peeked;
            for (i = 0; i < DEPTH * 6; i = i + 1) begin
                do_write(i[7:0]);
                peeked = rd_data; // FWFT peek BEFORE the pop -- see do_read below
                do_read;
                chk("Pointer wraparound: FIFO order preserved", peeked === i[7:0]);
            end
        end

        //---- Simultaneous read+write, neither full nor empty ----------------------
        do_write(8'hAA); // 1 entry
        do_write(8'hBB); // 2 entries
        @(posedge clk); wr_en <= 1'b1; wr_data <= 8'hCC; rd_en <= 1'b1; // simultaneous
        @(posedge clk); wr_en <= 1'b0; rd_en <= 1'b0;
        @(negedge clk);
        chk("Simultaneous r/w: count unchanged (still 2)", count === 2);
        chk("Simultaneous r/w: next is 0xBB (oldest untouched entry)", rd_data === 8'hBB);
        do_read;
        chk("Simultaneous r/w: next is 0xCC (the one written during overlap)", rd_data === 8'hCC);
        do_read;
        chk("Simultaneous r/w: now empty", empty === 1'b1);

        //---- Simultaneous read+write while FULL: nets to one fewer entry ----------
        do_write(8'h01); do_write(8'h02); do_write(8'h03); do_write(8'h04); // full
        @(posedge clk); wr_en <= 1'b1; wr_data <= 8'h05; rd_en <= 1'b1; // write ignored (full), read succeeds
        @(posedge clk); wr_en <= 1'b0; rd_en <= 1'b0;
        @(negedge clk);
        chk("Simultaneous r/w while full: write ignored, count==3", count === 3);
        chk("Simultaneous r/w while full: not full anymore", full === 1'b0);
        do_read; do_read; do_read; // drain the rest
        chk("Drained after full-simultaneous test: empty", empty === 1'b1);

        //---- Simultaneous read+write while EMPTY: nets to one more entry ----------
        @(posedge clk); wr_en <= 1'b1; wr_data <= 8'hE1; rd_en <= 1'b1; // read ignored (empty), write succeeds
        @(posedge clk); wr_en <= 1'b0; rd_en <= 1'b0;
        @(negedge clk);
        chk("Simultaneous r/w while empty: read ignored, count==1", count === 1);
        do_read;

        //---- Reset while active (partially full) -----------------------------------
        do_write(8'h01); do_write(8'h02);
        chk("Before mid-active reset: count == 2", count === 2);
        reset <= 1'b1; @(posedge clk); reset <= 1'b0; @(posedge clk);
        @(negedge clk);
        chk("Reset while active: empty",     empty === 1'b1);
        chk("Reset while active: count==0",  count === 0);
        chk("Reset while active: not full",  full  === 1'b0);

        //---- Randomized traffic vs. an independent software reference queue -------
        begin : random_traffic
            integer seed;
            integer i;
            reg [DW-1:0] sw_queue [0:255];
            integer sw_head, sw_tail, sw_count;
            reg do_w, do_r;
            reg [DW-1:0] wdata;

            seed = 42;
            sw_head = 0; sw_tail = 0; sw_count = 0;

            for (i = 0; i < 500; i = i + 1) begin
                do_w  = $random(seed) % 2;
                do_r  = $random(seed) % 2;
                wdata = $random(seed);

                @(posedge clk);
                wr_en   <= do_w;
                wr_data <= wdata;
                rd_en   <= do_r;
                @(posedge clk);
                wr_en <= 1'b0;
                rd_en <= 1'b0;
                @(negedge clk);

                // Reference model: mirrors the DUT's documented semantics
                // exactly (write ignored if full, read ignored if empty),
                // computed independently from the DUT's internal state.
                // Both decisions are made against the SAME starting count
                // (sw_count_start) -- matching the RTL, where full/empty
                // for this cycle's write/read decision are computed from
                // pointer values as they stood BEFORE either pointer's
                // nonblocking update applies this edge. Chaining the two
                // decisions sequentially (deciding the write using an
                // already-decremented count from this same cycle's read)
                // would let a write "sneak in" exactly when the FIFO
                // started this cycle completely full, or a read "sneak
                // in" when it started completely empty -- both already
                // disproven by name in the directed
                // "Simultaneous r/w while full/empty" tests above.
                begin : ref_update
                    integer sw_count_start;
                    sw_count_start = sw_count;
                    if (do_r && (sw_count_start > 0)) begin
                        sw_head  = (sw_head + 1) % 256;
                        sw_count = sw_count - 1;
                    end
                    if (do_w && (sw_count_start < DEPTH)) begin
                        sw_queue[sw_tail] = wdata;
                        sw_tail  = (sw_tail + 1) % 256;
                        sw_count = sw_count + 1;
                    end
                end

                chk("Random traffic: count matches reference model",
                     count === sw_count[$clog2(DEPTH+1)-1:0]);
                chk("Random traffic: empty matches reference model",
                     empty === (sw_count == 0));
                chk("Random traffic: full matches reference model",
                     full === (sw_count == DEPTH));
                if (sw_count > 0)
                    chk("Random traffic: rd_data matches reference model front",
                         rd_data === sw_queue[sw_head]);
            end
        end

        $display("----------------------------------------");
        $display("  %0d / %0d tests passed", pass_count, pass_count + fail_count);
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else $display("  *** %0d TEST(S) FAILED ***", fail_count);
        $display("----------------------------------------");
        $finish;
    end

    initial begin
        #500_000;
        $display("*** WATCHDOG TIMEOUT ***");
        $finish;
    end

endmodule
