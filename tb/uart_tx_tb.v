//==============================================================================
// File   : uart_tx_tb.v
// Purpose: Unit-level testbench for uart_tx + baud_gen ONLY (no uart_rx).
//
// This isolates the transmitter so its behavior can be verified directly
// against the serial line, independent of anything the receiver does. It
// checks:
//   - tx idle level and tx_busy/tx_done reset values
//   - tx_busy asserted for the whole frame, deasserted right after
//   - tx_done is a clean one-cycle completion pulse
//   - the actual line sequence (start/data-LSB-first/stop) for several
//     byte patterns, by directly sampling the tx pin
//==============================================================================

`timescale 1ns/1ps

module uart_tx_tb;

    localparam CLKS_PER_BIT   = 10;
    localparam TOTAL_BITS     = 10;
    localparam TOTAL_SAMPLES  = CLKS_PER_BIT * TOTAL_BITS;
    localparam CLK_PERIOD_NS  = 10;

    reg        clk = 0;
    reg        reset = 1;
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx, tx_busy, tx_done;
    wire       baud_tick, baud_restart;

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    baud_gen #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_baud (
        .clk(clk), .reset(reset), .restart(baud_restart), .tick(baud_tick)
    );

    uart_tx dut (
        .clk(clk), .reset(reset),
        .tx_start(tx_start), .tx_data(tx_data),
        .baud_tick(baud_tick), .baud_restart(baud_restart),
        .tx(tx), .tx_busy(tx_busy), .tx_done(tx_done)
    );

    // uart_tasks.v refers to tx_line for protocol-level checks; alias it.
    wire tx_line = tx;
    // uart_tasks.v also expects rx_data/rx_valid/rx_busy/rx_error to exist
    // (send_byte/wait_for_tx_done don't need them, but the file declares
    // wait_for_rx_valid/wait_for_tx_and_rx referencing them, so provide
    // harmless stand-ins for this TX-only testbench).
    reg [7:0] rx_data = 8'h00;
    reg       rx_valid = 1'b0;
    reg       rx_busy = 1'b0;
    reg       rx_error = 1'b0;

    `include "uart_tasks.v"

    reg cap [0:255];
    integer ci;

    task capture_and_check_frame(input [7:0] data_byte);
        integer seg, samp, base;
        reg seg_ok, seg_val;
        begin
            wait (tx_line == 1'b0);
            @(negedge clk);
            for (ci = 0; ci < TOTAL_SAMPLES; ci = ci + 1) begin
                cap[ci] = tx_line;
                @(negedge clk);
            end
            for (seg = 0; seg < TOTAL_BITS; seg = seg + 1) begin
                base    = seg * CLKS_PER_BIT;
                seg_val = cap[base];
                seg_ok  = 1'b1;
                for (samp = 0; samp < CLKS_PER_BIT; samp = samp + 1)
                    if (cap[base + samp] !== seg_val) seg_ok = 1'b0;

                if (seg == 0)
                    check_cond("TX: start bit correct", seg_ok && (seg_val === 1'b0));
                else if (seg <= 8)
                    check_cond("TX: data bit correct (LSB first)",
                                seg_ok && (seg_val === data_byte[seg-1]));
                else
                    check_cond("TX: stop bit correct", seg_ok && (seg_val === 1'b1));
            end
        end
    endtask

    integer i;
    reg [7:0] bytes [0:4];

    initial begin
        tx_start = 0; tx_data = 0;
        $display("----------------------------------------");
        $display("UART TX UNIT TEST");
        $display("----------------------------------------");

        repeat (3) @(posedge clk);
        @(negedge clk);
        check_cond("Reset: tx idle high", tx === 1'b1);
        check_cond("Reset: tx_busy low",  tx_busy === 1'b0);
        check_cond("Reset: tx_done low",  tx_done === 1'b0);
        reset = 0;
        @(posedge clk);

        repeat (5) @(posedge clk);
        check_cond("Idle: tx stays high with no tx_start", tx === 1'b1);

        bytes[0] = 8'h00;
        bytes[1] = 8'hFF;
        bytes[2] = 8'h55;
        bytes[3] = 8'hAA;
        bytes[4] = 8'hC3;

        for (i = 0; i < 5; i = i + 1) begin
            check_cond("tx_busy low before send", tx_busy === 1'b0);
            fork
                capture_and_check_frame(bytes[i]);
                send_byte(bytes[i]);
            join
            wait_for_tx_done;
            check_cond("tx_busy low right after tx_done", tx_busy === 1'b0);
            @(negedge clk);
            check_cond("tx_done is a single-cycle pulse", tx_done === 1'b0);
        end

        print_summary;
        $finish;
    end

    initial begin
        #500_000;
        $display("*** WATCHDOG TIMEOUT ***");
        $finish;
    end

endmodule
