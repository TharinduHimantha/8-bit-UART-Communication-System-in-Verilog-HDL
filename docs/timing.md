# Timing and Performance Analysis

This document covers bit-level timing (baud generation, sampling,
metastability) and system-level performance (throughput, latency,
buffering capacity), all calculated from this project's actual design
parameters -- not invented numbers.

## 1. Baud generation

Unlike earlier phases of this project, `CLK_FREQ_HZ` and `BAUD_RATE` are
not RTL parameters here. Because `BAUD_DIV` (see `docs/register_map.md`)
is a runtime register, software computes the divisor itself:

```
CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE      (integer division, done in software)
```

and writes the result directly. There is no on-chip divider.

**Worked example** (50 MHz system clock, 115200 baud target -- the
values `BAUD_DIV`'s reset default, `434`, corresponds to, chosen so the
peripheral is usable at a common baud rate out of reset without any
configuration):

```
CLKS_PER_BIT = 50,000,000 / 115200 = 434.027...  -> truncates to 434
actual bit period = 434 / 50,000,000 s = 8.68 us
actual baud rate   = 50,000,000 / 434 = 115207.4 baud
error              = (115207.4 - 115200) / 115200 = +0.0064 %
```

This error comes from Verilog's (and software's) integer division
truncating the `.027` remainder. It is negligible here -- real UART
receivers generally tolerate roughly 1-2% of baud mismatch before bit
errors appear -- but it is not zero, and for other clock/baud
combinations (particularly high baud rates relative to the clock, where
each integer step is a larger fraction of the bit period) it can be
considerably larger. This project does not implement fractional
(accumulator-based) baud generation; see `docs/verification.md`'s
"Future improvements" for when that would become worth adding.

## 2. Bit sampling, restart/tick handshake, and metastability

These are unchanged in principle from earlier phases; see
`docs/architecture.md` for the complete derivation (the
restart-then-tick combinational handshake between `uart_tx` and
`baud_gen` that keeps every bit period, including the start bit, exactly
`CLKS_PER_BIT` cycles wide; the half-bit-then-full-bit sampling ladder
`uart_rx` uses to find each bit's center independently, with no shared
clock enable with the transmitter).

**Clock domains**: this design has exactly **one** system clock domain
(`clk`). The external `rx_pin` is the only genuinely asynchronous
signal crossing into that domain; it passes through a 2-flip-flop
synchronizer inside `uart_rx.v` before any logic reads it (see
`docs/architecture.md` for the full metastability discussion, including
the honest statement of what a two-flop synchronizer does and does not
guarantee). There is no second clock domain anywhere in this design --
the register bus, the FIFOs, and both serial engines all run on `clk`.

## 3. Performance analysis

All figures below use the 50 MHz / 115200 baud worked example from
Section 1 (`CLKS_PER_BIT = 434`) unless noted otherwise; the formulas
generalize to any configured `CLKS_PER_BIT`.

### Maximum practical baud rate

Bounded by how small `CLKS_PER_BIT` can be while still giving `uart_rx`
enough resolution to reliably find each bit's center. With a 16-bit
`BAUD_DIV` field, the fastest representable configuration is
`CLKS_PER_BIT = 1` (nonsensical -- no room to sample at all) up through
`CLKS_PER_BIT = 65535`. In practice, a `CLKS_PER_BIT` of at least
~8-16 is advisable so that the half-bit start-bit validation window
(`CLKS_PER_BIT / 2`) still has enough resolution to distinguish a real
start bit from line noise with reasonable margin -- e.g. at 50 MHz,
`CLKS_PER_BIT = 16` corresponds to just over 3 Mbaud. This project's own
simulation testbenches use `CLKS_PER_BIT = 10` for fast, easy-to-inspect
waveforms, which is at the aggressive end of that range but was
extensively verified correct at that setting (see
`docs/verification.md`).

### Baud error

Calculated in Section 1 for the worked example: **+0.0064%** at 50 MHz /
115200 baud. Recompute per-configuration using the formula in Section 1
for any other clock/baud pair.

### TX / RX throughput

Each frame is `1 (start) + 8 (data) + parity_bits(0 or 1) +
stop_bits(1 or 2)` bit periods -- 10 bits for the most common 8-N-1
configuration, up to 12 bits for 8-E-2 (even parity, 2 stop bits).

```
byte_rate = BAUD_RATE / bits_per_frame
```

At 115200 baud, 8-N-1 (10 bits/frame): **11,520 bytes/sec** (~11.5 KB/s).
At 115200 baud, 8-E-2 (12 bits/frame): **9,600 bytes/sec** (~9.4 KB/s).

### FIFO buffering capacity

`FIFO_DEPTH = 16` (default). At 11,520 bytes/sec (8-N-1, 115200 baud), a
full 16-entry RX FIFO represents:

```
16 / 11520 = 1.389 ms
```

of received data software can leave unread before an overrun occurs
(assuming continuous back-to-back reception at maximum rate -- real
traffic with inter-byte gaps gives proportionally more slack). The same
figure applies symmetrically to the TX FIFO's write-ahead capacity
before software would see `TX_FULL`.

### RX latency (line activity to RX FIFO availability)

From the falling edge of a start bit to `rx_valid` (and, the same cycle,
the byte becoming visible via `RX_AVAILABLE`/a `DATA` read):

```
~2 cycles (input synchronizer)
+ CLKS_PER_BIT/2 cycles (start-bit center validation)
+ CLKS_PER_BIT * (8 + parity_bits + stop_bits - 1) cycles (remaining bit centers)
```

At 115200 baud / 8-N-1 (`CLKS_PER_BIT=434`): approximately
`2 + 217 + 434*9 = 4125` cycles, or about **82.5 microseconds** at 50 MHz
-- consistent with (slightly under, due to the half-bit head start) one
full 10-bit frame period, as expected.

### Interrupt latency

Interrupt generation is purely combinational downstream of each source's
own registered update (see `docs/interrupts.md`):

- **Sticky sources** (parity/framing/overrun/break): the `IRQ_STATUS`
  sticky bit latches on the same clock edge the underlying event pulses;
  `irq` is a combinational function of that already-updated register.
  **Latency: 1 clock cycle** from event to `irq` assertion (assuming the
  source is already enabled).
- **Level sources** (RX/TX available/threshold): `irq` is a purely
  combinational function of already-live signals (FIFO counts, empty/full
  flags). **Latency: 0 additional cycles** beyond whatever cycle the
  underlying condition itself became true.

### Register access latency

Per `docs/register_map.md`: writes take effect the cycle they are
issued; reads are combinational (valid the same cycle `addr`/`read_en`
are presented, once the small internal decode settles). **Latency: 0
extra wait-state cycles** for either operation, by design.
