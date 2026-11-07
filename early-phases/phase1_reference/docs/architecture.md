# UART Architecture

## 1. Overview

This project implements an 8-bit, no-parity UART (8-N-1) as four small,
single-responsibility Verilog modules, integrated by one top-level module,
and verified by a self-checking loopback testbench plus two standalone
unit testbenches.

```
                +-------------------------------------------------+
                |                     uart.v                      |
                |                                                 |
  tx_data[7:0]->|                                                 |
  tx_start ---->|   +-----------+        +---------+              |
                |   | baud_gen  |--tick->|  uart_tx |--tx--------->|---> tx (pin)
                |   | (CLKS_PER |<-------|          |              |
                |   |   _BIT)   |restart |           |--tx_busy--->|---> tx_busy
                |   +-----------+        +---------+---tx_done---->|---> tx_done
                |                                                 |
   rx (pin) --->|--rx-->  +-----------+                            |
                |         |  uart_rx  |--rx_data[7:0]------------->|---> rx_data
                |         | (CLKS_PER |--rx_valid------------------>|---> rx_valid
                |         |   _BIT)   |--rx_busy-------------------->|---> rx_busy
                |         +-----------+--rx_error------------------->|---> rx_error
                +-------------------------------------------------+
```

`uart_tx` and `uart_rx` never talk to each other directly and share no
internal state. The only thing that connects them, in the real world, is
the serial wire -- exactly as with two independent physical UART chips.
The testbench is what wires `tx` to `rx` to exercise them together
(loopback); that wiring is not something the RTL itself assumes.

## 2. Module inventory

| Module      | File            | Responsibility                                             |
|-------------|-----------------|-------------------------------------------------------------|
| `baud_gen`  | `rtl/baud_gen.v`| Produces a `tick` pulse once every `CLKS_PER_BIT` system clocks, restartable so a new UART frame always starts in phase. |
| `uart_tx`   | `rtl/uart_tx.v` | Serializes one byte: start bit, 8 data bits (LSB first), stop bit. |
| `uart_rx`   | `rtl/uart_rx.v` | Deserializes one byte from the `rx` line, sampling each bit at its center; validates start/stop bits. |
| `uart`      | `rtl/uart.v`    | Top-level integration: computes `CLKS_PER_BIT`, instantiates the three modules above, exposes a clean external interface. |

Testbenches:

| File                  | Purpose                                                        |
|-----------------------|------------------------------------------------------------------|
| `tb/uart_tasks.v`     | Shared tasks (`send_byte`, `wait_for_tx_and_rx`, `check_byte`, `check_cond`, `print_summary`), included by every testbench. |
| `tb/uart_tb.v`        | Top-level, self-checking **loopback** testbench (`tx` wired to `rx`). Also inspects the raw serial line for protocol-level correctness. |
| `tb/uart_tx_tb.v`     | Unit test for `uart_tx` + `baud_gen` alone, checking the line waveform directly. |
| `tb/uart_rx_tb.v`     | Unit test for `uart_rx` alone; bit-bangs hand-built frames (including malformed ones) directly onto `rx`. |

## 3. Interfaces

### 3.1 `uart` (top level)

```verilog
module uart #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BAUD_RATE   = 115200
) (
    input  wire       clk,
    input  wire       reset,      // synchronous, active-high

    input  wire [7:0] tx_data,
    input  wire       tx_start,
    output wire        tx_busy,
    output wire        tx_done,

    output wire [7:0] rx_data,
    output wire        rx_valid,
    output wire        rx_busy,
    output wire        rx_error,

    output wire        tx,
    input  wire        rx
);
```

- `tx_start` is a **1-cycle pulse**. Pulsing it while `tx_busy` is high is
  safely ignored (the module only reacts to `tx_start` while idle).
- `tx_done` is a **1-cycle pulse** the cycle the stop bit finishes.
- `rx_valid` is a **1-cycle pulse** the cycle a byte is fully validated;
  `rx_data` is guaranteed stable from that point until the next byte
  completes.
- `rx_error` is a **1-cycle pulse** indicating either a bad stop bit
  (framing error) or a start-bit condition that turned out to be a glitch.

