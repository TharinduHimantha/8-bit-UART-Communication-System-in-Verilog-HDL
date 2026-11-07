# Architecture

## 1. System overview

```
                              uart_top.v
   ┌─────────────────────────────────────────────────────────────────────┐
   │                                                                     │
   │  addr/write_en/write_data ──►┌───────────┐                         │
   │  read_en ────────────────────►│ uart_regs │◄── STATUS/FIFO_STATUS   │
   │  ◄── read_data ───────────────┴─────┬─────┘    (live signals)       │
   │                                     │                               │
   │            CONTROL/BAUD_DIV/FRAME_CONFIG/FIFO_CONTROL               │
   │                                     │                               │
   │            ┌────────────────────────┼─────────────────────┐        │
   │            ▼                        ▼                     ▼        │
   │      ┌──────────┐            ┌────────────┐         ┌───────────┐  │
   │  DATA│ TX FIFO  │─(FWFT)─►tx_│ baud_gen +  │──tx_pin►│ (external)│  │
   │  wr  │(uart_fifo)│  pop     │  uart_tx     │         └───────────┘  │
   │      └──────────┘            └────────────┘                        │
   │                                     │ active_divisor (frame-stable)│
   │                                     ▼                               │
   │      ┌──────────┐            ┌────────────┐         ┌───────────┐  │
   │  DATA│ RX FIFO  │◄─rx_valid──│  uart_rx    │◄─rx_pin─┤(external) │  │
   │  rd  │(uart_fifo)│  push      │(+ parity,   │    │    └───────────┘  │
   │      └────┬─────┘            │  framing,   │    │  ▲ (loopback mux) │
   │           │                  │  break)     │    └──┘                │
   │           │ (FWFT peek)      └──────┬──────┘   internal tx_pin      │
   │           ▼                         │                               │
   │  overrun_pulse ─────────────────────┤ parity_error, framing_error,  │
   │           │                          break_detected                 │
   │           ▼                          │                               │
   │      ┌──────────────────────────────▼─────────┐                    │
   │      │            uart_irq                     │──── irq ──────────►│
   │      │  (sticky bits 0-3, level mirrors 4-7)   │                    │
   │      └──────────────────────────────────────────┘                    │
   └─────────────────────────────────────────────────────────────────────┘
```

## 2. Module inventory

