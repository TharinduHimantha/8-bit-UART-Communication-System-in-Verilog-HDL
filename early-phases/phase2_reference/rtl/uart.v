//==============================================================================
// Module : uart
// Purpose: Top-level integration of baud_gen + uart_tx + uart_rx behind a
//          single, clean external interface, now including configurable
//          parity and protocol error reporting (parity/framing/break).
//
// PHASE 2 CHANGES FROM THE EARLIER VERSION:
//   - New parameters: DATA_BITS, PARITY_MODE (shared by both TX and RX --
//     a real link only works if both ends agree on framing, so this
//     top-level deliberately does not allow TX and RX to be configured
//     with different parity modes), BREAK_THRESHOLD_BITS (passed through
//     to uart_rx, with uart_rx's own sensible default if left unspecified).
//   - New outputs: parity_error, framing_error, break_detected (see
//     uart_rx.v and docs/architecture.md for full semantics), plus two
//     convenience aggregates:
//       rx_error  : parity_error | framing_error | break_detected
//                   ("something is wrong with the current/last reception")
//       rx_status : {break_detected, framing_error, parity_error}, a
//                   3-bit bus documented below for anyone who would rather
//                   read one bus than wire up three separate signals.
//     Both are purely combinational OR-reductions of the three underlying
//     signals -- no new state, no new registers, per the assignment's
//     "do not introduce unnecessary registers" guidance.
//
// rx_status encoding (documented per the assignment's request that any
// error bus have its encoding written down):
//   bit 0 = parity_error
//   bit 1 = framing_error
//   bit 2 = break_detected
//==============================================================================

`include "uart_defs.vh"

module uart #(
    parameter integer CLK_FREQ_HZ           = 50_000_000,
    parameter integer BAUD_RATE             = 115200,
    parameter integer DATA_BITS             = 8,
    parameter [1:0]   PARITY_MODE           = `UART_PARITY_NONE,
    // Passed straight through to uart_rx; if left at its default (-1, a
    // sentinel meaning "use uart_rx's own default"), uart_rx computes its
    // usual (1 frame + 1 bit margin) threshold itself. Overridable here so
    // a testbench (or a real system with unusual break-timing needs) can
    // reach it without editing uart_rx directly.
    parameter integer BREAK_THRESHOLD_BITS  = -1
) (
    input  wire                  clk,
    input  wire                  reset,      // synchronous, active-high

    // TX side
    input  wire [DATA_BITS-1:0]  tx_data,
    input  wire                  tx_start,
    output wire                  tx_busy,
    output wire                  tx_done,

    // RX side
    output wire [DATA_BITS-1:0]  rx_data,
    output wire                  rx_valid,
    output wire                  rx_busy,
    output wire                  parity_error,
    output wire                  framing_error,
    output wire                  break_detected,
    output wire                  rx_error,     // parity_error | framing_error | break_detected
    output wire [2:0]            rx_status,    // {break_detected, framing_error, parity_error}

    // Serial pins
    output wire                  tx,
    input  wire                  rx
);

    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;

    wire baud_tick;
    wire baud_restart;

    baud_gen #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) u_baud_gen (
        .clk     (clk),
        .reset   (reset),
        .restart (baud_restart),
        .tick    (baud_tick)
    );

    uart_tx #(
        .DATA_BITS   (DATA_BITS),
        .PARITY_MODE (PARITY_MODE)
    ) u_uart_tx (
        .clk          (clk),
        .reset        (reset),
        .tx_start     (tx_start),
        .tx_data      (tx_data),
        .baud_tick    (baud_tick),
        .baud_restart (baud_restart),
        .tx           (tx),
        .tx_busy      (tx_busy),
        .tx_done      (tx_done)
    );

    generate
        if (BREAK_THRESHOLD_BITS <= 0) begin : g_rx_default_break
            uart_rx #(
                .CLKS_PER_BIT (CLKS_PER_BIT),
                .DATA_BITS    (DATA_BITS),
                .PARITY_MODE  (PARITY_MODE)
            ) u_uart_rx (
                .clk            (clk),
                .reset          (reset),
                .rx             (rx),
                .rx_data        (rx_data),
                .rx_valid       (rx_valid),
                .rx_busy        (rx_busy),
                .parity_error   (parity_error),
                .framing_error  (framing_error),
                .break_detected (break_detected)
            );
        end else begin : g_rx_custom_break
            uart_rx #(
                .CLKS_PER_BIT         (CLKS_PER_BIT),
                .DATA_BITS            (DATA_BITS),
                .PARITY_MODE          (PARITY_MODE),
                .BREAK_THRESHOLD_BITS (BREAK_THRESHOLD_BITS)
            ) u_uart_rx (
                .clk            (clk),
                .reset          (reset),
                .rx             (rx),
                .rx_data        (rx_data),
                .rx_valid       (rx_valid),
                .rx_busy        (rx_busy),
                .parity_error   (parity_error),
                .framing_error  (framing_error),
                .break_detected (break_detected)
            );
        end
    endgenerate

    assign rx_error  = parity_error | framing_error | break_detected;
    assign rx_status = {break_detected, framing_error, parity_error};

endmodule