### 3.2 `uart_tx`

```verilog
module uart_tx (
    input  wire       clk,
    input  wire       reset,
    input  wire       tx_start,
    input  wire [7:0] tx_data,
    input  wire       baud_tick,
    output wire       baud_restart,
    output reg        tx,
    output reg        tx_busy,
    output reg        tx_done
);
```

`baud_tick`/`baud_restart` are the handshake with `baud_gen` (see Section
5). A larger system could also drive `uart_tx` from its own dedicated
`baud_gen` instance if independent TX/RX clock domains were ever needed;
nothing in `uart_tx` assumes it is sharing a divider with `uart_rx` (in
fact, in this design, it doesn't -- see Section 5).

### 3.3 `uart_rx`

```verilog
module uart_rx #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       rx,
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    output reg        rx_busy,
    output reg        rx_error
);
```

Unlike `uart_tx`, `uart_rx` does **not** take a `baud_tick` input. It
derives its own timing entirely from watching the `rx` line (see Section
5.3) -- this is intentional and mirrors how real, independent UART
transceivers work.

## 4. FSMs

### 4.1 `uart_tx`: 4 states

```
            tx_start
   +------+ (& not busy) +--------+  baud_tick   +-------+  baud_tick   +--------+
   | IDLE |------------->| START  |------------->| DATA  |------------->|  STOP  |
   | tx=1 |              | tx=0   |              | tx=   |  (x8 bits)   | tx=1   |
   +------+<-------------+--------+              |shift[i]|<------------+--------+
       ^         baud_tick (after 8th bit,        +-------+   baud_tick
       |          via STOP)                                  (tx_done pulse)
       +--------------------------------------------------------------------+
```

- **IDLE**: drives `tx = 1`. The only state that looks at `tx_start`.
  On `tx_start`, latches `tx_data` into an internal shift register,
  immediately drives the start bit (`tx <= 0`), asserts `tx_busy`, and
  pulses `baud_restart` (same cycle -- see Section 5.2).
- **START**: holds the start bit for one full bit period (`baud_tick`),
  then moves to DATA and drives the first data bit (`shift_reg[0]`,
  i.e. the LSB).
- **DATA**: on each `baud_tick`, drives the next bit and increments a
  3-bit `bit_index` (0..7). After bit 7, drives the stop bit and moves to
  STOP instead of incrementing again.
- **STOP**: holds the stop bit for one bit period, then returns to IDLE,
  clears `tx_busy`, and pulses `tx_done` for exactly one clock cycle.

### 4.2 `uart_rx`: 4 states

```
              rx_s==0                 (half-bit later)
   +------+  (falling edge) +--------+   rx_s still 0    +-------+
   | IDLE |----------------->| START |------------------->| DATA  |
   +------+                  +--------+   rx_s went 1      +-------+
       ^                         |        (glitch, rx_error)   |
       |                         v                              | (x8 bits,
       |                     (back to IDLE)                     |  full-bit each)
       |                                                        v
       |                                              +-------+  full-bit later
       +----------------------------------------------|  STOP |
              rx_valid (good stop) or rx_error (bad)   +-------+
```

- **IDLE**: watches the synchronized input (`rx_s`) for a `1 -> 0`
  transition, which is treated as the leading edge of a start bit.
- **START**: waits `CLKS_PER_BIT/2` cycles (to the *center* of the start
  bit) then re-checks `rx_s`. Still `0` -> real start bit, proceed. Back
  to `1` -> it was just a glitch; pulse `rx_error` and return to IDLE
  without ever asserting `rx_busy` for a full frame.
- **DATA**: waits a full `CLKS_PER_BIT` cycles per bit and samples `rx_s`
  at each bit's center into `rx_shift[bit_index]`, LSB first, for 8 bits.
- **STOP**: waits one more full bit period, samples `rx_s` at the stop
  bit's center. `1` -> valid frame, latch `rx_data` and pulse `rx_valid`.
  `0` -> framing error, pulse `rx_error` instead.

## 5. Timing, in detail

This section is the one the assignment explicitly asks not to hand-wave,
so it's written out in full.

### 5.1 The basic relationship

```
CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE      (integer division)
```

Every UART bit -- start, each of the 8 data bits, and the stop bit -- is
meant to occupy exactly `1 / BAUD_RATE` seconds on the wire. In a
synchronous design there is no such thing as "1/BAUD_RATE seconds"
directly; there is only "some whole number of clock cycles". That whole
number is `CLKS_PER_BIT`.

Example used throughout the RTL comments: 50 MHz clock, 115200 baud
target:

```
CLKS_PER_BIT = 50,000,000 / 115200 = 434.027...  -> truncates to 434
actual bit period = 434 / 50,000,000 s = 8.68 us
actual baud rate   = 50,000,000 / 434 = 115207.4 baud
error              = (115207.4 - 115200) / 115200 = +0.0064 %
```

That error comes purely from Verilog's integer division truncating the
`.027` remainder. It is small here, but it is not zero, and for other
clock/baud combinations it can be considerably larger -- particularly
when the baud rate doesn't divide the clock cleanly, or when the target
baud rate is a large fraction of the clock frequency (fewer clocks per
bit means each clock's rounding error is a bigger fraction of the bit
period). Real UARTs generally tolerate a percent or two of baud
mismatch before bit errors start appearing, so 0.0064% is a non-issue
in this example, but it's the kind of number that's worth computing for
whatever clock/baud pair a real target actually uses. This design does
not implement fractional (accumulator-based) baud generation -- it isn't
needed for the error levels above, and adding it before it's needed
would violate "don't optimize prematurely." It would be a natural next
step if a specific clock/baud combination produced too much error.

The simulation/testbenches in this project intentionally use
`CLK_FREQ_HZ=1000, BAUD_RATE=100` (`CLKS_PER_BIT=10`) instead of the
50 MHz/115200 baud numbers above, purely to keep simulated time short and
captured waveforms easy to eyeball. **Correctness never depends on the
specific value of `CLKS_PER_BIT`** -- see `sim/realistic_check.v`-style
verification notes below; the same RTL was also exercised with the
literal 50 MHz/115200 values during development.

### 5.2 TX timing: why `baud_restart` exists

`baud_gen` is a free-running divide-by-`CLKS_PER_BIT` counter: left to
itself, it produces a `tick` pulse every `CLKS_PER_BIT` cycles, forever,
starting from whenever `reset` was released. That phase is essentially
random from `uart_tx`'s point of view -- `tx_start` can arrive at any
point in that free-running cycle.

If `uart_tx` simply waited for "the next tick" to end the start bit, the
start bit's actual duration would be anywhere from 1 to `CLKS_PER_BIT`
cycles depending on when `tx_start` happened to arrive -- almost always
*not* a full bit period. Every bit after the start bit would then be a
correct `CLKS_PER_BIT` cycles wide (since those are always tick-to-tick),
but the whole frame would be shifted out of alignment with what a
receiver expects for the start bit specifically, which is exactly the
signal the receiver uses to find the center of every other bit.

The fix used here: `uart_tx` asserts `baud_restart` for exactly one cycle,
combinationally, the same cycle it accepts `tx_start` and begins driving
the start bit. `baud_gen` reloads its counter to 0 on that same edge, so
the very next `tick` -- and thus the start bit's end -- is *exactly*
`CLKS_PER_BIT` cycles later. From there, DATA and STOP simply keep
waiting for the free-running `tick`, which is now phase-locked to this
frame, so every subsequent bit is also exactly `CLKS_PER_BIT` cycles
wide. This was directly verified in simulation by capturing the `tx` pin
sample-by-sample and confirming all 10 segments (start + 8 data + stop)
of a transmitted frame are exactly `CLKS_PER_BIT` samples wide with a
uniform value each (see `tb/uart_tb.v`'s `capture_and_check_frame` task
and `tb/uart_tx_tb.v`).

Both `baud_restart` (from `uart_tx`) and `tick` (from `baud_gen`) are
combinational, not registered, specifically so that this restart-to-tick
relationship has zero extra latency -- a registered pulse anywhere in
that loop would reintroduce an off-by-one-cycle error on exactly the bit
that matters most for receiver alignment (the start bit). This was a real
bug caught during development by the directed simulation described above
(an earlier version with a registered `tick` produced an 11-cycle start
bit instead of 10), which is precisely why it is called out here.

### 5.3 RX timing: how the receiver knows when to sample

`uart_rx` has no `baud_tick` input and shares no clock enable with
`uart_tx`. All it has is the `rx` wire and its own system clock -- exactly
like two independent physical UART chips connected by a single wire, with
no shared timing reference beyond "close enough" clock frequencies. It
has to reconstruct bit timing purely by watching the line:

1. **Idle**: `rx == 1`. The moment a `0` is observed, that is treated as
   the leading edge of a start bit, and a local cycle counter starts from
   zero.
2. **Half a bit later** (`CLKS_PER_BIT / 2` cycles after the edge), the
   counter reaches the *center* of the start bit, and `rx` is checked
   again. Sampling at the center rather than at the edge matters for two
   reasons: it gives margin against a slightly early/late edge (line
   noise, or the couple of cycles of latency the input synchronizer
   adds), and it is, not coincidentally, also where a real transmitter's
   bit value is most stable (transitions happen at bit boundaries, not
   bit centers). If `rx` is still `0`, this was a genuine start bit. If it
   already went back to `1`, it was just a glitch, and the module returns
   to idle (pulsing `rx_error`) without ever committing to receiving a
   full frame.
3. **From the confirmed start-bit center**, the counter is reloaded and
   counts a **full** `CLKS_PER_BIT` cycles to reach the center of data bit
   0, then another full period for bit 1, and so on through bit 7. Each
   bit is sampled and shifted into `rx_shift[bit_index]`, LSB first.
4. **One more full bit period** after bit 7's center lands at the center
   of the stop bit. `rx == 1` there means a well-formed frame:
   `rx_data` is latched and `rx_valid` pulses. `rx == 0` there means a
   framing error (`rx_error` pulses instead, and the malformed byte is
   discarded).

Because every sample point is measured relative to the *locally detected*
start-bit edge -- not to any shared tick -- `uart_rx` tracks whatever
timing `uart_tx` (or any other transmitter on the wire) used, as long as
both sides were configured with the same `CLKS_PER_BIT`. This is what
makes UART "asynchronous": TX and RX don't need a shared clock or a
shared enable signal, only a shared bit rate.

### 5.4 Metastability

`rx` is, in general, an external asynchronous signal -- even in the
loopback testbench, treating it as if it might be asynchronous is the
right habit for code meant to be reused with a real off-chip UART. Before
any logic looks at it, `uart_rx` passes it through a two-flip-flop
synchronizer (`rx_sync1` -> `rx_sync2`). All FSM logic operates on the
synchronized version, `rx_s`, never on the raw `rx` pin. This adds a
small (2-cycle), constant latency between an edge appearing on the wire
and the FSM reacting to it; because that latency is far smaller than
`CLKS_PER_BIT` in any realistic configuration, it does not affect where
bit centers land relative to the frame.

## 6. Important corner cases

- **`tx_start` while busy**: ignored. Only `S_IDLE` reacts to it, so a
  stray or repeated `tx_start` pulse during an in-flight frame cannot
  corrupt it. Verified by `TEST: tx not busy before next send`-style
  checks in `tb/uart_tb.v`, and by the back-to-back burst test, which
  issues each `tx_start` only once the previous frame's `tx_busy` and
  `rx_valid`/`tx_done` have both been observed.
- **Back-to-back frames with no idle gap**: since the stop bit already
  returns the line to `1` (the same level as idle), a new start bit can
  begin on the very next cycle after a stop bit ends with no minimum
  idle time required. `tb/uart_rx_tb.v` drives two frames with zero gap
  between them and confirms both are decoded correctly.
- **False start bit (line glitch shorter than half a bit period)**:
  rejected during `S_START`'s half-bit validation window; produces
  `rx_error`, never `rx_valid`, and never blocks the receiver from
  correctly catching the next real frame. Verified in
  `tb/uart_rx_tb.v`.
- **Bad stop bit (framing error)**: produces `rx_error`, not `rx_valid`;
  the malformed byte is not published on `rx_data`. Verified in
  `tb/uart_rx_tb.v`.
- **`rx_valid` and `tx_done` are not guaranteed to occur in the same
  cycle, or even in a fixed order relative to each other**, because
  `uart_rx`'s timing (edge detection + synchronizer latency + its own
  half/full-bit ladder) is independent of `uart_tx`'s timing (tick-driven
  state machine). The loopback testbench accounts for this explicitly
  (see `wait_for_tx_and_rx` in `tb/uart_tasks.v`, which waits for both
  concurrently rather than one after the other) -- this was in fact
  discovered as a real testbench race during development, described in
  the README's "lessons learned" section, and is worth understanding
  before extending the testbench.
