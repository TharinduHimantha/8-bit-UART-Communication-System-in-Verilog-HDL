//==============================================================================
// Module : baud_gen
// Purpose: Generates a single-cycle "tick" pulse once every CLKS_PER_BIT
//          system clock cycles. This tick represents the passing of one
//          UART bit period and is used by uart_tx to know when to advance
//          to the next bit.
//
// Why a "restart" input?
//   A UART frame must have every bit (start, 8 data, stop) last EXACTLY
//   CLKS_PER_BIT clock cycles. If this counter were purely free-running
//   from power-up, the very first bit of a frame (the start bit) could be
//   shortened, because tx_start can arrive at any arbitrary point in the
//   free-running counter's cycle -- the counter has no idea a new frame is
//   beginning.
//
//   To fix this, uart_tx pulses "restart" for one clock cycle at the exact
//   moment it begins driving the start bit. That resets this counter to a
//   known phase, so the very first "tick" (end of the start bit) is exactly
//   CLKS_PER_BIT cycles later, same as every bit after it.
//
//   Between restarts, the counter free-runs, so consecutive bits within one
//   frame are automatically spaced CLKS_PER_BIT cycles apart with no drift.
//==============================================================================

module baud_gen #(
    parameter integer CLKS_PER_BIT = 434   // system clocks per UART bit period
) (
    input  wire clk,
    input  wire reset,     // synchronous, active-high
    input  wire restart,   // pulse: realign the counter to a new bit boundary
    output wire tick        // one clock-wide pulse, once per bit period
);

    // Width just large enough to count up to CLKS_PER_BIT-1.
    localparam integer CW = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

    reg [CW-1:0] count;

    // NOTE: tick is combinational (count == max), not a registered pulse.
    // This keeps the counter/tick pair a true zero-extra-latency divider:
    // the cycle on which "count" reaches its terminal value is the same
    // cycle "tick" is observed high, and also the same cycle "count" rolls
    // back to zero on the next edge. This is what allows a fully accurate
    // CLKS_PER_BIT-cycle bit period, including the very first bit right
    // after "restart".
    assign tick = (count == CLKS_PER_BIT - 1);

    always @(posedge clk) begin
        if (reset) begin
            count <= {CW{1'b0}};
        end else if (restart) begin
            // Realign: "count" starts a fresh CLKS_PER_BIT-cycle sweep
            // starting next cycle, so the following "tick" is exactly
            // CLKS_PER_BIT cycles after the state that requested restart.
            count <= {CW{1'b0}};
        end else if (tick) begin
            count <= {CW{1'b0}};
        end else begin
            count <= count + 1'b1;
        end
    end

endmodule
