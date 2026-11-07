//==============================================================================
// File: uart_defs.vh
//
// Single authoritative source for every constant shared across more than
// one file in this project: the register map addresses, every register's
// bit-field positions, and the parity-mode encoding. Every RTL module and
// every testbench that needs one of these values `include`s this file
// rather than re-typing the number, specifically so the project can never
// end up with (for example) docs/register_map.md saying IRQ_ENABLE is at
// 0x1C while the RTL decodes 0x20 for it -- see docs/architecture.md's
// consistency-review note for why this matters enough to centralize.
//
// Plain Verilog has no package/import mechanism, so `include`d `define
// macros are the standard, portable way to do this.
//==============================================================================

`ifndef UART_DEFS_VH
`define UART_DEFS_VH

//------------------------------------------------------------------------
// Parity mode encoding (2 bits). Used by FRAME_CONFIG[1:0] and by every
// RTL module's cfg_parity_mode port.
//------------------------------------------------------------------------
`define UART_PARITY_NONE 2'd0
`define UART_PARITY_EVEN 2'd1
`define UART_PARITY_ODD  2'd2
// 2'd3 is reserved; treated identically to NONE (see uart_rx.v / uart_tx.v).

//------------------------------------------------------------------------
// Register map (byte addresses, word-aligned, 4-byte stride). See
// docs/register_map.md for the full field-level documentation -- these
// addresses and field positions must always match this file exactly.
//------------------------------------------------------------------------
`define UART_REG_DATA         8'h00
`define UART_REG_STATUS       8'h04
`define UART_REG_CONTROL      8'h08
`define UART_REG_BAUD_DIV     8'h0C
`define UART_REG_FRAME_CONFIG 8'h10
`define UART_REG_FIFO_STATUS  8'h14
`define UART_REG_FIFO_CONTROL 8'h18
`define UART_REG_IRQ_ENABLE   8'h1C
`define UART_REG_IRQ_STATUS   8'h20

//------------------------------------------------------------------------
// STATUS (0x04) field bit positions -- read-only.
//------------------------------------------------------------------------
`define STATUS_BIT_TX_BUSY           0
`define STATUS_BIT_TX_EMPTY          1
`define STATUS_BIT_TX_FULL           2
`define STATUS_BIT_RX_EMPTY          3
`define STATUS_BIT_RX_FULL           4
`define STATUS_BIT_RX_DATA_AVAILABLE 5
`define STATUS_BIT_PARITY_ERROR      6
`define STATUS_BIT_FRAMING_ERROR     7
`define STATUS_BIT_OVERRUN           8
`define STATUS_BIT_BREAK             9

//------------------------------------------------------------------------
// CONTROL (0x08) field bit positions -- read/write (except *_RESET, which
// are self-clearing write-pulse bits; see docs/register_map.md).
//------------------------------------------------------------------------
`define CONTROL_BIT_TX_ENABLE       0
`define CONTROL_BIT_RX_ENABLE       1
`define CONTROL_BIT_LOOPBACK_ENABLE 2
`define CONTROL_BIT_TX_FIFO_RESET   3
`define CONTROL_BIT_RX_FIFO_RESET   4

//------------------------------------------------------------------------
// FRAME_CONFIG (0x10) field bit positions.
//------------------------------------------------------------------------
`define FRAME_CONFIG_PARITY_MODE_LO 0   // 2-bit field, [1:0]
`define FRAME_CONFIG_PARITY_MODE_HI 1
`define FRAME_CONFIG_BIT_STOP_BITS2 2   // 0 = 1 stop bit, 1 = 2 stop bits

//------------------------------------------------------------------------
// FIFO_STATUS (0x14) field bit positions. Counts are 8 bits wide, wide
// enough for any FIFO_DEPTH up to 256 entries; see docs/fifo.md for why
// 8 bits was chosen instead of parameterizing the count width too.
//------------------------------------------------------------------------
`define FIFO_STATUS_TX_COUNT_LO 0   // [7:0]
`define FIFO_STATUS_TX_COUNT_HI 7
`define FIFO_STATUS_RX_COUNT_LO 8   // [15:8]
`define FIFO_STATUS_RX_COUNT_HI 15
`define FIFO_STATUS_BIT_TX_FULL  16
`define FIFO_STATUS_BIT_TX_EMPTY 17
`define FIFO_STATUS_BIT_RX_FULL  18
`define FIFO_STATUS_BIT_RX_EMPTY 19

//------------------------------------------------------------------------
// FIFO_CONTROL (0x18) field bit positions -- interrupt threshold config.
//------------------------------------------------------------------------
`define FIFO_CONTROL_TX_THRESH_LO 0  // [7:0] -- IRQ when TX count <= threshold
`define FIFO_CONTROL_TX_THRESH_HI 7
`define FIFO_CONTROL_RX_THRESH_LO 8  // [15:8] -- IRQ when RX count >= threshold
`define FIFO_CONTROL_RX_THRESH_HI 15

//------------------------------------------------------------------------
// IRQ_ENABLE (0x1C) / IRQ_STATUS (0x20) share the same bit layout: bit N
// of IRQ_STATUS is only visible in `irq` when bit N of IRQ_ENABLE is 1
// (see docs/interrupts.md for the full raw/pending/enabled model).
//------------------------------------------------------------------------
`define IRQ_BIT_PARITY_ERROR   0
`define IRQ_BIT_FRAMING_ERROR  1
`define IRQ_BIT_OVERRUN        2
`define IRQ_BIT_BREAK          3
`define IRQ_BIT_RX_AVAILABLE   4   // at least one byte in RX FIFO
`define IRQ_BIT_RX_THRESHOLD   5   // RX FIFO count >= FIFO_CONTROL.RX_THRESH
`define IRQ_BIT_TX_EMPTY       6   // TX FIFO became empty
`define IRQ_BIT_TX_THRESHOLD   7   // TX FIFO count <= FIFO_CONTROL.TX_THRESH
`define IRQ_NUM_SOURCES        8

`endif
