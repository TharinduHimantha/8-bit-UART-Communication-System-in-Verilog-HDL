# UART Architecture (Phase 2: Parity, Framing, and Break Detection)

This document supersedes the phase-1 architecture writeup (preserved at
`docs/architecture.md.phase1.bak` for reference) and describes the design
as it stands after adding configurable parity, framing-error detection,
and break detection. Verification methodology, test categories, and the
Python reference model are documented separately in
`docs/verification.md`.

## 1. What changed from phase 1, and why

Phase 1 delivered a working TX/RX pair with no error handling: any byte
that arrived with a bad stop bit was silently accepted as if it were
correct. That is not how a real UART peripheral behaves, and it is the
central gap this phase closes. Before writing any new RTL, the existing
phase-1 design was reviewed for assumptions that needed to be revisited:

- **Assumption**: TX and RX only ever need to agree on `CLKS_PER_BIT`.
  **No longer true**: they must also agree on `PARITY_MODE`, since parity
  is a framing-level agreement between both ends of the link, not a
  per-side setting. The top-level `uart` module deliberately takes a
  single `PARITY_MODE` parameter and wires it to both `uart_tx` and
  `uart_rx`, rather than letting them be configured independently, so
  that mismatch is structurally impossible instead of merely
  discouraged. See Section 4.
- **Assumption**: a bad stop bit and "the line is broken/disconnected"
  are the same failure. **Not true**, and treating them the same would
  make break detection impossible to distinguish from an ordinary framing
  error. See Section 6.
- **Assumption (implicit, phase 1)**: `rx_error`'s only job was to reject
  a single malformed byte. This phase makes explicit that there are
  actually three independently meaningful conditions (parity, framing,
  break), and that conflating them into one flag would throw away
  information a real system needs (e.g. to decide whether to request a
  retransmit vs. treat the whole link as down). See Section 5.
- **Possible bug avoided**: an early version of `uart_rx`'s break logic
  reused the frame FSM's own bit counter to measure "how long has the
  line been low." That doesn't work: the frame FSM's counter resets every
  time a bit boundary is reached, so it can never accumulate a duration
  longer than one bit period, and can never observe a break at all. The
  final design uses a **separate, free-running counter** (`low_run_count`,
  Section 6) specifically because it must keep counting independently of
  whatever state the frame FSM is in.

## 2. Module inventory (updated)

```
                    +----------------------------------------------------+
                    |                       uart.v                       |
                    |                                                    |
  tx_data[7:0] ---->|                                                    |
  tx_start ---->|   +-----------+        +----------+                    |
                |   | baud_gen  |--tick->| uart_tx  |--tx--------------->|---> tx (pin)
                |   |(CLKS_PER  |<-------|(+parity) |                    |
                |   |  _BIT)    |restart |          |---tx_busy--------->|---> tx_busy
                |   +-----------+        +----------+---tx_done--------->|---> tx_done
                |                                                        |
   rx (pin)---->|--rx-->  +------------+                                 |
                |         |  uart_rx   |--rx_data[7:0]------------------>|---> rx_data
                |         |(+parity,   |--rx_valid------------------------>|---> rx_valid
                |         | framing,   |--rx_busy--------------------------->|---> rx_busy
                |         | break)     |--parity_error----------------------->|---> parity_error
                |         +------------+--framing_error----------------------->|---> framing_error
                |                      --break_detected--------------------------->|---> break_detected
                |                                                        |
                |         rx_error  = OR of the three error signals ---->|---> rx_error
                |         rx_status = {break,framing,parity} bus ------->|---> rx_status[2:0]
                +--------------------------------------------------------+
```

