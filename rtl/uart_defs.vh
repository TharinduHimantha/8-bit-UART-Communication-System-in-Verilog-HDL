//==============================================================================
// File: uart_defs.vh
//
// Shared constants for the UART subsystem. Plain Verilog has no package/
// import mechanism, so a `include`d header with `define macros is the
// standard, portable way to give every module (and every testbench) the
// same encoding without repeating magic numbers, or worse, letting them
// drift out of sync between files.
//
// PARITY_MODE encoding (2 bits, passed as a parameter to uart_tx/uart_rx):
//   2'd0 = NONE  : no parity bit is transmitted or expected
//   2'd1 = EVEN  : parity bit makes (DATA + PARITY) have an even number of 1s
//   2'd2 = ODD   : parity bit makes (DATA + PARITY) have an odd  number of 1s
//   2'd3 = reserved / unused
//==============================================================================

`ifndef UART_DEFS_VH
`define UART_DEFS_VH

`define UART_PARITY_NONE 2'd0
`define UART_PARITY_EVEN 2'd1
`define UART_PARITY_ODD  2'd2

`endif
