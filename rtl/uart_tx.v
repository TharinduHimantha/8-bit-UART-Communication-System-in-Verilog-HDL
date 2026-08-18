//==============================================================================
// Module : uart_tx
// Purpose: Serializes one byte onto a UART TX line: start bit, DATA_BITS data
//          bits (LSB first), an optional parity bit, and a stop bit. Idle
//          line level is 1.
//
// PHASE 2 CHANGE FROM THE EARLIER VERSION:
//   Adds a PARITY_MODE parameter (NONE/EVEN/ODD, see rtl/uart_defs.vh) and an
//   extra FSM state, S_PARITY, that is only entered when parity is enabled.
//   The parity bit is calculated ONCE, at the same moment tx_data is
//   latched (in S_IDLE, when tx_start is accepted) -- not recomputed every
//   clock cycle while transmitting, per the assignment's guidance to avoid
//   redundant recomputation. It is captured into parity_bit_reg alongside
//   the data shift register.
//
// FSM (4 or 5 states, depending on PARITY_MODE):
//   S_IDLE   : tx = 1. Waiting for tx_start. Latches tx_data AND the
//              computed parity bit on the same cycle it accepts tx_start,
//              starts driving the start bit, and pulses "baud_restart".
//   S_START  : tx = 0 (start bit). Waits one full bit period.
//   S_DATA   : tx = shift_reg[bit_index]. Advances through DATA_BITS bits.
//   S_PARITY : tx = parity_bit_reg. Only entered if PARITY_MODE != NONE.
//   S_STOP   : tx = 1 (stop bit). Returns to S_IDLE and pulses tx_done.
//
// Parity calculation, explained (see also docs/architecture.md Section on
// parity):
//   EVEN parity means the total number of 1 bits across DATA+PARITY must be
//   even. A Verilog reduction-XOR, ^tx_data, evaluates to 1 exactly when
//   tx_data contains an ODD number of 1 bits. So:
//     - if tx_data already has an even number of 1s, the parity bit must be
//       0 to keep the total even -- and ^tx_data is 0 in that case.
//     - if tx_data has an odd number of 1s, the parity bit must be 1 to make
//       the total even -- and ^tx_data is 1 in that case.
//   So EVEN parity is simply: parity_bit = ^tx_data.
//   ODD parity is the exact complement: parity_bit = ~(^tx_data).
//   This is computed combinationally (parity_bit_comb below) purely so the
//   register capture is a one-line, auditable assignment; it is still only
//   ever *latched* once per frame, in S_IDLE.
//
// Timing:
//   Identical restart/tick handshake with baud_gen as the earlier version
//   (see docs/architecture.md): baud_restart is pulsed combinationally the
//   same cycle tx_start is accepted, so every bit -- including the start
//   bit and, now, the parity bit -- lasts exactly CLKS_PER_BIT cycles with
//   no phase drift.
//
// Common mistakes this design avoids:
//   - Recomputing parity every cycle from a changing tx_data: if the caller
//     changes tx_data mid-frame (which is otherwise harmless, see below),
//     recomputing parity on the fly could transmit a parity bit that
//     doesn't match the data bits actually sent. Capturing it once avoids
//     this class of bug entirely.
//   - Forgetting to gate the PARITY state behind PARITY_MODE: skipping
//     straight from DATA to STOP when parity is disabled, rather than
//     always transmitting a parity bit whether needed or not.
//==============================================================================

`include "uart_defs.vh"

module uart_tx #(
    parameter integer DATA_BITS   = 8,
    parameter [1:0]   PARITY_MODE = `UART_PARITY_NONE
) (
    input  wire                  clk,
    input  wire                  reset,       // synchronous, active-high
    input  wire                  tx_start,    // 1-cycle pulse: begin sending tx_data
    input  wire [DATA_BITS-1:0]  tx_data,
    input  wire                  baud_tick,   // from baud_gen: 1 pulse per bit period
    output wire                  baud_restart,// to baud_gen: realign counter to new frame

    output reg                   tx,          // serial output line
    output reg                   tx_busy,     // 1 while a frame is in flight
    output reg                   tx_done      // 1-cycle pulse when stop bit completes
);

    localparam BIW = (DATA_BITS <= 1) ? 1 : $clog2(DATA_BITS); // bit_index width

    // FSM state encoding
    localparam [2:0] S_IDLE   = 3'd0,
                      S_START  = 3'd1,
                      S_DATA   = 3'd2,
                      S_PARITY = 3'd3,
                      S_STOP   = 3'd4;

    reg [2:0]           state;
    reg [DATA_BITS-1:0] shift_reg;
    reg [BIW-1:0]       bit_index;
    reg                 parity_bit_reg;

    // See header comment: EVEN parity = ^tx_data, ODD parity = ~(^tx_data).
    // Combinational; only ever sampled into parity_bit_reg once, in S_IDLE.
    wire parity_bit_comb = (PARITY_MODE == `UART_PARITY_ODD) ? ~(^tx_data)
                                                               :  (^tx_data);

    // baud_restart must be asserted the SAME cycle tx_start is accepted
    // (not one cycle later), otherwise the start bit ends up one clock
    // cycle too long (see docs/architecture.md for how this was found).
    assign baud_restart = (state == S_IDLE) && tx_start;

    always @(posedge clk) begin
        if (reset) begin
            state          <= S_IDLE;
            tx             <= 1'b1;   // idle line level
            tx_busy        <= 1'b0;
            tx_done        <= 1'b0;
            shift_reg      <= {DATA_BITS{1'b0}};
            bit_index      <= {BIW{1'b0}};
            parity_bit_reg <= 1'b0;
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
                        shift_reg      <= tx_data;
                        parity_bit_reg <= parity_bit_comb; // captured once
                        tx             <= 1'b0;   // start bit begins this cycle
                        tx_busy        <= 1'b1;
                        bit_index      <= {BIW{1'b0}};
                        state          <= S_START;
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
                        if (bit_index == DATA_BITS - 1) begin
                            if (PARITY_MODE == `UART_PARITY_NONE) begin
                                tx    <= 1'b1;      // stop bit, no parity sent
                                state <= S_STOP;
                            end else begin
                                tx    <= parity_bit_reg;
                                state <= S_PARITY;
                            end
                        end else begin
                            bit_index <= bit_index + 1'b1;
                            tx        <= shift_reg[bit_index + 1'b1];
                        end
                    end
                end

                //--------------------------------------------------------
                S_PARITY: begin
                    if (baud_tick) begin
                        tx    <= 1'b1;   // stop bit
                        state <= S_STOP;
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