- **Changing `tx_data` while `tx_busy` is high**: harmless. `tx_data` is
  only latched into the internal shift register in `S_IDLE`, so the
  in-flight frame is unaffected; the new value simply becomes visible the
  next time a frame starts.

## 7. Design decisions and alternatives considered

- **Combinational vs. registered `tick`/`baud_restart`**: combinational
  was chosen specifically to keep every bit period, including the start
  bit, at exactly `CLKS_PER_BIT` cycles with no extra pipeline latency.
  The trade-off is a slightly longer combinational path from `uart_tx`'s
  state register through `baud_gen`'s comparator and back into
  `uart_tx`'s next-state logic. At the clock rates typical of UART
  designs (tens of MHz) this is not a timing-closure concern; at very
  high clock rates it could be revisited by adding one cycle of latency
  to both the restart and the tick and compensating for it symmetrically.
- **RX uses its own counter instead of sharing `baud_gen`'s tick**: this
  is not an implementation shortcut, it's the architecturally correct
  choice -- a receiver that depended on the transmitter's tick generator
  would not be a receiver at all, it would just be reading a shared
  register. Real, independent UART transceivers do not share timing.
- **Half-bit start validation instead of accepting the edge immediately**:
  costs half a bit period of extra latency before RX commits to
  receiving a frame, in exchange for rejecting glitches that would
  otherwise be mis-decoded as a full (garbage) byte.
