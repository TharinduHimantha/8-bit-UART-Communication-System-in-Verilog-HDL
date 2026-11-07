//==============================================================================
// Module : uart_tx
// Purpose: Serializes one byte onto a UART TX line: start bit, 8 data bits
//          (LSB first), stop bit. Idle line level is 1.
//
// FSM (4 states):
//   S_IDLE  : tx = 1. Waiting for tx_start. Latches tx_data and, on the
//             SAME cycle it sees tx_start, starts driving the start bit and
//             pulses "baud_restart" so the external baud_gen begins timing
//             this frame from a known phase.
//   S_START : tx = 0 (start bit). Waits for one full bit period (baud_tick).
//   S_DATA  : tx = shift_reg[bit_index]. Advances bit_index each bit period
//             until all 8 bits (indices 0..7, LSB first) have been sent.
//   S_STOP  : tx = 1 (stop bit). After one bit period, returns to S_IDLE and
//             pulses tx_done for one clock cycle.
//
// Timing:
//   Every state transition (S_START -> S_DATA -> ... -> S_STOP -> S_IDLE)
//   happens on a baud_tick, and baud_tick fires once every CLKS_PER_BIT
//   system-clock cycles (see baud_gen.v). baud_restart is pulsed exactly
//   once, on the IDLE->START transition, so the counter that produces
//   baud_tick is phase-aligned to the start of this frame. The result is
//   that every one of the 10 bits (start + 8 data + stop) lasts exactly
//   CLKS_PER_BIT clock cycles -- there is no "short first bit" problem.
//
// Common mistakes this design avoids:
//   - Using an un-synchronized free-running baud tick: the start bit could
//     be shortened depending on when tx_start happens to arrive, which then
//     desynchronizes the receiver's bit-center sampling for the rest of the
//     frame. Fixed here with baud_restart.
//   - Changing tx_data while tx_busy is high: tx_data is only latched in
//     S_IDLE, so it is safe (though not meaningful) for the caller to change
//     tx_data while busy; the module simply won't look at it again until the
//     next transmission.
//   - Forgetting to gate tx_start with tx_busy: this module ignores tx_start
//     while busy (S_IDLE is the only state that reacts to it), so back-to-back
//     tx_start pulses cannot corrupt an in-progress frame.
//==============================================================================

module uart_tx (
    input  wire       clk,
    input  wire       reset,       // synchronous, active-high
    input  wire       tx_start,    // 1-cycle pulse: begin sending tx_data
    input  wire [7:0] tx_data,
    input  wire       baud_tick,   // from baud_gen: 1 pulse per bit period
    output wire       baud_restart,// to baud_gen: realign counter to new frame

    output reg        tx,          // serial output line
    output reg        tx_busy,     // 1 while a frame is in flight
    output reg        tx_done      // 1-cycle pulse when stop bit completes
);

    // FSM state encoding
    localparam [1:0] S_IDLE  = 2'd0,
                      S_START = 2'd1,
                      S_DATA  = 2'd2,
                      S_STOP  = 2'd3;

    reg [1:0] state;
    reg [7:0] shift_reg;
    reg [2:0] bit_index;

    // baud_restart must be asserted the SAME cycle tx_start is accepted
    // (not one cycle later), otherwise the start bit ends up one clock
    // cycle too long. That is why it is combinational rather than a
    // registered output.
    assign baud_restart = (state == S_IDLE) && tx_start;

    always @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            tx        <= 1'b1;   // idle line level
            tx_busy   <= 1'b0;
            tx_done   <= 1'b0;
            shift_reg <= 8'h00;
            bit_index <= 3'd0;
        end else begin
            // Default: tx_done is a 1-cycle pulse, so drop it unless the
            // STOP-bit case below re-asserts it this cycle.
            tx_done <= 1'b0;

            case (state)
                //--------------------------------------------------------
                S_IDLE: begin
                    tx      <= 1'b1;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        shift_reg <= tx_data;
                        tx        <= 1'b0;   // start bit begins this cycle
                        tx_busy   <= 1'b1;
                        bit_index <= 3'd0;
                        state     <= S_START;
                    end
                end

                //--------------------------------------------------------
                S_START: begin
                    if (baud_tick) begin
                        tx    <= shift_reg[0]; // first data bit, LSB first
                        state <= S_DATA;
                    end
                end

                //--------------------------------------------------------
                S_DATA: begin
                    if (baud_tick) begin
                        if (bit_index == 3'd7) begin
                            tx    <= 1'b1;    // stop bit
                            state <= S_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                            tx        <= shift_reg[bit_index + 1'b1];
                        end
                    end
                end

                //--------------------------------------------------------
                S_STOP: begin
                    if (baud_tick) begin
                        tx      <= 1'b1;   // return to idle level
                        tx_busy <= 1'b0;
                        tx_done <= 1'b1;   // 1-cycle completion pulse
                        state   <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
