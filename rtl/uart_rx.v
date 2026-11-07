//==============================================================================
// Module : uart_rx
// Purpose: Deserializes a UART frame (start bit, DATA_BITS data bits LSB
//          first, an optional parity bit, 1 or 2 stop bits) received on
//          "rx", with parity checking, framing-error detection, and
//          break-condition detection.
//
// PHASE 6-8 CHANGE FROM THE EARLIER (PARAMETER-ONLY) VERSION:
//   PARITY_MODE and stop-bit count are now runtime inputs (cfg_parity_mode,
//   cfg_stop_bits2) from the FRAME_CONFIG register, not parameters -- see
//   uart_tx.v's header comment for the same change and its rationale.
//
//   RX has no equivalent of TX's "tx_start" moment to latch config at, since
//   it discovers frames autonomously by watching the line. The latch point
//   used here is the end of S_START -- i.e. the instant a candidate start
//   bit is CONFIRMED real (not a glitch). From that point on, the frame
//   uses a stable, frame-locked copy of the config
//   (parity_mode_reg/stop_bits2_reg), so a FRAME_CONFIG write that lands
//   mid-frame cannot change the bit count or parity check of a frame
//   already being received; it only affects frames whose start bit is
//   confirmed after the write.
//
// BREAK_THRESHOLD_BITS default, revisited for runtime-configurable framing:
//   In the earlier, parameter-only version, "one full frame's worth of bit
//   periods" was a fixed, known quantity at elaboration time. Now that
//   parity and stop-bit count can change between frames, the receiver
//   cannot assume a fixed frame length. The default below instead sizes
//   the threshold for the WORST CASE (longest possible) frame this module
//   could ever be configured to receive: 1 start + DATA_BITS data + 1
//   parity bit (even if currently configured for NONE, a future frame
//   might not be) + 2 stop bits (even if currently configured for 1) + 1
//   bit of margin. This is deliberately conservative: it guarantees no
//   legitimately-configured frame, in any FRAME_CONFIG setting this module
//   supports, can ever be misclassified as a break, at the cost of
//   allowing a very slightly longer stuck-low condition before a break is
//   actually declared than a config-specific threshold would. That
//   trade-off is the right one: break detection existing at all matters
//   far more than shaving one or two bit periods off its worst-case
//   latency, and a config-specific threshold would also have to be
//   re-latched exactly like parity/stop-bits are, adding real complexity
//   for a marginal timing improvement.
//
// Everything else (half-bit start validation, per-bit center sampling,
// the free-running low_run_count break counter, the 2-flop input
// synchronizer) is unchanged from the earlier phase -- see
// docs/architecture.md for the full derivation.
//==============================================================================