| Module        | File               | Responsibility                                                    |
|---------------|--------------------|---------------------------------------------------------------------|
| `baud_gen`    | `rtl/baud_gen.v`   | Unchanged from phase 1: produces `tick` once every `CLKS_PER_BIT` cycles, restartable to phase-align a new frame. |
| `uart_tx`     | `rtl/uart_tx.v`    | Serializes DATA_BITS + optional parity + stop. Computes parity once per frame, at latch time. |
| `uart_rx`     | `rtl/uart_rx.v`    | Deserializes, center-samples every field, validates parity and the stop bit, detects break conditions. |
| `uart`        | `rtl/uart.v`       | Top-level integration; shares `PARITY_MODE` between TX and RX; aggregates error outputs. |
| `uart_defs.vh`| `rtl/uart_defs.vh` | `` `include ``-d constants: the PARITY_MODE encoding, shared by every RTL file and every testbench so it can't drift out of sync between files. |

Testbenches (see `docs/verification.md` for full details):

| File                     | Purpose                                                                 |
|--------------------------|--------------------------------------------------------------------------|
| `tb/uart_tasks.v`        | Shared tasks, now including an independent Verilog-side parity reference model (`model_parity_bit`). |
| `tb/uart_tb.v`           | Top-level loopback testbench; three DUT instances (NONE/EVEN/ODD), full 0x00-0xFF sweep per mode, reset-during-frame. |
| `tb/uart_tx_tb.v`        | TX unit test; three DUT instances, verifies line-level parity-bit generation directly. |
| `tb/uart_rx_tb.v`        | RX unit test; the primary home for fault injection (bad parity, bad stop, glitches, break, combined faults, reset-during-RX). |
| `tb/uart_vectors_tb.v`   | Reads `tb/vectors/random_vectors.txt` (produced by `scripts/gen_vectors.py`, an independent Python reference model) and replays it against the RTL. |

## 3. Interfaces (updated)

### 3.1 `uart` (top level)

```verilog
module uart #(
    parameter integer CLK_FREQ_HZ           = 50_000_000,
    parameter integer BAUD_RATE             = 115200,
    parameter integer DATA_BITS             = 8,
    parameter [1:0]   PARITY_MODE           = `UART_PARITY_NONE, // see uart_defs.vh
    parameter integer BREAK_THRESHOLD_BITS  = -1  // -1 = use uart_rx's own default
) (
    input  wire                  clk,
    input  wire                  reset,      // synchronous, active-high

    input  wire [DATA_BITS-1:0]  tx_data,
    input  wire                  tx_start,
    output wire                  tx_busy,
    output wire                  tx_done,

    output wire [DATA_BITS-1:0]  rx_data,
    output wire                  rx_valid,
    output wire                  rx_busy,
    output wire                  parity_error,
    output wire                  framing_error,
    output wire                  break_detected,
    output wire                  rx_error,     // parity_error | framing_error | break_detected
    output wire [2:0]            rx_status,    // {break_detected, framing_error, parity_error}

    output wire                  tx,
    input  wire                  rx
);
```

`PARITY_MODE` is shared by both `uart_tx` and `uart_rx` -- there is no way
to configure them differently through this top-level module, deliberately
(see Section 1). `rx_error` and `rx_status` are pure combinational
OR-reductions of the three underlying signals; no new registers were
introduced for them, per the "don't introduce unnecessary registers"
design constraint. `rx_status` encoding: bit 0 = `parity_error`, bit 1 =
`framing_error`, bit 2 = `break_detected`.

### 3.2 `uart_tx`

```verilog
module uart_tx #(
    parameter integer DATA_BITS   = 8,
    parameter [1:0]   PARITY_MODE = `UART_PARITY_NONE
) (
    input  wire                  clk,
    input  wire                  reset,
    input  wire                  tx_start,
    input  wire [DATA_BITS-1:0]  tx_data,
    input  wire                  baud_tick,
    output wire                  baud_restart,
    output reg                   tx,
    output reg                   tx_busy,
    output reg                   tx_done
);
```

### 3.3 `uart_rx`

```verilog
module uart_rx #(
    parameter integer CLKS_PER_BIT         = 434,
    parameter integer DATA_BITS            = 8,
    parameter [1:0]   PARITY_MODE          = `UART_PARITY_NONE,
    parameter integer BREAK_THRESHOLD_BITS = 1+DATA_BITS+(parity?1:0)+1+1  // default, see Section 6
) (
    input  wire                  clk,
    input  wire                  reset,
    input  wire                  rx,
    output reg  [DATA_BITS-1:0]  rx_data,
    output reg                   rx_valid,
    output reg                   rx_busy,
    output reg                   parity_error,
    output reg                   framing_error,
    output wire                  break_detected
);
```

Note that `parity_error` and `framing_error` are 1-cycle pulses (`reg`,
default-cleared every cycle), while `break_detected` is a combinational
**level** output, not a pulse -- see Section 6 for why that distinction
matters and is deliberate.

## 4. Parity: FSM changes and the calculation itself

### 4.1 Where the PARITY state fits

Both FSMs gained one conditional state:

```
TX:  IDLE -> START -> DATA(x8) -> [PARITY, only if enabled] -> STOP -> IDLE
RX:  IDLE -> START -> DATA(x8) -> [PARITY, only if enabled] -> STOP -> IDLE
```

