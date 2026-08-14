//==============================================================================
// File   : uart_rx_tb.v
// Purpose: Unit-level testbench for uart_rx ONLY (no uart_tx). Frames are
//          driven directly onto the "rx" pin by a bit-banging task in this
//          testbench, independent of uart_tx entirely. This lets the RX
//          be validated against hand-built frames, including deliberately
//          malformed ones (bad stop bit, glitchy start bit) that a working
//          TX would never produce, in order to exercise rx_error.
//==============================================================================

`timescale 1ns/1ps

module uart_rx_tb;

    localparam CLKS_PER_BIT  = 10;
    localparam CLK_PERIOD_NS = 10;

    reg clk = 0;
    reg reset = 1;
    reg rx_line = 1'b1;   // idle = 1

    wire [7:0] rx_data;
    wire       rx_valid, rx_busy, rx_error;

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk), .reset(reset), .rx(rx_line),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .rx_busy(rx_busy), .rx_error(rx_error)
    );

    // uart_tasks.v expects tx_data/tx_start/tx_busy/tx_done/tx_line to
    // exist even though this testbench doesn't exercise TX; provide
    // harmless stand-ins so the shared include compiles.
    reg  [7:0] tx_data  = 8'h00;
    reg        tx_start = 1'b0;
    reg        tx_busy  = 1'b0;
    reg        tx_done  = 1'b0;
    wire       tx_line  = rx_line;

    `include "uart_tasks.v"

    //--------------------------------------------------------------------
    // drive_frame: bit-bangs one well-formed UART frame directly onto
    // rx_line: start bit (0), 8 data bits LSB first, stop bit (1). Each
    // bit is held for exactly CLKS_PER_BIT clocks, driven from the
    // negedge so it is stable well before uart_rx's midpoint sample.
    //--------------------------------------------------------------------
    task drive_frame(input [7:0] data);
        integer b;
        begin
            @(negedge clk);
            rx_line = 1'b0;                     // start bit
            repeat (CLKS_PER_BIT - 1) @(negedge clk);
            for (b = 0; b < 8; b = b + 1) begin
                @(negedge clk);
                rx_line = data[b];               // LSB first
                repeat (CLKS_PER_BIT - 1) @(negedge clk);
            end
            @(negedge clk);
            rx_line = 1'b1;                     // stop bit
            repeat (CLKS_PER_BIT - 1) @(negedge clk);
            @(negedge clk);
        end
    endtask

    //--------------------------------------------------------------------
    // drive_bad_stop_frame: same as drive_frame, but drives 0 instead of
    // 1 for the stop bit -> should be flagged as a framing error.
    //--------------------------------------------------------------------
    task drive_bad_stop_frame(input [7:0] data);
        integer b;
        begin
            @(negedge clk);
            rx_line = 1'b0;
            repeat (CLKS_PER_BIT - 1) @(negedge clk);
            for (b = 0; b < 8; b = b + 1) begin
                @(negedge clk);
                rx_line = data[b];
                repeat (CLKS_PER_BIT - 1) @(negedge clk);
            end
            @(negedge clk);
            rx_line = 1'b0;                     // bad stop bit
            repeat (CLKS_PER_BIT - 1) @(negedge clk);
            @(negedge clk);
            rx_line = 1'b1;                     // release line back to idle
        end
    endtask

    //--------------------------------------------------------------------
    // drive_glitch: a start-bit-looking pulse shorter than half a bit
    // period, which should be rejected as noise, not accepted as a frame.
    //--------------------------------------------------------------------
    task drive_glitch;
        begin
            @(negedge clk);
            rx_line = 1'b0;
            repeat (CLKS_PER_BIT/2 - 2) @(negedge clk); // well under half-bit
            @(negedge clk);
            rx_line = 1'b1;
        end
    endtask

    task wait_for_rx_valid_or_error(output got_valid, output got_error);
        integer timeout;
        begin
            timeout = 0;
            got_valid = 1'b0;
            got_error = 1'b0;
            while (!got_valid && !got_error && (timeout < 100000)) begin
                @(negedge clk);
                if (rx_valid) got_valid = 1'b1;
                if (rx_error) got_error = 1'b1;
                timeout = timeout + 1;
            end
        end
    endtask

    integer i;
    reg [7:0] bytes [0:4];
    reg got_valid, got_error;

    initial begin
        $display("----------------------------------------");
        $display("UART RX UNIT TEST");
        $display("----------------------------------------");

        repeat (3) @(posedge clk);
        @(negedge clk);
        check_cond("Reset: rx_busy low",  rx_busy  === 1'b0);
        check_cond("Reset: rx_valid low", rx_valid === 1'b0);
        check_cond("Reset: rx_error low", rx_error === 1'b0);
        reset = 0;
        @(posedge clk);

        // ---- Well-formed frames, several byte patterns -------------------
        bytes[0] = 8'h00;
        bytes[1] = 8'hFF;
        bytes[2] = 8'h55;
        bytes[3] = 8'hAA;
        bytes[4] = 8'h7E;

        for (i = 0; i < 5; i = i + 1) begin
            fork
                drive_frame(bytes[i]);
                wait_for_rx_valid_or_error(got_valid, got_error);
            join
            check_cond("Well-formed frame -> rx_valid (not rx_error)",
                        got_valid && !got_error);
            check_byte("RX received byte matches driven byte", bytes[i], rx_data);
            @(negedge clk);
            check_cond("rx_valid is a single-cycle pulse", rx_valid === 1'b0);
        end

        // ---- Back-to-back frames with no idle gap between them -----------
        fork
            begin
                drive_frame(8'hDE);
                drive_frame(8'hAD);
            end
            begin : back_to_back
                integer n;
                reg [7:0] seen [0:1];
                n = 0;
                while (n < 2) begin
                    @(negedge clk);
                    if (rx_valid) begin
                        seen[n] = rx_data;
                        n = n + 1;
                    end
                end
                check_byte("Back-to-back frame 1", 8'hDE, seen[0]);
                check_byte("Back-to-back frame 2", 8'hAD, seen[1]);
            end
        join

        // ---- Malformed stop bit -> rx_error, no rx_valid -----------------
        fork
            drive_bad_stop_frame(8'h3C);
            wait_for_rx_valid_or_error(got_valid, got_error);
        join
        check_cond("Bad stop bit -> rx_error asserted", got_error);
        check_cond("Bad stop bit -> rx_valid NOT asserted", !got_valid);

        // ---- Line glitch shorter than half a bit -> rejected, no frame ---
        got_valid = 1'b0;
        got_error = 1'b0;
        fork
            drive_glitch;
            begin : glitch_watch
                integer t;
                for (t = 0; t < CLKS_PER_BIT * 3; t = t + 1) begin
                    @(negedge clk);
                    if (rx_valid) got_valid = 1'b1;
                    if (rx_error) got_error = 1'b1;
                end
            end
        join
        check_cond("Glitch rejected: no valid byte produced", !got_valid);

        print_summary;
        $finish;
    end

    initial begin
        #500_000;
        $display("*** WATCHDOG TIMEOUT ***");
        $finish;
    end

endmodule
