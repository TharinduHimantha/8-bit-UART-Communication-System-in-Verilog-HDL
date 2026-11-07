//==============================================================================
// Module : uart_rx
// Purpose: Deserializes a UART frame (start bit, 8 data bits LSB first, stop
//          bit) received on "rx" into an 8-bit parallel word.
//
// How sampling works (the most important part of any UART RX):
//   The receiver does NOT share a clock or a baud-tick with the transmitter.
//   All it has is the serial line and its own system clock. So it has to
//   re-derive bit timing purely from watching the line:
//
//     1. While idle, rx == 1. The instant a 0 is seen, that edge is treated
//        as the leading edge of a start bit, and a local cycle counter
//        starts from 0.
//     2. The counter counts up to HALF a bit period (CLKS_PER_BIT/2). This
//        lands roughly in the MIDDLE of the start bit, not at its edge.
//        Sampling at the center (rather than right at the edge) gives
//        maximum margin against line noise/jitter and against the input
//        synchronizer adding 1-2 cycles of latency to the edge itself.
//        If rx is still 0 at that midpoint, the start bit is confirmed
//        valid; if rx has already gone back to 1, it was just a glitch and
//        the module returns to idle (this is the rx_error condition for a
//        false start).
//     3. From that confirmed start-bit-center, the counter is reloaded and
//        counts a FULL bit period (CLKS_PER_BIT) to reach the center of
//        data bit 0, then a full bit period again for bit 1, and so on
//        through bit 7. Each data bit is captured exactly at its midpoint.
//     4. One more full bit period after bit 7's center lands at the middle
//        of the stop bit. If rx == 1 there, the frame is valid and rx_data /
//        rx_valid are produced. If rx == 0, the frame is malformed (framing
//        error) and rx_error is pulsed instead.
//
//   Because every sampling point is anchored to the START BIT's leading
//   edge (measured independently by this module) and re-centers itself
//   every bit via a half-then-full-period ladder, the receiver tracks the
//   transmitter's bit timing without ever needing to share a clock enable
//   or baud tick with it -- this is exactly how asynchronous UART works in
//   real hardware.
//
// Metastability:
//   rx is an external, asynchronous input. It is passed through a 2-flip-
//   flop synchronizer (rx_sync1/rx_sync2) before any logic looks at it, to
//   bring it safely into the clk domain.
//
// FSM:
//   S_IDLE  : watch rx_s for a falling edge (1 -> 0).
//   S_START : wait CLKS_PER_BIT/2 cycles, then check rx_s is still 0.
//   S_DATA  : wait CLKS_PER_BIT cycles per bit, sample rx_s into
//             rx_shift[bit_index], LSB first, for 8 bits.
//   S_STOP  : wait CLKS_PER_BIT cycles, sample rx_s; must be 1.
//
// Common mistakes this design avoids:
//   - Sampling right at the bit edge instead of the center: any small clock
//     or line skew then causes bits to be read one cycle early/late.
//   - Not synchronizing the asynchronous rx input: can cause metastability
//     that propagates into the FSM state itself, corrupting more than just
//     one bit.
//   - Not validating the stop bit: silently accepting a mis-framed byte as
//     if it were valid data.
//==============================================================================

module uart_rx #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       reset,     // synchronous, active-high
    input  wire       rx,        // asynchronous serial input

    output reg  [7:0] rx_data,   // holds the last successfully received byte
    output reg        rx_valid,  // 1-cycle pulse: rx_data is a new, valid byte
    output reg        rx_busy,   // 1 whenever a frame is being received
    output reg        rx_error   // 1-cycle pulse: framing error (bad stop bit
                                  // or false start)
);

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
    // FSM
    // -------------------------------------------------------------------
    localparam [1:0] S_IDLE  = 2'd0,
                      S_START = 2'd1,
                      S_DATA  = 2'd2,
                      S_STOP  = 2'd3;

    // Half and full bit-period counts. Integer division here rounds down;
    // for CLKS_PER_BIT values used in real designs (tens to thousands of
    // cycles) the +/-1 cycle this can introduce is negligible compared to
    // the bit period itself.
    localparam integer HALF_PERIOD = CLKS_PER_BIT / 2;
    localparam integer CW = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

    reg [1:0]      state;
    reg [CW-1:0]   cycle_count;
    reg [2:0]      bit_index;
    reg [7:0]      rx_shift;

    always @(posedge clk) begin
        if (reset) begin
            state       <= S_IDLE;
            cycle_count <= {CW{1'b0}};
            bit_index   <= 3'd0;
            rx_shift    <= 8'h00;
            rx_data     <= 8'h00;
            rx_valid    <= 1'b0;
            rx_busy     <= 1'b0;
            rx_error    <= 1'b0;
        end else begin
            // Default: both are 1-cycle pulses.
            rx_valid <= 1'b0;
            rx_error <= 1'b0;

            case (state)
                //--------------------------------------------------------
                S_IDLE: begin
                    rx_busy <= 1'b0;
                    if (rx_s == 1'b0) begin
                        // Candidate falling edge: start of a start bit.
                        rx_busy     <= 1'b1;
                        cycle_count <= {CW{1'b0}};
                        state       <= S_START;
                    end
                end

                //--------------------------------------------------------
                // Wait to the middle of the start bit, then validate it.
                S_START: begin
                    if (cycle_count == HALF_PERIOD - 1) begin
                        if (rx_s == 1'b0) begin
                            // Confirmed real start bit; begin data bits.
                            cycle_count <= {CW{1'b0}};
                            bit_index   <= 3'd0;
                            state       <= S_DATA;
                        end else begin
                            // It was a glitch, not a real start bit.
                            rx_error <= 1'b1;
                            rx_busy  <= 1'b0;
                            state    <= S_IDLE;
                        end
                    end else begin
                        cycle_count <= cycle_count + 1'b1;
                    end
                end

                //--------------------------------------------------------
                // Sample each data bit at its center, LSB first.
                S_DATA: begin
                    if (cycle_count == CLKS_PER_BIT - 1) begin
                        cycle_count       <= {CW{1'b0}};
                        rx_shift[bit_index] <= rx_s;
                        if (bit_index == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end else begin
                        cycle_count <= cycle_count + 1'b1;
                    end
                end

                //--------------------------------------------------------
                // Sample the stop bit at its center; must read back as 1.
                S_STOP: begin
                    if (cycle_count == CLKS_PER_BIT - 1) begin
                        rx_busy <= 1'b0;
                        state   <= S_IDLE;
                        if (rx_s == 1'b1) begin
                            rx_data  <= rx_shift;
                            rx_valid <= 1'b1;
                        end else begin
                            rx_error <= 1'b1; // framing error: bad stop bit
                        end
                    end else begin
                        cycle_count <= cycle_count + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