`PARITY_MODE` is an elaboration-time parameter, so the `if (PARITY_MODE ==
`UART_PARITY_NONE) ... else ...` branch that decides whether to enter the
PARITY state is a plain, ordinary `if` inside the RTL -- not a `generate`
block -- because the condition is on a parameter, which Verilog constant-
folds at synthesis time just as well either way; a `generate` block would
add complexity without adding correctness here. (The top-level `uart.v`
*does* use a `generate` block, for a different reason -- see Section 4.3.)

### 4.2 The parity calculation, explained without hiding it in an expression

**EVEN parity** means: the total number of `1` bits across DATA+PARITY
must be even.

**ODD parity** means: the total number of `1` bits across DATA+PARITY
must be odd.

Verilog's reduction-XOR operator, `^data`, evaluates to `1` exactly when
`data` contains an *odd* number of `1` bits (each XOR stage flips a
running parity bit; the net result is 1 iff an odd number of 1s were
XORed in). So:

- If `data` already has an **even** number of 1s, `^data` is `0`. To keep
  the EVEN-parity total even, the parity bit must also be `0` -- which is
  exactly what `^data` already is.
- If `data` has an **odd** number of 1s, `^data` is `1`. To make the
  EVEN-parity total even (odd + 1 = even), the parity bit must be `1` --
  which, again, is exactly `^data`.

So **EVEN parity bit = `^data`**, with no further logic needed.

**ODD parity** is the exact bitwise complement of that: **ODD parity bit
= `~(^data)`**. (If `^data` would have produced an even total, flipping
it produces an odd one instead, and vice versa.)

This is implemented identically, and independently, in two places:

- `uart_tx.v`: `parity_bit_comb = (PARITY_MODE == ODD) ? ~(^tx_data) :
  (^tx_data)`, captured once into `parity_bit_reg` at the same moment
  `tx_data` is latched (in `S_IDLE`, when `tx_start` is accepted) -- not
  recomputed every clock. If it were recomputed every clock from a live
  `tx_data` input, and the caller changed `tx_data` mid-frame (which is
  otherwise harmless -- see below), the transmitted parity bit could end
  up describing different data than the data bits actually sent. Latching
  once avoids that whole class of bug.
- `uart_rx.v`: `expected_parity = (PARITY_MODE == ODD) ? ~(^rx_shift) :
  (^rx_shift)`, computed from the data bits RX itself captured (never
  from any TX-side signal), and compared against the actually-received
  parity bit at the moment the parity bit is sampled.

### 4.3 Why `uart.v` uses `generate` for `BREAK_THRESHOLD_BITS`

`uart_rx`'s `BREAK_THRESHOLD_BITS` parameter has its own sensible default
(see Section 6.1) that is itself a function of `DATA_BITS` and
`PARITY_MODE`. The top-level `uart` module exposes an *override*
parameter, defaulting to a sentinel value of `-1` meaning "don't
override, let `uart_rx` compute its own default." Because Verilog cannot
conditionally omit a parameter override inline, `uart.v` uses a
`generate`/`if` block to instantiate `uart_rx` one of two ways: with
`BREAK_THRESHOLD_BITS` passed through explicitly (if overridden) or
without touching that parameter at all (letting `uart_rx`'s own default
expression apply). This is the one place `generate` is used in this
design, and it is used because the alternative (always passing an
explicit value) would require duplicating `uart_rx`'s default-computation
expression in `uart.v` too, creating exactly the kind of
two-places-that-must-agree risk this design otherwise avoids by sharing
constants through `uart_defs.vh`.

## 5. Framing error: exact semantics

The stop bit is sampled at its center (see Section 7 for why center
sampling, generally). If it reads back `0` instead of `1`,
`framing_error` pulses for one cycle.

**Design decision, stated explicitly (not left ambiguous):** on a framing
error (or a parity error, or both at once), `rx_valid` is **not**
asserted -- a byte that failed validation is never presented to the
caller as if it were good data. `rx_data` **is** still updated with
whatever data bits were actually captured, purely for diagnostic
visibility (e.g. so a debug/logging path can see what garbage arrived),
but the side-band error pulse is the only thing that tells the caller not
to trust it. This mirrors how many real UART peripherals behave: the data
register is still writable/readable on an error, but a status bit (not
the data itself) is what says whether to believe it.

Parity and framing checks are independent of each other. If both are
wrong in the same frame, both `parity_error` and `framing_error` pulse
together, in the same cycle -- see the full behavioral table in Section
9.

## 6. Break detection: what it means and how it's measured

### 6.1 Definition and threshold

A **break condition** is defined here as: the (synchronized) `rx` line
staying continuously **LOW** for `BREAK_THRESHOLD_BITS` bit-periods or
longer.

The assignment explicitly warns against defining break as simply `rx ==
0`, because that would misclassify an ordinary start bit (which is also
`rx == 0`, briefly) as a break. The threshold is what prevents that: it
must be large enough that **no legitimate frame, however constructed,
could ever produce a continuous low run that long.**

Why "however constructed" matters: a frame with `data = 0x00` and (if
parity is EVEN) a `0` parity bit already produces up to `1 (start) + 8
(data) = 9` consecutive low bit-periods before the parity/stop bit -- and
a real transmitter's stop bit is *always* `1`, which is exactly what
guarantees any real frame must contain at least one high pulse within its
duration. So the threshold only needs to exceed one full frame's bit
count to be safe; this design uses:

```
BREAK_THRESHOLD_BITS (default) = (1 start + DATA_BITS + parity_bits(0 or 1) + 1 stop) + 1
```

The `+1` at the end is one bit period of margin beyond the longest
possible legitimate frame duration, so a break is only ever declared once
the line has been low noticeably longer than any real frame -- including
one that happens to have a bad stop bit -- could last.

**A consequence worth stating precisely, not glossing over:** because the
threshold is *larger* than one frame's duration, a receiver watching a
line that goes low and simply stays low will necessarily complete one
full "frame's worth" of bit-sampling first -- producing one legitimate
`framing_error` pulse (the stop-bit position reads `0`, correctly, since
the line never went high) -- *before* the continuous low duration
accumulates enough to cross the break threshold. This is not a bug in
this design; it is an unavoidable consequence of the threshold needing to
exceed one frame's duration to safely distinguish "break" from "all-zero
data byte." Once `break_detected` does assert, the frame FSM stops
attempting further byte-shaped interpretations of the stuck-low line (see
6.2), so this "one leading framing error" is a one-time event per break,
not a repeating one. This is verified directly:
`tb/uart_rx_tb.v`'s "just below break threshold" test asserts there is
**exactly one** such leading `framing_error`, not zero and not many.

### 6.2 How it's measured: a free-running counter, independent of the frame FSM

A dedicated register, `low_run_count`, increments every clock cycle
`rx_s` (the synchronized `rx` input) reads `0`, and resets to `0` the
instant `rx_s` reads `1`. Critically, **this counter is not part of the
frame FSM's state** -- it is a separate always-block, running
unconditionally, specifically so it keeps counting *through* whatever the
frame FSM happens to be doing (including completing an entire spurious
frame attempt, as described above). `break_detected` is a combinational
comparison, `low_run_count == BREAK_THRESHOLD_CYCLES` (where
`BREAK_THRESHOLD_CYCLES = CLKS_PER_BIT * BREAK_THRESHOLD_BITS`), so it is
a true **level** signal: it becomes `1` the cycle the threshold is
reached, stays `1` for as long as the line remains continuously low past
that point (the counter saturates at the threshold rather than wrapping,
specifically to prevent it from spuriously toggling off due to overflow
on a very long low condition), and drops back to `0` the same cycle
`rx_s` returns to `1` (since that's also when the counter resets).

**Why level, not pulse:** a level output lets software simply poll it
("is there a break right now"), and lets the testbench verify two
separable properties independently: that it asserts promptly once the
threshold is crossed, and that it clears promptly when the line recovers
-- both checked as distinct tests in `tb/uart_rx_tb.v`.

### 6.3 What happens to the frame FSM when a break is recognized

Every cycle, before evaluating its normal state transitions, the frame
FSM checks: is `break_detected` asserted, and is the FSM currently
somewhere other than `S_IDLE` or already `S_BREAK`? If so, it is forced
into a dedicated `S_BREAK` state immediately, abandoning whatever partial
frame it was in the middle of **without** emitting a `framing_error` or
`parity_error` for that specific, currently-in-progress attempt -- a
break is a distinct condition from "a very badly framed byte," and is
reported as such, not layered on top of a fabricated per-byte error (see
6.1 for the nuance about the one frame attempt that necessarily completes
*before* this check can ever fire).

`S_BREAK` itself does nothing but wait: `rx_busy` stays asserted (the
line is still busy/abnormal), and the moment `rx_s` returns to `1`, the
FSM returns to `S_IDLE` to resume normal start-bit detection. No special
recovery sequence is needed beyond that -- verified directly by the "break
followed by a valid frame" test in `tb/uart_rx_tb.v`, which drives a
clean frame immediately after a break condition clears and confirms it is
received correctly.

## 7. Timing (baud generation, sampling, parity/stop timing) -- unchanged core, extended coverage

The core baud-timing derivation from phase 1 is unchanged and still
applies in full:

- `CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE` (integer division).
- Example: 50 MHz clock, 115200 baud target: `CLKS_PER_BIT = 434`
  (truncated from 434.027), giving an actual baud rate of 115207.4 and an
  error of **+0.0064%** -- calculated, not hand-waved, and negligible
  next to the ~1-2% tolerance typical UART receivers accept. This
  project's simulation testbenches deliberately use small, round
  parameters (`CLKS_PER_BIT=10`) purely for fast, easy-to-inspect
  simulation; the RTL does not depend on that value being small or round
  (see `docs/verification.md` for the separate check against the
  realistic 50 MHz/115200 configuration).
- `uart_tx`'s `baud_restart`/`baud_gen`'s `tick` handshake is
  combinational (not registered) on both ends specifically so that every
  bit period -- start, data, **and now parity**, and stop -- is exactly
  `CLKS_PER_BIT` cycles wide with zero extra latency. (An earlier version
  with a registered `tick` produced an 11-cycle start bit instead of 10;
  see `docs/verification.md`'s "lessons learned" for how that was found.)
  This applies identically to the new PARITY bit: it is just one more
  state in the same tick-driven sequence, so it inherits the same exact
  timing guarantee with no special-casing needed.
- `uart_rx` derives all of its timing -- including, now, the parity bit's
  sample point -- from its own locally-detected start-bit edge, using the
  half-bit-then-full-bit ladder: half a bit period to the start bit's
  center (validating it's real, not a glitch), then one full bit period
  per subsequent field (data bit 0, data bit 1, ..., data bit 7,
  **parity bit if enabled**, stop bit), each sampled at its own center.
  The parity bit's sample point is therefore automatically correct with
  no additional logic beyond "one more full-bit wait, one more state" --
  it is architecturally just another field in the same sequence as the
  data bits, sampled the same way.
- The 2-flip-flop input synchronizer (`rx_sync1`/`rx_sync2`) is unchanged.
  See Section 8 for an expanded discussion of what it does and does not
  guarantee.

## 8. Asynchronous RX input and metastability, discussed honestly

`rx` is, in general, an external asynchronous signal relative to this
design's clock domain -- even in the loopback testbench, `uart_rx`
treats it as such, which is the right habit for RTL meant to be reused
with a real off-chip UART line.

**Why a synchronizer is needed:** if an asynchronous input happens to
change value at almost exactly the moment a flip-flop's clock edge
samples it, the flop can enter a *metastable* state -- an unresolved
voltage between valid `0` and valid `1` for longer than a normal
propagation delay. If that metastable value is read by downstream logic
before it resolves, it can be interpreted differently by different gates,
producing internally inconsistent, undefined behavior -- not just "the
wrong bit," but potentially a corrupted FSM state.

**What the two-flop synchronizer does:** the first flop (`rx_sync1`) is
the one directly exposed to the metastability risk. Its output is not
used directly; it feeds a *second* flop (`rx_sync2`), giving the first
flop's output a full clock period to resolve to a stable value before
anything downstream reads it. All of `uart_rx`'s FSM logic operates on
`rx_sync2` (referred to as `rx_s` throughout the RTL and this document),
never on the raw `rx` pin or on `rx_sync1`.

**What this does *not* guarantee, stated honestly:** a two-flop
synchronizer does not make metastability impossible. It reduces the
*probability* that a metastable event propagates to something usably
small -- a function of clock frequency, the flip-flop's specific
metastability characteristics (MTBF, mean time between failures), and how
many synchronizer stages are used. It does not reduce that probability to
zero. For UART-rate signals (kilohertz to low megahertz) synchronized
into typical digital logic clock domains (tens of MHz and up), a two-flop
synchronizer's residual failure rate is standard industry practice and
overwhelmingly unlikely to matter in practice -- but "overwhelmingly
unlikely" is a probabilistic claim, not a proof of correctness, and a
design with a much higher clock-to-signal frequency ratio or tighter
reliability requirements might reasonably use three or more stages, or a
purpose-built metastability-hardened cell library, instead. This project
uses two stages because that is the standard, well-understood baseline
tradeoff for this class of design, not because two stages are a
guarantee.

## 9. Error semantics: the complete behavioral table

This table specifies exactly what happens for every scenario the
assignment calls out, so none of it is left implicit.

| # | Scenario                                  | `rx_data`                        | `rx_valid` | `parity_error` | `framing_error` | `break_detected` | Receiver state after |
|---|--------------------------------------------|-----------------------------------|:----------:|:--------------:|:----------------:|:-----------------:|------------------------|
| 1 | Valid byte, no error                       | updated to received byte           | pulse (1 cyc) | 0            | 0                 | 0                  | `S_IDLE` |
| 2 | Valid byte, parity error                   | updated to received byte (unreliable) | 0       | pulse (1 cyc) | 0                 | 0                  | `S_IDLE` |
| 3 | Valid byte, framing error (bad stop)       | updated to received byte (unreliable) | 0       | 0            | pulse (1 cyc)      | 0                  | `S_IDLE` |
| 4 | Break detected                              | **not** updated (no coherent byte)  | 0       | 0            | 0 (see 6.1 for the one leading framing_error that precedes this, from the frame that necessarily completes first) | level 1, for the duration of the low condition | `S_BREAK`, then `S_IDLE` once `rx` returns high |
| 5 | Parity error AND framing error, same frame | updated to received byte (unreliable) | 0    | pulse (1 cyc) | pulse (1 cyc), same cycle | 0            | `S_IDLE` |
| 6 | `reset` asserted during reception           | cleared to `0` (reset value)        | 0       | 0            | 0                 | 0                  | `S_IDLE`; in-progress frame silently abandoned, no pulses of any kind |
| 7 | `reset` asserted during transmission        | (TX has no rx_data; `tx` returns to idle-high, `tx_busy` clears) | -- | -- | -- | -- | TX: `S_IDLE`; in-progress frame silently abandoned, no `tx_done` pulse |

All seven rows are directly exercised by named tests in
`tb/uart_rx_tb.v` and `tb/uart_tb.v` -- see `docs/verification.md`'s test
inventory for exactly which test covers which row.

## 10. Design decisions and alternatives considered (phase 2 additions)

- **Discrete error signals (`parity_error`/`framing_error`/`break_detected`)
  plus a convenience `rx_status` bus, rather than only a bus.** A bus-only
  interface saves a few top-level pins but forces every consumer to know
  the encoding to do anything useful; discrete signals are self-
  documenting and directly usable in an `if` statement or a waveform
  viewer without a lookup table. The bus is provided *in addition*,
  purely combinationally (no extra registers), for anyone who would
  rather route one 3-bit signal than three 1-bit ones.
- **`rx_data` updated on every completed frame regardless of error,
  rather than held/frozen on error.** The alternative -- only updating
  `rx_data` on a clean frame -- would mean a caller inspecting `rx_data`
  after a `framing_error` sees stale data from the *previous* good frame,
  which is more likely to mislead a debugging engineer than showing them
  what was actually captured (flagged as unreliable via the side-band
  error signal). This is a judgment call, explained here rather than left
  implicit, and a FIFO-based future phase could reasonably revisit it.
- **Silent glitch filtering (no dedicated error output for a
  sub-half-bit-period low pulse).** The three error signals this phase
  asks for -- parity, framing, break -- are all about a byte-or-longer
  scale event. A glitch shorter than half a bit period never becomes a
  byte attempt in the first place (it's rejected during start-bit
  validation, before any data bits are ever sampled), so classifying it
  under any of those three would be misleading. It is documented here and
  in the RTL comments as a deliberate, silent design choice, not an
  oversight.
- **Break threshold as a parameter with a computed default, not a fixed
  constant.** Exposing it lets a testbench (or an unusual real-world
  deployment) reach corner cases -- "exactly at the threshold" -- without
  editing `uart_rx.v`, while the computed default means an ordinary user
  of this module never has to think about it or risk getting it wrong.
- **One shared `reset` for TX and RX, rather than independent resets.**
  The assignment's test list asks for "reset during TX" and "reset during
  RX" as separate categories; with a single shared reset (matching the
  existing top-level interface from phase 1, which this phase did not
  redesign), both happen simultaneously in the loopback testbench. This
  is documented explicitly in `tb/uart_tb.v`'s reset test rather than
  silently treating the two categories as identical, and independent
  reset domains are noted as a possible future improvement in
  `docs/verification.md` if a use case ever needs them.
