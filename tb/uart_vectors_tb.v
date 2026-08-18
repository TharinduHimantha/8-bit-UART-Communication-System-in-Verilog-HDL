//==============================================================================
// File   : uart_vectors_tb.v
// Purpose: Reads randomized test vectors produced by the independent
//          Python reference model (scripts/gen_vectors.py -> tb/vectors/
//          random_vectors.txt) and drives each one directly onto the
//          appropriate parity-mode uart_rx instance, checking that the
//          DUT's outcome (clean rx_valid / parity_error / framing_error /
//          both) matches what the Python model independently predicted.
//
// This is deliberately a SEPARATE testbench from uart_rx_tb.v (which has
// its own hand-written, directed fault-injection tests) so that this
// file's only job is "drive whatever the external vector file says, check
// the DUT agrees with the external model's prediction" -- a clean,
// reusable regression path that can be re-run against many different
// randomized vector files (different seeds, more vectors) without editing
// any Verilog.
//==============================================================================

`timescale 1ns/1ps
`include "uart_defs.vh"

module uart_vectors_tb;

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

    // uart_tasks.v naming contract
    wire [7:0] rx_data       = rx_data_even;
    wire       rx_valid      = rx_valid_even;
    wire       rx_busy       = rx_busy_even;
    wire       parity_error  = parity_error_even;
    wire       framing_error = framing_error_even;
    reg  [7:0] tx_data = 8'h00;
    reg        tx_start = 1'b0, tx_busy = 1'b0, tx_done = 1'b0;
    wire       tx_line = rx_line_even;

    `include "uart_tasks.v"

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

    task drive_vector_even(input [7:0] data, input bad_parity, input bad_stop);
        integer i;
        reg p;
        begin
            wait (rx_busy_even == 1'b0);
            p = model_parity_bit(data, `UART_PARITY_EVEN);
            if (bad_parity) p = ~p;
            drive_bit_even(1'b0);
            for (i = 0; i < 8; i = i + 1) drive_bit_even(data[i]);
            drive_bit_even(p);
            drive_bit_even(bad_stop ? 1'b0 : 1'b1);
            rx_line_even = 1'b1;
        end
    endtask

    task drive_vector_odd(input [7:0] data, input bad_parity, input bad_stop);
        integer i;
        reg p;
        begin
            wait (rx_busy_odd == 1'b0);
            p = model_parity_bit(data, `UART_PARITY_ODD);
            if (bad_parity) p = ~p;
            drive_bit_odd(1'b0);
            for (i = 0; i < 8; i = i + 1) drive_bit_odd(data[i]);
            drive_bit_odd(p);
            drive_bit_odd(bad_stop ? 1'b0 : 1'b1);
            rx_line_odd = 1'b1;
        end
    endtask

    task wait_outcome_even(output gv, output gp, output gf);
        integer timeout;
        begin
            timeout = 0; gv = 0; gp = 0; gf = 0;
            while (!gv && !gp && !gf && (timeout < 200000)) begin
                @(negedge clk);
                if (rx_valid_even)      gv = 1'b1;
                if (parity_error_even)  gp = 1'b1;
                if (framing_error_even) gf = 1'b1;
                timeout = timeout + 1;
            end
        end
    endtask
    task wait_outcome_odd(output gv, output gp, output gf);
        integer timeout;
        begin
            timeout = 0; gv = 0; gp = 0; gf = 0;
            while (!gv && !gp && !gf && (timeout < 200000)) begin
                @(negedge clk);
                if (rx_valid_odd)      gv = 1'b1;
                if (parity_error_odd)  gp = 1'b1;
                if (framing_error_odd) gf = 1'b1;
                timeout = timeout + 1;
            end
        end
    endtask

    //--------------------------------------------------------------------
    // Vector file reading
    //--------------------------------------------------------------------
    integer fd, r;
    reg [8*256-1:0] line;
    reg [8*16-1:0]  outcome_str;
    integer data_val, mode_val, bad_p_val, bad_s_val;
    reg gv, gp, gf;
    integer vec_count;

    // Optional VCD waveform dump, enabled with `make waves TB=uart_vectors_tb`.
    // Off by default so ordinary regression runs don't pay the (small but
    // nonzero) cost of dumping every signal on every run.
`ifdef WAVES
    initial begin
        $dumpfile("uart_vectors_tb.vcd");
        $dumpvars(0, uart_vectors_tb);
    end
`endif

    initial begin
        tx_data = 0; tx_start = 0;
        $display("----------------------------------------");
        $display("UART RX RANDOMIZED VECTOR REGRESSION (Python reference model)");
        $display("----------------------------------------");

        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        fd = $fopen("tb/vectors/random_vectors.txt", "r");
        if (fd == 0) begin
            $display("*** ERROR: could not open tb/vectors/random_vectors.txt");
            $display("    Run `make vectors` (or: python3 scripts/gen_vectors.py > tb/vectors/random_vectors.txt)");
            $display("    from the project root before running this testbench.");
            $finish;
        end

        vec_count = 0;
        while (!$feof(fd)) begin
            r = $fgets(line, fd);
            if (r > 0) begin
                // Skip comment / blank lines (first non-space char '#').
                if (line[8*256-1 -: 8] != "#" && line[8*256-8 -: 8] != "#") begin
                    // $sscanf tolerates leading '#'-free, whitespace
                    // separated lines directly; comment lines simply won't
                    // parse as 4 fields + string and are skipped below.
                end
                r = $sscanf(line, "%h %d %d %d %s", data_val, mode_val, bad_p_val, bad_s_val, outcome_str);
                if (r == 5) begin
                    vec_count = vec_count + 1;
                    if (mode_val == `UART_PARITY_EVEN) begin
                        fork
                            drive_vector_even(data_val[7:0], bad_p_val[0], bad_s_val[0]);
                            wait_outcome_even(gv, gp, gf);
                        join
                    end else begin
                        fork
                            drive_vector_odd(data_val[7:0], bad_p_val[0], bad_s_val[0]);
                            wait_outcome_odd(gv, gp, gf);
                        join
                    end

                    if (outcome_str == "VALID")
                        check_cond("Vector: expected VALID", gv && !gp && !gf);
                    else if (outcome_str == "PARITY_ERROR")
                        check_cond("Vector: expected PARITY_ERROR", gp && !gv && !gf);
                    else if (outcome_str == "FRAMING_ERROR")
                        check_cond("Vector: expected FRAMING_ERROR", gf && !gv && !gp);
                    else if (outcome_str == "BOTH_ERRORS")
                        check_cond("Vector: expected BOTH_ERRORS", gp && gf && !gv);
                    else begin
                        $display("  *** unrecognized expected outcome '%0s' in vector file ***", outcome_str);
                        fail_count = fail_count + 1;
                    end
                end
            end
        end
        $fclose(fd);

        $display("----------------------------------------");
        $display("  %0d vectors replayed from tb/vectors/random_vectors.txt", vec_count);
        print_summary;
        $finish;
    end

    initial begin
        #20_000_000;
        $display("*** WATCHDOG TIMEOUT ***");
        $finish;
    end

endmodule