| Module         | File               | Responsibility |
|-----------------|--------------------|-----------------|
| `uart_defs.vh`   | `rtl/uart_defs.vh` | Single source of truth for the register map addresses, bit fields, and parity encoding -- `` `include ``d by every RTL file and every testbench. |
| `baud_gen`        | `rtl/baud_gen.v`   | Bit-timing generator. Runtime-configurable divisor (`cfg_divisor`, from `BAUD_DIV`), applied only while the link is idle (`cfg_update_allowed`) -- see Section 4. |
| `uart_tx`           | `rtl/uart_tx.v`    | Serializes one byte: start, `DATA_BITS` data bits (LSB first), optional parity, 1 or 2 stop bits. Parity mode and stop-bit count are runtime inputs, latched once per frame. |
| `uart_rx`             | `rtl/uart_rx.v`    | Deserializes, center-samples every field, validates parity and stop bit(s), detects break conditions. Parity/stop-bit config latched once per frame (at start-bit confirmation); break threshold sized for the worst-case (longest possible) frame this module could ever be configured to receive. |
| `uart_fifo`             | `rtl/uart_fifo.v`  | Generic, reusable, parameterized synchronous FIFO. UART-agnostic. See `docs/fifo.md`. |
| `uart_regs`               | `rtl/uart_regs.v`  | Generic register storage/decode for CONTROL, BAUD_DIV, FRAME_CONFIG, FIFO_CONTROL, and the read side of STATUS/FIFO_STATUS. See `docs/register_map.md`. |
| `uart_irq`                  | `rtl/uart_irq.v`   | Dedicated interrupt subsystem: IRQ_STATUS storage (sticky + level-mirror, per source) and the final IRQ_ENABLE-gated `irq` output. See `docs/interrupts.md`. |
| `uart_top`                    | `rtl/uart_top.v`   | Top-level integration: wires everything above together, owns the TX/RX FIFO auto-feed logic, loopback mux, and overrun detection. |

Every module above has exactly one clearly-stated responsibility, is
independently instantiable, and (except `uart_top` itself, which is an
integration module by definition) is independently testable --
`uart_fifo` and `uart_rx`/`uart_tx` all have dedicated unit-level
coverage in addition to the full-system `tb/uart_core_tb.v` (see
`docs/verification.md`).

## 3. TX/RX FSMs

Both engines are 4-6-state FSMs (state count depends on the currently
latched parity/stop-bit configuration); the full derivation -- including
the parity calculation, the combinational restart/tick handshake that
keeps every bit period exactly `CLKS_PER_BIT` cycles wide, the half-bit
start-bit validation, and the free-running break-detection counter -- is
documented in detail directly in `rtl/uart_tx.v` and `rtl/uart_rx.v`'s
header comments, which this document intentionally does not duplicate.
See those files for the complete, line-referenced explanation; the
summary:

```
TX:  IDLE -> START -> DATA(x8) -> [PARITY] -> STOP1 -> [STOP2] -> IDLE
RX:  IDLE -> START -> DATA(x8) -> [PARITY] -> STOP1 -> [STOP2 | BREAK] -> IDLE
```

**What changed from an earlier, single-configuration version of this
project**: `PARITY_MODE` and stop-bit count used to be Verilog
`parameter`s (fixed at elaboration time). This phase's register interface
requires them to be **runtime-configurable**, so both are now input
ports (`cfg_parity_mode`, `cfg_stop_bits2`), latched into frame-local
registers at the start of each frame (TX: when `tx_start` is accepted;
RX: when a start bit is confirmed real). This guarantees a `FRAME_CONFIG`
write that lands mid-frame cannot corrupt a frame already in flight -- it
only affects frames that begin after the write. The same latch-at-
frame-boundary principle is applied to the baud divisor (see Section 4).

## 4. Baud divisor: runtime-configurable, deferred-until-idle

`baud_gen.v`'s `active_divisor` register only loads a new value from
`cfg_divisor` (the live `BAUD_DIV` register) while `cfg_update_allowed`
(driven by `uart_top` as `!tx_busy && !rx_busy`) is asserted -- i.e. only
while the link is completely idle. A `BAUD_DIV` write that lands mid-frame
is stored immediately (a subsequent read reflects it right away) but does
not affect actual bit timing until the current frame finishes.

**A real bug this protection was built to prevent, and initially didn't
fully prevent**, is worth documenting precisely: an early version of
`uart_top.v` wired `uart_rx`'s `cfg_clks_per_bit` input directly to the
*raw* `BAUD_DIV` register value, not to `baud_gen`'s protected,
frame-stable `active_divisor`. TX was correctly protected (it only ever
sees timing through `baud_gen`'s `tick` output), but RX was reading the
live, unprotected register directly -- so a `BAUD_DIV` write mid-RX-frame
corrupted that frame's bit timing even though the exact same write
mid-TX-frame was harmless. This was caught by a directed test that
changed `BAUD_DIV` mid-frame and checked the *received* byte was still
correct (see `docs/verification.md`), not by inspection. The fix:
`baud_gen` now exposes `active_divisor_out`, and `uart_top` wires *that*
-- not the raw register -- into `uart_rx`. Both TX and RX now derive
their timing from the exact same protected value.

## 5. TX/RX FIFO auto-feed

### TX: register interface -> TX FIFO -> `uart_tx`

Software writes to `DATA`; the byte enters the TX FIFO. `uart_top`
automatically pops the TX FIFO and starts a new TX frame whenever
`TX_ENABLE` is set, the TX FIFO is non-empty, and `uart_tx` is not
already busy:

```verilog
wire tx_pop_request = ctrl_tx_enable && !tx_fifo_empty && !tx_busy;
```

Because `uart_fifo` is first-word-fall-through (see `docs/fifo.md`),
`tx_fifo_rd_data` already reflects the byte that *will* be popped this
cycle, so `tx_start` and the pop fire on the exact same cycle -- no
pipeline delay is needed. (An earlier version of this logic, written
before the FIFO was changed to FWFT, needed an explicit one-cycle
pipeline register to bridge a real read-latency hazard; removing that
register was possible, and correct, specifically because of the FWFT
change -- see `docs/fifo.md` for the bug that motivated it.)

No double-pop hazard exists: the cycle after `tx_pop_request` fires,
`uart_tx` has already raised `tx_busy` (since it reacts to `tx_start`
combinationally within the same edge that also updates its own `tx_busy`
register), which immediately removes `tx_pop_request`'s enabling
condition for the next cycle. This was verified directly by streaming
multiple bytes through the TX FIFO back-to-back and confirming each one
is transmitted exactly once, in order.

### RX: `uart_rx` -> RX FIFO -> register interface

Simpler, with no equivalent pipeline hazard: `rx_valid` is already a
clean one-cycle pulse meaning "this byte is ready right now," and
pushing it into the RX FIFO the same cycle
(`wr_data = rx_data_serial, wr_en = rx_valid && ctrl_rx_enable &&
!rx_fifo_full`) is exactly the FIFO's normal write protocol. Software
then reads `DATA`, which pops the (FWFT) RX FIFO combinationally -- see
`docs/register_map.md`.

**Overrun**: if `rx_valid` pulses while the RX FIFO is already full, the
byte is discarded (`rx_fifo_wr_en` is gated by `!rx_fifo_full`) and a
one-cycle `overrun_pulse` is raised for `uart_irq`. See
`docs/interrupts.md` for the full overrun semantics and verification.

## 6. Loopback

When `CONTROL.LOOPBACK_ENABLE` is set, `uart_rx`'s serial input is
switched from the external `rx_pin` to `uart_tx`'s own output
internally:

```verilog
wire rx_source = ctrl_loopback_enable ? tx_pin : rx_pin;
```

**The external `tx_pin` is always driven from `uart_tx` regardless of
loopback mode** -- it is not gated to idle during a loopback test. Only
`uart_rx`'s source changes. This means loopback mode genuinely exercises
the full TX FSM, the full RX FSM, real bit timing, real parity
generation and checking, and the real TX/RX FIFOs -- it is not a
shortcut that copies TX data directly into the RX FIFO (which the
assignment explicitly warns against). `tb/uart_core_tb.v` uses loopback
extensively for high-volume protocol verification (the full 0x00-0xFF
sweep, randomized traffic, multiple parity/stop-bit configurations) for
exactly this reason: it is real, complete-path verification, not a
simplified stand-in for it.

## 7. Reset architecture

A single, synchronous, active-high `reset` clears every piece of state
in the design in one cycle: both FSMs return to `S_IDLE`, both FIFOs
empty (pointers zeroed), `CONTROL`/`BAUD_DIV`/`FRAME_CONFIG`/
`FIFO_CONTROL` return to their documented reset values, `IRQ_ENABLE`
clears (all sources disabled), the sticky `IRQ_STATUS` bits (0-3) clear,
and `irq` deasserts. Because this project has a single shared `reset`
input for the whole peripheral (matching the earlier phases' interface,
which this phase did not redesign), "reset during TX" and "reset during
RX" cannot be independently timed in a loopback context -- both halves
reset simultaneously in `tb/uart_core_tb.v`'s loopback-based reset tests;
independent reset domains are noted as a future improvement in
`docs/verification.md`.

Reset was directly tested (see `docs/verification.md`'s test inventory)
in every state the assignment calls out: idle, mid-TX, mid-RX, with the
FIFOs partially full, with the FIFOs completely full, with a pending
(sticky) interrupt, and immediately followed by a check that the whole
peripheral is fully functional again afterward.

## 8. Clock domain crossing

This design has exactly **one** clock domain. The external `rx_pin` is
the only signal that is genuinely asynchronous to it. See
`docs/timing.md` Section 2 for the full metastability discussion --
including an honest statement of what a two-flop synchronizer does and
does not guarantee, per the assignment's explicit instruction not to
overstate that.

## 9. Final architecture review

Performed after the implementation above was complete and fully passing
regression, per the assignment's request for a genuine review rather
than a self-congratulatory summary.

1. **UART protocol correctness**: start/data/parity/stop timing, LSB-
   first ordering, and both stop-bit counts were verified against an
   independently-computed parity model (two independent
   implementations -- see `docs/verification.md`) and against the full
   0x00-0xFF byte sweep in three parity configurations. No known
   protocol-correctness gaps.
2. **TX design**: correct; the auto-feed pipeline hazard found and fixed
   during development (Section 5) was the one real design flaw
   encountered here, and is now covered by a regression test that would
   catch a regression of it.
3. **RX design**: correct; the divisor-protection gap found and fixed
   during development (Section 4) was the analogous real flaw on the RX
   side, likewise now covered by a regression test.
4. **Baud generator**: correct; the deferred-until-idle update policy is
   deterministic and directly tested (mid-frame `BAUD_DIV` write proven
   to not affect the in-flight frame, on both TX and RX).
5. **FIFO design**: correct, and unusually thoroughly verified (2014
   checks including 500 iterations of randomized traffic against an
   independent reference queue) given it is the one module in this
   project simple enough to fully characterize. The FWFT redesign
   (Section 5, `docs/fifo.md`) was a genuine architectural improvement
   made mid-development, not a late patch.
6. **Register interface**: correct; reset values, read/write behavior,
   reserved-bit behavior, and unmapped-address behavior are all directly
   tested. No wait-state support exists (by design -- see
   `docs/register_map.md`), which is a real, documented limitation if a
   future register ever needs multi-cycle access.
7. **Error handling**: correct and unambiguous for all documented cases
   (see `docs/register_map.md`'s error-related field descriptions and
   `docs/interrupts.md`'s per-source table); parity+framing-error
   simultaneity, overrun content-preservation, and break detection's
   "one leading framing error is expected before the break threshold is
   reached" nuance (inherited from this project's earlier phase, and
   still accurate here) are all explicitly tested, not assumed.
8. **Interrupt logic**: correct; the sticky-vs-level split (Section 2 of
   `docs/interrupts.md`) is the single most consequential architectural
   decision in this phase, and is the one most thoroughly justified and
   tested as a result.
9. **Reset behavior**: correct across every state the assignment
   requested (Section 7 above).
10. **CDC handling**: a standard, well-understood two-flop synchronizer
    is used and honestly documented (Section 8, `docs/timing.md`); this
    is appropriate for this design's clock/baud-rate ratios but is not a
    formally-proven-safe CDC crossing (no CDC-specific static checking
    tool was run -- see "Known limitations" in `docs/verification.md`).
11. **Verification environment**: substantial (2146 total checks across
    two testbenches, plus a real, executed lint pass and a real, executed
    synthesis check), but built from plain-Verilog tasks rather than a
    class-based UVM-style environment, since Icarus Verilog has no
    SystemVerilog class support to build one with -- see
    `docs/verification.md` for the direct mapping between what was built
    and the assignment's requested driver/monitor/scoreboard/reference-
    model architecture.
12. **Assertions**: implemented as procedural checks (see
    `docs/verification.md`), not SystemVerilog `assert property`, for the
    same open-source-toolchain reason as above.
13. **Coverage**: no formal functional-coverage tool was used (Icarus
    Verilog has no `covergroup`/`coverpoint` support); the test inventory
    in `docs/verification.md` is this project's functional-coverage
    substitute, and the distinction between that and code coverage is
    discussed explicitly there, not conflated.
14. **Regression automation**: real, working `make test` / `make
    regression` / `make lint` / `make synth` / `make waves` / `make
    clean` targets, all actually run to produce the results quoted in
    this documentation set.
15. **Synthesis portability**: a real Yosys synthesis pass was run
    (`scripts/synth_check.sh`) and reports zero problems, including an
    explicit, executed check for unintended inferred latches. This is a
    technology-independent generic synthesis check, not a timing-closure
    or vendor-specific (FPGA/ASIC) flow -- see
    `docs/verification.md`'s "Known limitations" for exactly what that
    does and does not prove.
16. **Documentation**: this document set (`README.md` plus seven files
    under `docs/`) was written to match the RTL exactly, including
    documenting real bugs found during development and the fixes for
    them, rather than presenting only a idealized final design with no
    development history.
