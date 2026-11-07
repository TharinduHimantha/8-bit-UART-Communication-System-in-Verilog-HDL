//==============================================================================
// Module : uart
// Purpose: Top-level integration of baud_gen + uart_tx + uart_rx behind a
//          single, clean external interface. This is the module a larger
//          system (or a testbench) instantiates.
//
// CLKS_PER_BIT is computed ONCE here, from CLK_FREQ_HZ and BAUD_RATE, and
// handed down as a plain integer parameter to both baud_gen (for TX timing)
// and uart_rx (for its independent sampling counter). Computing it in one
// place guarantees TX and RX always agree on the same bit period, even
// though internally they use it in different ways (TX: shared tick from a
// restart-synchronized divider; RX: its own free-standing counter re-armed
// on every detected start edge).
//
// Baud-rate error from integer division:
//   CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE using Verilog integer division
//   truncates any remainder. The actual bit period the hardware produces is
//   therefore CLKS_PER_BIT/CLK_FREQ_HZ seconds, not exactly 1/BAUD_RATE.
//   Example: 50 MHz clock, 115200 baud target:
//       50_000_000 / 115200 = 434.027...  -> truncates to 434
//       actual baud = 50_000_000 / 434    = 115207.4 baud
//       error       = (115207.4 - 115200) / 115200 = +0.0064%
//   This is small enough to be irrelevant in practice (real UARTs tolerate
//   roughly +/-2% before bit errors appear), but the error grows for clock/
//   baud combinations that divide less evenly, and can matter more for very
//   high baud rates relative to the clock. This design does not implement
//   fractional (accumulator-based) baud generation, since it isn't needed
//   at this phase; it would be a natural future enhancement if a specific
//   target clock/baud pair produced too much error.
//==============================================================================

module uart #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BAUD_RATE   = 115200
) (
    input  wire       clk,
    input  wire       reset,      // synchronous, active-high

    // TX side
    input  wire [7:0] tx_data,
    input  wire       tx_start,
    output wire        tx_busy,
    output wire        tx_done,

    // RX side
    output wire [7:0] rx_data,
    output wire        rx_valid,
    output wire        rx_busy,
    output wire        rx_error,

    // Serial pins
    output wire        tx,
    input  wire        rx
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

    uart_tx u_uart_tx (
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

    uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) u_uart_rx (
        .clk      (clk),
        .reset    (reset),
        .rx       (rx),
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .rx_busy  (rx_busy),
        .rx_error (rx_error)
    );

endmodule
