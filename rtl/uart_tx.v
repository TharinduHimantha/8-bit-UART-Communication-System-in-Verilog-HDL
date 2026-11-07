//==============================================================================
// Module : uart_tx
// Purpose: Serializes one byte onto a UART TX line: start bit, DATA_BITS data
//          bits (LSB first), an optional parity bit, and 1 or 2 stop bits.
//          Idle line level is 1.
//
// PHASE 6-8 CHANGE FROM THE EARLIER (PARAMETER-ONLY) VERSION:
//   PARITY_MODE and stop-bit count are now runtime INPUTS
//   (cfg_parity_mode, cfg_stop_bits2), driven from the FRAME_CONFIG
//   register (see docs/register_map.md), not Verilog parameters. This is
//   required because this phase's register interface lets software choose
//   the frame format at runtime; a compile-time parameter cannot do that.
//
//   Exactly like tx_data and the computed parity bit, cfg_parity_mode and
//   cfg_stop_bits2 are LATCHED once, in S_IDLE, at the same moment tx_start
//   is accepted -- not read live throughout the frame. This guarantees a
//   FRAME_CONFIG write that lands mid-frame cannot change the bit count or
//   parity behavior of a frame already in flight; it only affects frames
//   that start after the write. This mirrors the timing-safety reasoning
//   already used for BAUD_DIV in baud_gen.v.
//
// FSM (4, 5, or 6 states depending on latched config):
//   S_IDLE   : tx = 1. Waiting for tx_start. Latches tx_data, the computed
//              parity bit, cfg_parity_mode, and cfg_stop_bits2 all on the
//              same cycle tx_start is accepted; starts driving the start
//              bit; pulses "baud_restart".
//   S_START  : tx = 0 (start bit). Waits one full bit period.
//   S_DATA   : tx = shift_reg[bit_index]. Advances through DATA_BITS bits.
//   S_PARITY : tx = parity_bit_reg. Only entered if latched parity mode != NONE.
//   S_STOP1  : tx = 1 (first/only stop bit).
//   S_STOP2  : tx = 1 (second stop bit). Only entered if latched
//              stop_bits2_reg == 1. Returns to S_IDLE and pulses tx_done.
//
// Parity calculation: unchanged from the prior phase (see docs/architecture.md):
//   EVEN parity bit = ^tx_data.  ODD parity bit = ~(^tx_data).
//
// Timing: unchanged restart/tick handshake with baud_gen -- every bit,
// including both stop bits when configured, is exactly one baud_gen tick
// period wide, with no phase drift (see docs/architecture.md).
//==============================================================================

`include "uart_defs.vh"

module uart_tx #(
    parameter integer DATA_BITS = 8
) (
    input  wire                  clk,
    input  wire                  reset,        // synchronous, active-high
    input  wire                  tx_start,     // 1-cycle pulse: begin sending tx_data
    input  wire [DATA_BITS-1:0]  tx_data,
    input  wire [1:0]            cfg_parity_mode, // latched at frame start
    input  wire                  cfg_stop_bits2,  // latched at frame start; 1=2 stop bits
    input  wire                  baud_tick,    // from baud_gen: 1 pulse per bit period
    output wire                  baud_restart, // to baud_gen: realign counter to new frame

    output reg                   tx,           // serial output line
    output reg                   tx_busy,      // 1 while a frame is in flight
    output reg                   tx_done       // 1-cycle pulse when the frame completes
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

    localparam [2:0] S_IDLE   = 3'd0,
                      S_START  = 3'd1,
                      S_DATA   = 3'd2,
                      S_PARITY = 3'd3,
                      S_STOP1  = 3'd4,
                      S_STOP2  = 3'd5;

    reg [2:0]           state;
    reg [DATA_BITS-1:0] shift_reg;
    reg [BIW-1:0]       bit_index;
    reg                 parity_bit_reg;
    reg [1:0]           parity_mode_reg;   // latched copy, stable for the whole frame
    reg                 stop_bits2_reg;    // latched copy, stable for the whole frame

    wire parity_bit_comb = (cfg_parity_mode == `UART_PARITY_ODD) ? ~(^tx_data)
                                                                    :  (^tx_data);

    assign baud_restart = (state == S_IDLE) && tx_start;

    always @(posedge clk) begin
        if (reset) begin
            state           <= S_IDLE;
            tx              <= 1'b1;
            tx_busy         <= 1'b0;
            tx_done         <= 1'b0;
            shift_reg       <= {DATA_BITS{1'b0}};
            bit_index       <= {BIW{1'b0}};
            parity_bit_reg  <= 1'b0;
            parity_mode_reg <= `UART_PARITY_NONE;
            stop_bits2_reg  <= 1'b0;
        end else begin
            tx_done <= 1'b0; // default: one-cycle pulse

            case (state)
                //--------------------------------------------------------
                S_IDLE: begin
                    tx      <= 1'b1;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        shift_reg       <= tx_data;
                        parity_bit_reg  <= parity_bit_comb;
                        parity_mode_reg <= cfg_parity_mode;
                        stop_bits2_reg  <= cfg_stop_bits2;
                        tx              <= 1'b0;
                        tx_busy         <= 1'b1;
                        bit_index       <= {BIW{1'b0}};
                        state           <= S_START;
                    end
                end

                //--------------------------------------------------------
                S_START: begin
                    if (baud_tick) begin
                        tx    <= shift_reg[0];
                        state <= S_DATA;
                    end
                end

                //--------------------------------------------------------
                S_DATA: begin
                    if (baud_tick) begin
                        if (bit_index == LAST_BIT_INDEX) begin
                            if (parity_mode_reg == `UART_PARITY_NONE) begin
                                tx    <= 1'b1;
                                state <= S_STOP1;
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
                        tx    <= 1'b1;
                        state <= S_STOP1;
                    end
                end

                //--------------------------------------------------------
                S_STOP1: begin
                    if (baud_tick) begin
                        if (stop_bits2_reg) begin
                            tx    <= 1'b1;
                            state <= S_STOP2;
                        end else begin
                            tx      <= 1'b1;
                            tx_busy <= 1'b0;
                            tx_done <= 1'b1;
                            state   <= S_IDLE;
                        end
                    end
                end

                //--------------------------------------------------------
                S_STOP2: begin
                    if (baud_tick) begin
                        tx      <= 1'b1;
                        tx_busy <= 1'b0;
                        tx_done <= 1'b1;
                        state   <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
