//==============================================================================
// Module : uart_rx
// Purpose: Deserializes a UART frame (start bit, DATA_BITS data bits LSB
//          first, an optional parity bit, stop bit) received on "rx" into
//          an parallel word, with parity checking, framing-error detection,
//          and break-condition detection.
//
// PHASE 2 CHANGES FROM THE EARLIER VERSION:
//   - PARITY_MODE parameter (NONE/EVEN/ODD) and a new S_PARITY state.
//   - The old single "rx_error" pulse is replaced by two independently
//     meaningful signals, parity_error and framing_error (see Section
//     "Error semantics" below and docs/architecture.md for the full
//     behavioral table), plus a new break_detected LEVEL output.
//   - A free-running "how long has rx been continuously low" counter that
//     lets the FSM tell a genuine break condition apart from an ordinary
//     start bit, and abort mid-frame into a dedicated S_BREAK state
//     without falsely reporting a framing/parity error for that aborted
//     attempt.
//
// How sampling works (bit-center sampling, unchanged in principle from the
// earlier version -- see docs/architecture.md Section 5.3 for the full
// derivation):
//   1. IDLE: rx_s == 1. A 1->0 transition is treated as a candidate start
//      bit; a local cycle counter starts from 0.
//   2. START: at the HALF-bit point, rx_s is re-checked. Still 0 -> real
//      start bit. Back to 1 -> just a glitch; silently return to IDLE
//      (see "Glitch filtering" below -- this is deliberately NOT reported
//      as any of the three defined error types, since no byte attempt ever
//      began).
//   3. DATA: from the confirmed start-bit center, one FULL bit period per
//      data bit, LSB first, sampled at each bit's center.
//   4. PARITY (only if PARITY_MODE != NONE): one more full bit period,
//      sampled at its center, compared against the expected parity
//      computed from the DATA bits actually received.
//   5. STOP: one more full bit period, sampled at its center; must read
//      back 1.
//
// Parity checking, explained:
//   The expected parity bit is recomputed from the received data bits using
//   exactly the same EVEN/ODD formula as uart_tx (see uart_tx.v's header
//   comment for the derivation): expected = ^rx_shift for EVEN,
//   expected = ~(^rx_shift) for ODD. parity_error is asserted when the
//   actually-received parity bit does not match this expectation. This
//   reuses the *formula* (which is simply how parity is mathematically
//   defined) but is computed independently in RX from the bits RX itself
//   captured -- it does not read any TX-side signal or register.
//
// Framing-error semantics (see full behavioral table in
// docs/architecture.md):
//   The stop bit is sampled at its center. If it reads back 0 instead of 1,
//   framing_error is pulsed for one cycle. In that case rx_valid is NOT
//   asserted -- a mis-framed byte is never presented as if it were good
//   data. rx_data IS still updated with whatever data bits were captured,
//   for diagnostic visibility, but the side-band framing_error pulse is the
//   only thing that tells the caller not to trust it. The same rule
//   applies to parity_error. If both are true in the same frame, both
//   pulse together; they are independent checks, not mutually exclusive.
//
// Break detection, explained:
//   A break condition is defined here as: the (synchronized) rx line stays
//   continuously LOW for BREAK_THRESHOLD_BITS bit-periods or longer. By
//   default, BREAK_THRESHOLD_BITS = (1 start + DATA_BITS + parity-bits(0 or
//   1) + 1 stop) + 1 -- i.e. one full frame's worth of bit periods, plus
//   one extra bit period of margin. The margin exists so that a break is
//   only ever declared once the line has stayed low noticeably longer than
//   any legitimate frame (including one with a bad stop bit) could
//   possibly last; a single bad-stop-bit frame is a framing error, not a
//   break, and must not be misclassified as one.
//
//   A free-running counter (low_run_count) increments every cycle rx_s is
//   0 and resets to 0 the instant rx_s goes back to 1; it is NOT part of
//   the main frame FSM's state, precisely so it keeps counting even while
//   the frame FSM is mid-frame. Once it reaches the break threshold, the
//   frame FSM (if it is not already idle) is forced into a dedicated
//   S_BREAK state -- abandoning whatever partial frame it was in the
//   middle of, without emitting a framing_error or parity_error for that
//   aborted attempt, since a break is a distinct condition, not "a very
//   badly framed byte".
//
//   break_detected is a LEVEL output (not a pulse): it stays asserted for
//   as long as the line remains continuously low past the threshold, and
//   is deasserted the cycle rx_s returns to 1 (same cycle low_run_count
//   resets to 0). This lets software simply poll it, and lets the
//   testbench directly verify both "stays asserted throughout the break"
//   and "clears promptly when the line recovers" as separate checks.
//   S_BREAK itself just waits for rx_s to return high, then returns to
//   S_IDLE to resume normal frame detection.
//
// Metastability:
//   rx is an external, asynchronous input. It is passed through a 2-flip-
//   flop synchronizer (rx_sync1/rx_sync2) before any logic looks at it.
//   This does not eliminate the possibility of metastability -- it reduces
//   the probability that a metastable event on the first flop propagates
//   into the rest of the design to something acceptably small (a function
//   of clock frequency and the flops' characteristics), not to zero. See
//   docs/architecture.md for the fuller discussion of this tradeoff.
//==============================================================================

