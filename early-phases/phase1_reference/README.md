# UART (8-N-1) in Synthesizable Verilog

A modular, synthesizable 8-bit UART transmitter/receiver, built and
verified in plain Verilog-2005 (no SystemVerilog, no vendor primitives).

```
uart/
├── rtl/
│   ├── baud_gen.v     -- bit-timing / baud tick generator
│   ├── uart_tx.v       -- transmitter FSM
│   ├── uart_rx.v       -- receiver FSM
│   └── uart.v           -- top-level integration
│
├── tb/
│   ├── uart_tasks.v    -- shared testbench tasks (`include`d by the others)
│   ├── uart_tb.v         -- self-checking loopback testbench (top-level)
│   ├── uart_tx_tb.v      -- unit testbench for uart_tx alone
│   └── uart_rx_tb.v      -- unit testbench for uart_rx alone
│
├── docs/
│   └── architecture.md  -- full architecture, FSM, and timing writeup
│
└── README.md (this file)
```

This matches the structure requested in the assignment, with one small
addition: `tb/uart_tasks.v` is *included* (via `` `include ``) by all
three testbenches rather than compiled as its own top-level module. Plain
Verilog has no package/import system, so textual inclusion is the
standard, portable way to share testbench code (tasks, bookkeeping regs)
across multiple testbench files -- see the header comment in
`uart_tasks.v` for the naming contract each including testbench must
follow.

## UART format implemented

- 8 data bits, 1 start bit, 1 stop bit, no parity (8-N-1)
- LSB transmitted first
- Idle line level = `1`
- Fully synchronous, single system clock, synchronous active-high reset
- No `#` delays, `initial` blocks, `force`/`release`, or vendor primitives
  anywhere in `rtl/` -- all of that is confined to `tb/`

## How to simulate

Any standard Verilog-2005 simulator will work. Using
[Icarus Verilog](http://iverilog.icarus.com/), which is what this project
was developed and verified against:

```sh
# Full self-checking loopback test (TX -> wire -> RX, 101 checks)
iverilog -g2005 -o uart_tb.out rtl/baud_gen.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart.v tb/uart_tb.v -I tb
vvp uart_tb.out

# TX-only unit test (69 checks)
iverilog -g2005 -o uart_tx_tb.out rtl/baud_gen.v rtl/uart_tx.v tb/uart_tx_tb.v -I tb
vvp uart_tx_tb.out

# RX-only unit test (23 checks, including deliberately malformed frames)
iverilog -g2005 -o uart_rx_tb.out rtl/uart_rx.v tb/uart_rx_tb.v -I tb
vvp uart_rx_tb.out
```

All three currently report:

```
----------------------------------------
  <N> / <N> tests passed
  ALL TESTS PASSED
----------------------------------------
```

(101/101, 69/69, and 23/23 respectively, 193 checks total, last verified
against this exact source with Icarus Verilog 12.0.)

The main loopback testbench uses simulation-friendly baud parameters
(`CLK_FREQ_HZ=1000`, `BAUD_RATE=100` -> `CLKS_PER_BIT=10`) to keep
simulated waveforms short and easy to inspect by eye if needed. The same
RTL was also verified, separately, against realistic parameters
(`CLK_FREQ_HZ=50_000_000`, `BAUD_RATE=115200` -> `CLKS_PER_BIT=434`,
matching the worked example in `docs/architecture.md`) to confirm nothing
was accidentally tuned to only work with a small, round `CLKS_PER_BIT`.
See "Lessons learned" below for how that check surfaced a testbench-only
bug (not an RTL bug).

## What's verified, and how

`tb/uart_tb.v` doesn't just compare `rx_data == tx_data`. It checks, for
real, on the actual serial line and actual control signals:

- Reset behavior (`tx` idle high, `tx_busy`/`rx_busy` low)
- TX idle behavior (line stays high with no `tx_start`)
- Start-bit, each data-bit (LSB first), and stop-bit **duration and
  value**, by sampling the `tx` pin once per clock for an entire frame
  and checking each `CLKS_PER_BIT`-wide segment is uniform and correct
- `tx_busy` asserted for the entire frame, deasserted immediately after
  `tx_done`
- `tx_done` and `rx_valid` are both exactly one-clock-wide pulses
- `rx_data` remains stable after `rx_valid` falls
- No spurious `rx_error` on a clean frame
- Full TX -> wire -> RX loopback for: a single byte, `0x00`, `0xFF`,
  `0x55`, `0xAA`, a 5-byte back-to-back burst with no idle gap, and 8
  random bytes
- `tx_busy` correctly blocks/ignores overlapping `tx_start`s between
  consecutive sends

`tb/uart_tx_tb.v` and `tb/uart_rx_tb.v` isolate each half of the design.
Notably, `uart_rx_tb.v` bit-bangs raw frames directly onto `rx` (bypassing
`uart_tx` entirely), including two kinds of intentionally malformed
frames -- a bad stop bit and a start-bit-shaped glitch shorter than half a
bit period -- and checks that both correctly produce `rx_error` instead
of a fabricated `rx_valid`/`rx_data`.

## Lessons learned while building this (a note on testbench races)

Two real bugs were caught during development, and both are worth
understanding if you extend this testbench, because they're the kind of
mistake that's easy to reintroduce:

1. **A one-cycle-late testbench sample can look like an RTL bug.** An
   early version of the frame-capture task read the `tx` pin immediately
   after `@(posedge clk)`. Because the DUT's outputs update via
   nonblocking assignments that settle in the NBA region *after* the
   active region resumes, that read could see the pin's *previous*
   (stale) value, not the one this edge just produced. The fix: sample at
   `@(negedge clk)` instead (or add a small delay after `@(posedge clk)`)
   so the read happens safely after the DUT's outputs have settled. This
   is a general testbench hygiene rule, not specific to this project.
2. **Waiting for two independent single-cycle pulses sequentially can
   miss one of them.** `tx_done` and `rx_valid` don't necessarily land on
   the same cycle, or even in a fixed order (see
   `docs/architecture.md`, Section 6). An early version of the testbench
   did `wait_for_tx_done;` followed by `wait_for_rx_valid;`. If
   `rx_valid` happened to pulse *before* `tx_done` was detected, by the
   time the second wait started polling, that one-cycle pulse had already
   come and gone, and the testbench would hang waiting for something that
   already happened. The fix, `wait_for_tx_and_rx` in `uart_tasks.v`,
   waits for both concurrently in a single `fork`/`join`.

Both were found by actually running the design in Icarus Verilog and
reading the waveforms/timestamps, not by inspection -- a good reminder
that "the RTL looks right" and "the RTL simulates correctly" are
different claims, and only the second one is the one that counts.

## Design philosophy

- One responsibility per module; no single "do everything" UART module.
- No premature optimization: integer-division baud generation is used
  even though it has a small, calculated error, because that error is
  negligible for the target use case (see `docs/architecture.md` Section
  5.1) and a fractional/accumulator-based generator isn't needed yet.
- Every non-obvious timing decision (the `baud_restart` handshake, the
  RX half-bit/full-bit sampling ladder, the input synchronizer) has a
  comment in the RTL explaining *why*, not just *what*, and is backed by
  a specific, named test in `tb/`.

See `docs/architecture.md` for the full write-up: module-by-module
interfaces, both FSMs in detail, the complete timing derivation
(including the baud-rate error calculation), corner cases, and the
design decisions behind each non-obvious choice.
