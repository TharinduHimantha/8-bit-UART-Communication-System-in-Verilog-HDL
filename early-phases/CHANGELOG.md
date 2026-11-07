# Changelog

This project was developed incrementally across several phases. Each
phase's design review (what assumptions the previous phase made, what
had to change, and why) is documented in detail in
[`docs/architecture.md`](docs/architecture.md); this file is a shorter,
chronological summary.

## Phase 3 — FIFOs, Register Interface, Interrupts *(current)*

The peripheral gained a full software-facing interface on top of the
earlier working serial engine:

- **TX/RX FIFOs**: a generic, reusable, parameterized synchronous FIFO
  (`uart_fifo.v`), power-of-two depths only (checked at elaboration
  time), first-word-fall-through reads. See
  [`docs/fifo.md`](docs/fifo.md).
- **Memory-mapped register interface**: single-cycle, no wait states,
  9 registers (`DATA`, `STATUS`, `CONTROL`, `BAUD_DIV`, `FRAME_CONFIG`,
  `FIFO_STATUS`, `FIFO_CONTROL`, `IRQ_ENABLE`, `IRQ_STATUS`). See
  [`docs/register_map.md`](docs/register_map.md).
- **Runtime-configurable baud/parity/stop-bits**: previously
  elaboration-time Verilog parameters, now software-writable registers,
  with config latched per-frame (not read live) so a mid-frame register
  write can never corrupt a frame already in flight, and baud-divisor
  changes specifically deferred until the link is fully idle.
- **Dedicated interrupt subsystem** (`uart_irq.v`): 8 sources, split
  between sticky/edge-latched/write-1-clear (one-shot error events) and
  live/level-mirrored (ongoing FIFO conditions) — see
  [`docs/interrupts.md`](docs/interrupts.md).
- **RX overrun detection**: a validated byte arriving while the RX FIFO
  is full is discarded and flagged, with the FIFO's existing contents
  left completely undisturbed.
- **Full-path internal loopback**, routed through the real TX/RX FSMs
  and FIFOs rather than a data-copy shortcut.
- **Verification**: two testbenches (`tb/fifo_tb.v`, 2014 checks;
  `tb/uart_core_tb.v`, 132 checks), a real Verilator lint pass (0
  warnings), and a real Yosys synthesis check (0 problems, explicit
  latch-inference check). See [`docs/verification.md`](docs/verification.md)
  for the full test matrix and every bug found during this phase's
  development.

**Notable bugs found and fixed during this phase** (full writeups in
`docs/verification.md` Section 4):
- An RX baud-timing protection gap where the receiver read the raw,
  live `BAUD_DIV` register instead of the frame-stable value TX used,
  only surfaced by a directed mid-frame-reconfiguration test.
- A FIFO read-latency hazard in the register-interface `DATA` read,
  which motivated redesigning the FIFO's read side to first-word-
  fall-through rather than patching around the symptom.
- A blocking-assignment race on `reset` in a testbench, adopted from
  that point forward as a project-wide rule (always use `reset <= ...`).

## Earlier phase — Parity, Framing, and Break Detection

Added to the base TX/RX/loopback design:

- Configurable parity (NONE/EVEN/ODD) with an independently-verified
  parity calculation (both TX generation and RX checking).
- Framing-error detection (invalid stop bit), with a fully-specified
  behavioral table covering every combination of clean/parity-error/
  framing-error/break/reset-mid-frame.
- Break-condition detection: a dedicated free-running counter,
  independent of the frame state machine, distinguishing a genuine
  break from an ordinary start bit by requiring the line to stay low
  longer than any legitimate frame could ever last.
- Two independent reference models used for verification: a
  structurally-different Verilog-side parity calculation, and a
  separate Python-based vector generator/reference model.

## Earliest phase — UART TX/RX/Loopback Foundation

The initial working design:

- UART transmitter and receiver finite state machines (start bit, 8
  data bits LSB-first, stop bit).
- A restart/tick baud-timing handshake between the transmitter and the
  baud generator, keeping every bit period — including the start bit —
  exactly `CLKS_PER_BIT` cycles wide with no phase drift.
- A two-flip-flop synchronizer on the asynchronous RX input.
- A self-checking loopback testbench that inspects the actual serial
  line's bit timing and ordering, not just the final received byte.