`include "uart_defs.vh"

module uart_rx #(
    parameter integer CLKS_PER_BIT         = 434,
    parameter integer DATA_BITS            = 8,
    parameter [1:0]   PARITY_MODE          = `UART_PARITY_NONE,
    // Default: one full frame's worth of bit periods, plus one bit of
    // margin. See header comment. Exposed as a parameter so a testbench
    // can pick a small, exact value to test "exactly at threshold" style
    // corner cases without waiting through a huge default.
    parameter integer BREAK_THRESHOLD_BITS =
        1 + DATA_BITS + ((PARITY_MODE == `UART_PARITY_NONE) ? 0 : 1) + 1 + 1
) (
    input  wire                  clk,
    input  wire                  reset,     // synchronous, active-high
    input  wire                  rx,        // asynchronous serial input

    output reg  [DATA_BITS-1:0]  rx_data,       // last received data bits
    output reg                   rx_valid,      // 1-cyc pulse: rx_data is a new, CLEAN byte
    output reg                   rx_busy,       // 1 whenever a frame (or break) is in progress
    output reg                   parity_error,  // 1-cyc pulse: received parity bit didn't match
    output reg                   framing_error, // 1-cyc pulse: stop bit was 0, not 1
    output wire                  break_detected // LEVEL: rx has been low for >= threshold
);

    localparam BIW = (DATA_BITS <= 1) ? 1 : $clog2(DATA_BITS); // bit_index width

    // -------------------------------------------------------------------
    // 2-flop synchronizer for the asynchronous rx input
    // -------------------------------------------------------------------
    reg rx_sync1, rx_sync2;
    always @(posedge clk) begin
        if (reset) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end
    wire rx_s = rx_sync2;

    // -------------------------------------------------------------------
    // Break detection: free-running, independent of the frame FSM state.
    // -------------------------------------------------------------------
    localparam integer BREAK_THRESHOLD_CYCLES = CLKS_PER_BIT * BREAK_THRESHOLD_BITS;
    localparam integer LRCW = $clog2(BREAK_THRESHOLD_CYCLES + 1);

    reg [LRCW-1:0] low_run_count;

    always @(posedge clk) begin
        if (reset) begin
            low_run_count <= {LRCW{1'b0}};
        end else if (rx_s == 1'b0) begin
            if (low_run_count < BREAK_THRESHOLD_CYCLES)
                low_run_count <= low_run_count + 1'b1;
            // else: saturate. Prevents wraparound if rx is held low far
            // longer than the threshold (e.g. a disconnected/idle-low
            // line), which would otherwise cause break_detected to
            // spuriously toggle off and on as the counter wrapped.
        end else begin
            low_run_count <= {LRCW{1'b0}};
        end
    end

    assign break_detected = (low_run_count == BREAK_THRESHOLD_CYCLES);

    // -------------------------------------------------------------------
    // Main frame FSM
    // -------------------------------------------------------------------
    localparam [2:0] S_IDLE   = 3'd0,
                      S_START  = 3'd1,
                      S_DATA   = 3'd2,
                      S_PARITY = 3'd3,
                      S_STOP   = 3'd4,
                      S_BREAK  = 3'd5;

    // Half and full bit-period counts. Integer division here rounds down;
    // for CLKS_PER_BIT values used in real designs (tens to thousands of
    // cycles) the +/-1 cycle this can introduce is negligible compared to
    // the bit period itself.
    localparam integer HALF_PERIOD = CLKS_PER_BIT / 2;
    localparam integer CW = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

    reg [2:0]           state;
    reg [CW-1:0]         cycle_count;
    reg [BIW-1:0]        bit_index;
    reg [DATA_BITS-1:0]  rx_shift;
    reg                  rx_parity_bit;

    // Expected parity, recomputed independently from the bits RX itself
    // captured (see header comment: same formula as TX, but never reads
    // any TX-side signal).
    wire expected_parity = (PARITY_MODE == `UART_PARITY_ODD) ? ~(^rx_shift)
                                                               :  (^rx_shift);

    always @(posedge clk) begin
        if (reset) begin
            state         <= S_IDLE;
            cycle_count   <= {CW{1'b0}};
            bit_index     <= {BIW{1'b0}};
            rx_shift      <= {DATA_BITS{1'b0}};
            rx_parity_bit <= 1'b0;
            rx_data       <= {DATA_BITS{1'b0}};
            rx_valid      <= 1'b0;
            rx_busy       <= 1'b0;
            parity_error  <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            // Defaults: all three are 1-cycle pulses.
            rx_valid      <= 1'b0;
            parity_error  <= 1'b0;
            framing_error <= 1'b0;

            if (break_detected && (state != S_IDLE) && (state != S_BREAK)) begin
                // Escalate: whatever frame was in progress is abandoned.
                // Deliberately do NOT set framing_error/parity_error here
                // -- see header comment on why a break is not "a very bad
                // framing error".
                state   <= S_BREAK;
                rx_busy <= 1'b1;
            end else begin
                case (state)
                    //----------------------------------------------------
                    S_IDLE: begin
                        rx_busy <= 1'b0;
                        if (rx_s == 1'b0) begin
                            // Candidate falling edge: start of a start bit.
                            rx_busy     <= 1'b1;
                            cycle_count <= {CW{1'b0}};
                            state       <= S_START;
                        end
                    end

                    //----------------------------------------------------
                    // Wait to the middle of the start bit, then validate.
                    S_START: begin
                        if (cycle_count == HALF_PERIOD - 1) begin
                            if (rx_s == 1'b0) begin
                                cycle_count <= {CW{1'b0}};
                                bit_index   <= {BIW{1'b0}};
                                state       <= S_DATA;
                            end else begin
                                // Glitch filtering: shorter than half a bit
                                // period is treated as noise, not a start
                                // bit. Deliberately silent -- no error
                                // output, no byte attempt ever began. See
                                // header comment "Glitch filtering".
                                rx_busy <= 1'b0;
                                state   <= S_IDLE;
                            end
                        end else begin
                            cycle_count <= cycle_count + 1'b1;
                        end
                    end

                    //----------------------------------------------------
                    // Sample each data bit at its center, LSB first.
                    S_DATA: begin
                        if (cycle_count == CLKS_PER_BIT - 1) begin
                            cycle_count          <= {CW{1'b0}};
                            rx_shift[bit_index]  <= rx_s;
                            if (bit_index == DATA_BITS - 1) begin
                                if (PARITY_MODE == `UART_PARITY_NONE)
                                    state <= S_STOP;
                                else
                                    state <= S_PARITY;
                            end else begin
                                bit_index <= bit_index + 1'b1;
                            end
                        end else begin
                            cycle_count <= cycle_count + 1'b1;
                        end
                    end

                    //----------------------------------------------------
                    // Sample the parity bit at its center (only reached if
                    // PARITY_MODE != NONE).
                    S_PARITY: begin
                        if (cycle_count == CLKS_PER_BIT - 1) begin
                            cycle_count   <= {CW{1'b0}};
                            rx_parity_bit <= rx_s;
                            state         <= S_STOP;
                        end else begin
                            cycle_count <= cycle_count + 1'b1;
                        end
                    end

                    //----------------------------------------------------
                    // Sample the stop bit at its center; must read back 1.
                    // rx_data is updated here regardless of error status
                    // (diagnostic visibility); rx_valid is asserted only
                    // for a fully clean frame. See header comment
                    // "Framing-error semantics".
                    S_STOP: begin
                        if (cycle_count == CLKS_PER_BIT - 1) begin
                            rx_busy <= 1'b0;
                            state   <= S_IDLE;
                            rx_data <= rx_shift;

                            if (rx_s == 1'b1) begin
                                // Stop bit OK.
                                if ((PARITY_MODE == `UART_PARITY_NONE) ||
                                    (rx_parity_bit == expected_parity)) begin
                                    rx_valid <= 1'b1;
                                end else begin
                                    parity_error <= 1'b1;
                                end
                            end else begin
                                // Bad stop bit: framing error. Still check
                                // parity independently and report both if
                                // both are wrong (see header comment).
                                framing_error <= 1'b1;
                                if ((PARITY_MODE != `UART_PARITY_NONE) &&
                                    (rx_parity_bit != expected_parity)) begin
                                    parity_error <= 1'b1;
                                end
                            end
                        end else begin
                            cycle_count <= cycle_count + 1'b1;
                        end
                    end

                    //----------------------------------------------------
                    // Wait for the line to return high, then resume normal
                    // start-bit detection.
                    S_BREAK: begin
                        rx_busy <= 1'b1;
                        if (rx_s == 1'b1) begin
                            rx_busy <= 1'b0;
                            state   <= S_IDLE;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