`include "uart_defs.vh"

module uart_rx #(
    parameter integer CLKS_PER_BIT_MAX     = 4096, // sizes the bit-period counter; see baud_gen's DIV_WIDTH
    parameter integer DATA_BITS            = 8,
    parameter integer BREAK_THRESHOLD_BITS = 1 + DATA_BITS + 1 + 2 + 1 // worst case; see header
) (
    input  wire                  clk,
    input  wire                  reset,
    input  wire                  rx,
    input  wire [15:0]           cfg_clks_per_bit, // MUST be baud_gen's frame-stable
                                                       // active_divisor_out, not the raw
                                                       // BAUD_DIV register value -- see
                                                       // baud_gen.v's header comment.
    input  wire [1:0]            cfg_parity_mode,
    input  wire                  cfg_stop_bits2,

    output reg  [DATA_BITS-1:0]  rx_data,
    output reg                   rx_valid,
    output reg                   rx_busy,
    output reg                   parity_error,
    output reg                   framing_error,
    output wire                  break_detected
);

    localparam BIW = (DATA_BITS <= 1) ? 1 : $clog2(DATA_BITS); // bit_index width
    // verilator lint_off WIDTHTRUNC
    // DATA_BITS-1 is computed as a 32-bit expression but always fits in
    // BIW bits by construction (BIW = $clog2(DATA_BITS)); the truncation
    // is safe and intentional -- this localparam exists specifically to
    // make it explicit at the point of comparison (see below).
    localparam [BIW-1:0] LAST_BIT_INDEX = DATA_BITS - 1; // explicit width, avoids
                                                            // a 3-bit-vs-32-bit
                                                            // comparison warning
                                                            // against bit_index
    // verilator lint_on WIDTHTRUNC
    localparam CW  = $clog2(CLKS_PER_BIT_MAX);

    // -------------------------------------------------------------------
    // 2-flop synchronizer for the asynchronous rx input.
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
    localparam integer BREAK_THRESHOLD_CYCLES_MAX = CLKS_PER_BIT_MAX * BREAK_THRESHOLD_BITS;
    localparam integer LRCW = $clog2(BREAK_THRESHOLD_CYCLES_MAX + 1);

    // Explicit 32-bit intermediate for the multiply, then an explicit
    // truncation to LRCW bits -- LRCW was sized (see above) to comfortably
    // hold the actual maximum product (CLKS_PER_BIT_MAX * BREAK_THRESHOLD_BITS),
    // so this truncation never actually discards a set bit; it is written
    // this way so that fact is visible at the point of truncation instead
    // of relying on an implicit narrowing assignment (which Verilator
    // correctly flags as worth double-checking).
    // verilator lint_off UNUSEDSIGNAL
    // The upper bits of this 32-bit intermediate are unused by
    // construction: LRCW was sized to hold the actual maximum product
    // (see its definition above), so only the low LRCW bits are ever
    // meaningful. Kept as an explicit 32-bit intermediate anyway (rather
    // than narrowing the multiply itself) so the truncation below is
    // visible and auditable at its point of use.
    wire [31:0]      break_threshold_product = cfg_clks_per_bit * BREAK_THRESHOLD_BITS;
    // verilator lint_on UNUSEDSIGNAL
    wire [LRCW-1:0]  break_threshold_cycles  = break_threshold_product[LRCW-1:0];
    reg  [LRCW-1:0] low_run_count;

    always @(posedge clk) begin
        if (reset) begin
            low_run_count <= {LRCW{1'b0}};
        end else if (rx_s == 1'b0) begin
            if (low_run_count < break_threshold_cycles)
                low_run_count <= low_run_count + 1'b1;
        end else begin
            low_run_count <= {LRCW{1'b0}};
        end
    end

    assign break_detected = (low_run_count == break_threshold_cycles);

    // -------------------------------------------------------------------
    // Main frame FSM
    // -------------------------------------------------------------------
    localparam [2:0] S_IDLE   = 3'd0,
                      S_START  = 3'd1,
                      S_DATA   = 3'd2,
                      S_PARITY = 3'd3,
                      S_STOP1  = 3'd4,
                      S_STOP2  = 3'd5,
                      S_BREAK  = 3'd6;

    reg [2:0]           state;
    reg [CW-1:0]         cycle_count;
    reg [BIW-1:0]        bit_index;
    reg [DATA_BITS-1:0]  rx_shift;
    reg                  rx_parity_bit;
    reg [1:0]            parity_mode_reg;
    reg                  stop_bits2_reg;
    reg                  stop1_ok; // validity of the first stop bit, held
                                     // across S_STOP1 -> S_STOP2 when a
                                     // second stop bit is configured

    wire [CW-1:0] half_period = cfg_clks_per_bit[CW-1:0] >> 1;
    wire [CW-1:0] full_period_m1 = cfg_clks_per_bit[CW-1:0] - 1'b1;

    wire expected_parity = (parity_mode_reg == `UART_PARITY_ODD) ? ~(^rx_shift)
                                                                    :  (^rx_shift);

    always @(posedge clk) begin
        if (reset) begin
            state           <= S_IDLE;
            cycle_count     <= {CW{1'b0}};
            bit_index       <= {BIW{1'b0}};
            rx_shift        <= {DATA_BITS{1'b0}};
            rx_parity_bit   <= 1'b0;
            parity_mode_reg <= `UART_PARITY_NONE;
            stop_bits2_reg  <= 1'b0;
            rx_data         <= {DATA_BITS{1'b0}};
            rx_valid        <= 1'b0;
            rx_busy         <= 1'b0;
            parity_error    <= 1'b0;
            framing_error   <= 1'b0;
        end else begin
            rx_valid      <= 1'b0;
            parity_error  <= 1'b0;
            framing_error <= 1'b0;

            if (break_detected && (state != S_IDLE) && (state != S_BREAK)) begin
                state   <= S_BREAK;
                rx_busy <= 1'b1;
            end else begin
                case (state)
                    //----------------------------------------------------
                    S_IDLE: begin
                        rx_busy <= 1'b0;
                        if (rx_s == 1'b0) begin
                            rx_busy     <= 1'b1;
                            cycle_count <= {CW{1'b0}};
                            state       <= S_START;
                        end
                    end

                    //----------------------------------------------------
                    S_START: begin
                        if (cycle_count == half_period - 1'b1) begin
                            if (rx_s == 1'b0) begin
                                // Confirmed real start bit: latch config for
                                // the rest of this frame (see header comment).
                                cycle_count     <= {CW{1'b0}};
                                bit_index       <= {BIW{1'b0}};
                                parity_mode_reg <= cfg_parity_mode;
                                stop_bits2_reg  <= cfg_stop_bits2;
                                state           <= S_DATA;
                            end else begin
                                rx_busy <= 1'b0; // glitch: see docs/architecture.md
                                state   <= S_IDLE;
                            end
                        end else begin
                            cycle_count <= cycle_count + 1'b1;
                        end
                    end

                    //----------------------------------------------------
                    S_DATA: begin
                        if (cycle_count == full_period_m1) begin
                            cycle_count          <= {CW{1'b0}};
                            rx_shift[bit_index]  <= rx_s;
                            if (bit_index == LAST_BIT_INDEX) begin
                                if (parity_mode_reg == `UART_PARITY_NONE)
                                    state <= S_STOP1;
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
                    S_PARITY: begin
                        if (cycle_count == full_period_m1) begin
                            cycle_count   <= {CW{1'b0}};
                            rx_parity_bit <= rx_s;
                            state         <= S_STOP1;
                        end else begin
                            cycle_count <= cycle_count + 1'b1;
                        end
                    end

                    //----------------------------------------------------
                    // First (or only) stop bit. If a second stop bit is
                    // configured, its validity is ANDed in once sampled
                    // (see S_STOP2); if only one stop bit is configured,
                    // the outcome is decided here.
                    S_STOP1: begin
                        if (cycle_count == full_period_m1) begin
                            rx_data <= rx_shift;
                            if (stop_bits2_reg) begin
                                cycle_count <= {CW{1'b0}};
                                state       <= S_STOP2;
                                // Stash this stop bit's validity in
                                // rx_parity_bit's sibling via framing_error
                                // pre-check deferred to S_STOP2 -- see there.
                                stop1_ok <= (rx_s == 1'b1);
                            end else begin
                                rx_busy <= 1'b0;
                                state   <= S_IDLE;
                                if (rx_s == 1'b1) begin
                                    if ((parity_mode_reg == `UART_PARITY_NONE) ||
                                        (rx_parity_bit == expected_parity))
                                        rx_valid <= 1'b1;
                                    else
                                        parity_error <= 1'b1;
                                end else begin
                                    framing_error <= 1'b1;
                                    if ((parity_mode_reg != `UART_PARITY_NONE) &&
                                        (rx_parity_bit != expected_parity))
                                        parity_error <= 1'b1;
                                end
                            end
                        end else begin
                            cycle_count <= cycle_count + 1'b1;
                        end
                    end

                    //----------------------------------------------------
                    // Second stop bit (only reached if stop_bits2_reg==1).
                    // Both stop bits must read 1 for a clean frame; a bad
                    // first OR second stop bit is a framing error.
                    S_STOP2: begin
                        if (cycle_count == full_period_m1) begin
                            rx_busy <= 1'b0;
                            state   <= S_IDLE;
                            if (stop1_ok && (rx_s == 1'b1)) begin
                                if ((parity_mode_reg == `UART_PARITY_NONE) ||
                                    (rx_parity_bit == expected_parity))
                                    rx_valid <= 1'b1;
                                else
                                    parity_error <= 1'b1;
                            end else begin
                                framing_error <= 1'b1;
                                if ((parity_mode_reg != `UART_PARITY_NONE) &&
                                    (rx_parity_bit != expected_parity))
                                    parity_error <= 1'b1;
                            end
                        end else begin
                            cycle_count <= cycle_count + 1'b1;
                        end
                    end

                    //----------------------------------------------------
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
