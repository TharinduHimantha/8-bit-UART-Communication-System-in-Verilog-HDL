# Changelog

This project is developed in documented phases. Each phase's rationale —
not just what changed, but which assumptions from the previous phase
were revisited and why — is covered in full in
[`architecture.md`](architecture.md) Section 1. This file is the
short, itemized version for quick reference.

## Phase 2 — Parity, Framing, and Break Detection *(current)*

**Added**

- Configurable `PARITY_MODE` parameter (`NONE` / `EVEN` / `ODD`),
  shared between `uart_tx` and `uart_rx` by the top-level `uart`
  module so the two sides of a link cannot be configured to disagree.
- `parity_error` — RX independently recomputes the expected parity bit
  from the data it received and flags a mismatch.
- `framing_error` — RX flags a stop bit that doesn't read back `1`.
- `break_detected` — a dedicated, free-running counter (`low_run_count`)
  independent of the frame FSM, distinguishing a genuine break from an
  ordinary start bit by requiring the line to stay low longer than any
  legitimate frame could ever last.
- `rx_error` (OR of the three error signals) and `rx_status[2:0]`
  (bit-packed convenience bus), both purely combinational.
- `uart_defs.vh` — a shared, `` `include ``-d header for the
  `PARITY_MODE` encoding, so it has one authoritative source instead of
  being repeated across every RTL and testbench file.
- A fully-specified behavioral table (`architecture.md` Section 9)
  covering every combination of clean / parity-error / framing-error /
  break / reset-mid-frame.
- Fault injection as a first-class part of verification: `uart_rx_tb.v`
  deliberately drives malformed frames (bad parity, bad stop bit,
  sub-half-bit glitches, break conditions of varying duration).
- A second, independent reference model: `scripts/gen_vectors.py`, a
  standalone Python program with its own parity computation, generating
  randomized test vectors replayed by `tb/uart_vectors_tb.v`.
- `Makefile`-based build/regression flow (`make regression`) producing
  one pass/fail summary; VCD waveform dumps via `make waves TB=<name>`.

**Changed**

- Regression suite grew from 193 checks (phase 1) to 1937 checks.
- `tb/uart_tasks.v` gained an independent Verilog-side parity reference
  model (`model_parity_bit`), structurally different from the RTL's
  reduction-XOR (`^data`), so a bug in one can't hide from the other.

**Explicitly out of scope this phase**

- FIFOs (byte-at-a-time interface only).
- Configurable stop-bit count (fixed at 1).
- Fractional (accumulator-based) baud generation (integer division
  retained; error is calculated and documented, not hand-waved).
- Independent TX/RX reset domains (single shared `reset`, inherited
  from phase 1).

See `docs/verification.md` Section 5 for the complete, precise list of
known limitations and Section 8 for future improvements under
consideration.

## Phase 1 — UART TX/RX/Loopback Foundation

**Added**

- UART transmitter and receiver finite state machines: start bit, 8
  data bits (LSB-first), stop bit.
- `baud_gen` — a restart/tick handshake between the transmitter and the
  baud generator, keeping every bit period (including the start bit)
  exactly `CLKS_PER_BIT` cycles wide with no phase drift.
- A two-flip-flop synchronizer (`rx_sync1` / `rx_sync2`) on the
  asynchronous `rx` input.
- A self-checking loopback testbench that inspects the actual serial
  line's bit timing and ordering, not just the final received byte.
- 193 total checks across three testbenches (`uart_tb`, `uart_tx_tb`,
  `uart_rx_tb`).

Preserved unmodified under [`phase1_reference/`](../phase1_reference/)
for direct comparison against the current design.