- **Integer, non-fractional baud generation**: simplest correct option
  for this phase; revisit only if a specific target clock/baud pair
  produces unacceptable error (see Section 5.1's error calculation).
- **4-state FSMs for both TX and RX** rather than one state per bit
  (e.g. 10 explicit states): keeps the state count small and the
  `case` statements easy to read, at the cost of needing a small
  `bit_index` counter inside the `DATA` state. This is a very common,
  well-understood trade-off in UART implementations and keeps the design
  easy to extend (e.g. to a parameterizable data-width or optional parity
  bit) without restructuring the FSM.

## 8. Assertions / protocol checking without SystemVerilog

This project intentionally stays in Verilog-2005 (`iverilog -g2005`), so
there are no SystemVerilog `assert` statements anywhere in `rtl/`. The
things an SVA-based environment would typically assert are instead
checked procedurally, in `tb/uart_tb.v`:

- **Bit-width/value correctness** (what an SVA `assert property` with a
  clocking block might check) is done by `capture_and_check_frame`:
  sampling the `tx` line once per system clock for an entire frame into a
  plain array, then checking that each `CLKS_PER_BIT`-wide segment holds
  a single, expected value.
- **Pulse-width correctness** (`tx_done`, `rx_valid` being exactly one
  cycle wide) is checked by reading the signal immediately after the
  cycle it was expected to be high, and confirming it has already
  returned low.
- **Mutual-exclusion / sequencing properties** (e.g. "`tx_busy` must be
  high for the whole frame", "`tx_start` must be ignored while busy") are
  checked by polling the relevant signal every cycle across the interval
  in question, inside a loop, rather than via a temporal assertion
  operator.

This is a standard, portable way to get the same protocol coverage an SVA
environment would give, without introducing SystemVerilog-only syntax
into either the RTL or the testbench.
