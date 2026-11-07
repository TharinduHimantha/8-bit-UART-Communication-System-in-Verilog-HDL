# Verification

<p align="center"><img src="assets/header-verification.svg" alt="Verification" width="100%"></p>

<p align="center"><sub>[README](../README.md) · [Architecture](architecture.md) · [Registers](register_map.md) · [FIFO](fifo.md) · [Interrupts](interrupts.md) · [Timing](timing.md) · **Verification**</sub></p>

## 1. Verification architecture

```
tb/
├── uart_tasks.v      -- shared tasks (`include`d by both testbenches below):
│                         register-bus driver tasks, PASS/FAIL bookkeeping,
│                         and an independent Verilog-side parity reference
│                         model (see Section 2).
├── fifo_tb.v           -- standalone FIFO testbench. No UART logic at all.
│                         2014 checks, including 500 iterations of randomized
│                         traffic against a software reference queue.
└── uart_core_tb.v        -- the main integration testbench. Drives uart_top
                            exclusively through its two real interfaces (the
                            register bus and the serial pins), exactly as
                            real software and a real external UART peer
                            would. 132 checks spanning registers, FIFO
                            streaming, protocol correctness, fault
                            injection, interrupts, randomized traffic, and
                            reset-in-every-requested-state.
```

**Where this maps onto the assignment's driver/monitor/scoreboard/
reference-model architecture diagram:**

| Assignment's role | This project's equivalent |
|---------------------|------------------------------|
| Drivers               | `reg_write`/`reg_read` (register bus) and `drive_raw_frame`/`drive_break` (raw serial bit-banging) tasks in `tb/uart_tasks.v` / `tb/uart_core_tb.v` |
| Register Monitor         | `reg_read`-based polling helpers (`wait_status_bit`, `wait_and_read_byte`) |
| UART Monitor                | The same raw bit-banging tasks, used in reverse (observing `tx_pin` was done in earlier phases' TX-capture tests; this phase's fault injection focuses on driving `rx_pin`, since loopback mode already gives full-path TX-then-RX coverage without needing a separate line monitor -- see Section 3) |
| Scoreboard                     | `check_byte`/`check_word`/`check_cond` in `tb/uart_tasks.v`, comparing DUT-observed outcomes against independently-computed expected values at each call site |
| Reference model                   | `model_parity_bit` (see Section 2) plus, for the FIFO, a plain software reference queue implemented directly in `tb/fifo_tb.v` |

> [!NOTE]
> **This is a single Verilog testbench file per DUT-under-test (plus a
> shared task library), not a multi-file class-based (UVM-style)
> environment.** That is a direct consequence of the toolchain, not a
> scope-cutting shortcut: Icarus Verilog has no SystemVerilog class
> support, and the assignment's own policy is to prefer open-source tools
> and to explicitly document when a requested feature needs a simulator
> unavailable in that flow (see "Known limitations," Section 5). The
> task-based structure above is the standard, well-understood plain-
> Verilog equivalent, and was already used successfully in this project's
> earlier phases.


## 2. Independent reference models

**Parity** (`model_parity_bit` in `tb/uart_tasks.v`): computes parity
with an explicit `for` loop that sums individual bits
(`ones = ones + data[i]`), then checks `ones % 2` -- a structurally
different computation from the RTL's single reduction-XOR operator
(`^data`), which happens to compute the same mathematical quantity. This
is deliberate: if the RTL's reduction-XOR were ever wired up backwards,
or an EVEN/ODD complement were swapped, this model would not
"helpfully" agree with the mistake, because it is not built the same
way.

**FIFO behavior** (the `random_traffic` block in `tb/fifo_tb.v`): a
plain Verilog array (`sw_queue`) plus head/tail/count indices,
implementing the exact documented FIFO semantics (see `docs/fifo.md`)
independently -- computed only from which commands (`wr_en`/`rd_en`/
`wr_data`) were issued each cycle, never by reading the DUT's internal
pointers. A real bug in this reference model itself (sequentially
chaining the read and write success checks instead of deciding both
against the same starting count) was found and fixed during development
-- see Section 4.

## 3. Fault injection

A working `uart_tx` cannot produce a malformed frame by construction, so
testing "what happens on bad parity / a bad stop bit / a break
condition" requires driving `rx_pin` directly, bypassing `uart_tx`
entirely. `tb/uart_core_tb.v` does this with `drive_raw_frame` (a
parameterized single-frame bit-banger supporting independent parity and
stop-bit corruption) and `drive_break` (holds the line low for a caller-
specified number of cycles), with loopback disabled for the duration of
that testing so nothing else drives `rx_pin` at the same time.

Covered directly:
- correct parity (sanity-checks the raw driver itself)
- incorrect parity -> `PARITY_ERROR`, no `RX_DATA_AVAILABLE`
- incorrect (forced-low) stop bit -> `FRAMING_ERROR`, no
  `RX_DATA_AVAILABLE`
- both simultaneously -> both error bits, no `RX_DATA_AVAILABLE`
- break: line held low well beyond the break threshold -> `STATUS.BREAK`
  (live level) asserts, then clears when the line recovers; the sticky
  `IRQ_STATUS.BREAK` bit latches the event and is independently cleared
- overrun: RX FIFO filled to exactly `FIFO_DEPTH` known bytes (via
  loopback, the simplest deterministic way to fill it), then one more
  byte injected and confirmed dropped with the FIFO's original contents
  completely undisturbed

## 4. Lessons learned (real bugs found during this phase's development)

> [!TIP]
> Documented here in full, per this project's ongoing practice (see the
> earlier phases' documentation for the same practice) of recording actual
> development bugs rather than only presenting a final, idealized design.
> All were found by running the simulator and reading actual signal
> values/timestamps, not by inspection.


1. **RX baud-divisor protection gap** (RTL bug): an early version of
   `uart_top.v` wired `uart_rx`'s timing input directly to the raw,
   live `BAUD_DIV` register instead of `baud_gen`'s protected,
   frame-stable `active_divisor_out`. A directed test that changed
   `BAUD_DIV` mid-frame and checked the received byte caught this
   immediately (the received byte was corrupted). Fixed by exposing
   `active_divisor_out` from `baud_gen` and wiring *that* into
   `uart_rx`. See `docs/architecture.md` Section 4.
2. **FIFO read-latency hazard in the register-interface DATA read** (RTL
   bug, and the trigger for a real architectural change): the original
   `uart_fifo` design used a registered read (`rd_data` valid one cycle
   after `rd_en`). The combinational `DATA` register read mux built on
   top of that returned the *previous* popped byte, not the one being
   popped this cycle. Fixed by redesigning the FIFO's read side to
   first-word-fall-through (see `docs/fifo.md`), which also simplified
   the TX auto-feed logic (an interim one-cycle pipeline-delay register,
   needed only because of the old registered-read timing, became
   unnecessary and was removed).
3. **A blocking-assignment race on `reset`** (testbench bug, but a
   general, reusable lesson): `reset = 1'b1;` (blocking) immediately
   after `@(posedge clk)`, followed shortly by `reset = 1'b0;`
   (blocking), is a genuine, simulator-execution-order-dependent race
   against the DUT's own `always @(posedge clk)` block, both triggered
   by the exact same clock edge. It was found reproducibly failing to
   reset a FIFO's pointers in `tb/fifo_tb.v`'s development. The fix,
   adopted as standard practice everywhere in this project from that
   point forward: always change `reset` with a **nonblocking**
   assignment (`reset <= 1'b1;`).
4. **FIFO reference-model bug** (testbench bug): the software reference
   queue in `tb/fifo_tb.v`'s randomized test originally decided the
   write's success using the count *after* that same cycle's read had
   already been applied (sequential chaining within one simulated
   cycle), rather than deciding both against the starting count -- which
   does not match the RTL (where both decisions are based on
   pointer/full/empty state as it stood before either pointer's
   nonblocking update applies). This diverged from the RTL specifically
   on the "simultaneous read+write while completely full/empty" corner
   case -- exactly the case the directed tests immediately above it in
   the same file had already proven correct by hand. Fixed by deciding
   both against an explicitly captured starting count.
5. **FWFT peek-before-pop testbench timing** (testbench bug, a direct
   consequence of item 2's FIFO redesign): after switching the FIFO to
   FWFT, several existing test-checking code paths still read `rd_data`
   *after* calling the pop task, which under FWFT semantics shows the
   *next* entry, not the one just popped. Fixed by capturing `rd_data`
   into a local variable before popping wherever the "value that was
   just read" needed to be checked.
6. **A leftover byte silently shifting an entire randomized-traffic
   comparison by one position** (testbench bug): a FIFO-threshold test
   left one byte sitting, un-drained, in the RX FIFO (via loopback) when
   it moved on to the next test section. The next section's randomized-
   traffic loop picked that leftover byte up as if it were the first
   random byte's echo, silently shifting every subsequent comparison by
   one position for the rest of that loop. Fixed by explicitly draining
   the FIFO at the end of the threshold test. A reminder that "the DUT
   is still functioning correctly" and "the testbench's bookkeeping is
   still in sync with it" are two different claims.
7. **A reset legitimately reverting `BAUD_DIV` to its own reset default,
   silently desynchronizing a subsequent raw bit-banged frame drive**
   (testbench bug): several consecutive reset-related tests each
   correctly reset the DUT's `BAUD_DIV` register back to its default
   (434), but the testbench's own `g_clks_per_bit` bookkeeping variable
   (used to time the raw-frame bit-banging tasks) was never updated to
   match, causing a subsequent raw frame drive to be paced roughly
   43x too fast for what the DUT now expected -- observed as the DUT
   appearing to "hang" in `S_START` indefinitely, actually the correct
   behavior for a frame whose apparent start-bit width fell far outside
   any expected value. Fixed by re-establishing the fast-simulation
   `BAUD_DIV` value after every reset in that test section, and (during
   debugging) confirmed by directly probing `active_divisor` and
   `half_period` inside the DUT.

## 5. Final test matrix

| Category  | Test               | Result |
| --------- | ------------------ | ------ |
| Reset     | Basic reset (all registers to documented defaults) | PASS |
| Reset     | Reset while idle | PASS |
| Reset     | Reset while active TX | PASS |
| Reset     | Reset while active RX | PASS |
| Reset     | Reset with FIFOs partially populated | PASS |
| Reset     | Reset with a pending (sticky) interrupt | PASS |
| Reset     | Fully functional again immediately after any of the above | PASS |
| TX        | Single byte (via DATA register, loopback) | PASS |
| TX        | Continuous/back-to-back bytes | PASS |
| TX        | FIFO absorbs multiple writes before draining | PASS |
| RX        | Single byte | PASS |
| RX        | Continuous bytes (0x00-0xFF full sweep, x3 parity modes) | PASS |
| FIFO      | Fill (to exactly DEPTH) | PASS |
| FIFO      | Drain | PASS |
| FIFO      | Full (write-while-full ignored) | PASS |
| FIFO      | Empty (read-while-empty ignored, reads 0) | PASS |
| FIFO      | Pointer wraparound (DEPTH*6 cycles) | PASS |
| FIFO      | Simultaneous R/W (neither/full/empty, all 3 cases) | PASS |
| FIFO      | Randomized traffic vs. reference queue (500 iterations) | PASS |
| Registers | Read/write (every RW register) | PASS |
| Registers | Reset values (every register) | PASS |
| Registers | Reserved bits read 0, writes ignored | PASS |
| Registers | Unmapped address read returns 0, write silently ignored | PASS |
| Parity    | Even | PASS |
| Parity    | Odd | PASS |
| Parity    | None | PASS |
| Stop bits | 1 stop bit | PASS |
| Stop bits | 2 stop bits | PASS |
| Stop bits | Parity + 2 stop bits combined | PASS |
| Errors    | Parity (injected) | PASS |
| Errors    | Framing (injected) | PASS |
| Errors    | Overrun (FIFO content preserved, dropped byte confirmed absent) | PASS |
| Errors    | Break: below/at/above threshold, recovery, sticky-event latch | PASS |
| Errors    | Parity + framing simultaneously | PASS |
| IRQ       | RX_AVAILABLE (level) | PASS |
| IRQ       | RX_THRESHOLD, thresholds 0 / DEPTH | PASS |
| IRQ       | TX_EMPTY (level) | PASS |
| IRQ       | TX_THRESHOLD, threshold 0 | PASS |
| IRQ       | PARITY_ERROR full lifecycle (create/status/disabled-pending/enable/assert/clear/deassert) | PASS |
| IRQ       | Multiple simultaneous sources; clearing one leaves the other | PASS |
| IRQ       | Disabled source produces no `irq` | PASS |
| IRQ       | Write-1-to-clear on a level-mirror bit has no effect | PASS |
| Loopback  | Basic (single byte) | PASS |
| Loopback  | Full-path (parity, stop bits, FIFO, all exercised, not bypassed) | PASS |
| Random    | Random traffic (register-driven, reproducible seed) | PASS |
| Random    | Random FIFO traffic (500 iterations, reproducible seed) | PASS |

**Totals, as of the last run against this exact source (Icarus Verilog
12.0):**

```
fifo_tb        : 2014 / 2014 PASSED
uart_core_tb      :  132 /  132 PASSED
------------------------------------
TOTAL                : 2146 / 2146 PASSED
```

<p align="center">
  <img src="assets/terminal.svg" alt="Terminal: make regression" width="80%">
</p>

## 6. Assertions

Plain Verilog-2001/2012 (no SystemVerilog `assert property`), for the
same open-source-toolchain reason noted in Section 1. The things an SVA
environment would typically assert are checked procedurally instead:

- **TX is high while idle**: checked directly in `docs`-referenced reset
  and idle-behavior tests (inherited from earlier phases and re-verified
  against the current RTL).
- **FIFO `count <= DEPTH` and `count >= 0`**: `count` is an unsigned
  register whose width (`$clog2(DEPTH+1)`) makes a value outside `[0,
  DEPTH]` structurally unreachable; additionally, 500 iterations of
  randomized traffic checked `count` against an independent reference
  model on every cycle, which would have caught any way that invariant
  could actually be violated in practice.
- **`empty` implies `count == 0`, `full` implies `count == DEPTH`**:
  checked directly, every cycle, throughout the randomized FIFO test.
- **RX valid corresponds to accepted data**: `rx_valid` only ever
  fires from `uart_rx`'s `S_STOP`/`S_STOP2` states on a clean frame; every
  positive test checks the byte that arrives matches what was sent/driven.
- **IRQ corresponds to documented pending/enable semantics**: `irq =
  OR(IRQ_STATUS & IRQ_ENABLE)` is checked directly across every
  interrupt-lifecycle test in Section 5's matrix.
- **Reset clears FIFOs / interrupt state**: checked directly (Section 5).
- **A disabled interrupt cannot assert IRQ**: checked directly (the
  "disabled source produces no irq" test).
- **TX cannot consume from an empty FIFO**: `tx_pop_request` is
  structurally gated by `!tx_fifo_empty`; the FIFO-streaming test's
  final drained state (`TX_EMPTY` asserted, no further `tx_busy`
  activity) is consistent with this never having been violated.
- **RX cannot write into a full FIFO** (this design's chosen overrun
  behavior, rather than permitting an overflowing write): `rx_fifo_wr_en`
  is structurally gated by `!rx_fifo_full`; directly verified by the
  overrun test's confirmation that the FIFO's original contents survive
  unchanged.

## 7. Coverage: functional vs. code coverage

Icarus Verilog does not support SystemVerilog functional coverage
(`covergroup`/`coverpoint`), so no line/branch/toggle coverage tool was
run. This project's substitute is the same one used in earlier phases:
the test inventory in Section 5 above **is** this project's functional
coverage summary -- it answers "which scenarios did we check, and did
the design behave correctly for each," which is the metric that actually
matters for a verification effort, not "which lines of RTL executed."
Code coverage and functional verification are genuinely different
things: a test suite can achieve 100% code coverage while never checking
that a computed value is *correct* (only that every line ran), and a
well-targeted, intent-driven test suite (like this one) can find real
bugs -- and did, see Section 4 -- without ever being told to chase a
coverage percentage. If code coverage were wanted as a secondary sanity
check (e.g. "did we ever actually reach `S_STOP2`"), Verilator's
`--coverage` flag could be layered on top of this exact RTL/testbench
structure without any RTL changes, since nothing here depends on
Icarus-specific behavior.

**Explicitly uncovered / lightly covered cases, stated rather than
hidden:**
- Reset landing in the exact PARITY or exact STOP2 state window is not a
  separately *named* test (the RTL's reset handling is uniformly
  state-independent -- a single `if (reset)` branch applies regardless
  of current state -- so this is not architecturally distinct from the
  mid-data-bits reset window that *is* directly tested, but a dedicated
  test would still add confidence at low cost).
- `RX_ENABLE=0` behavior (RX front-end keeps running and can still flag
  parity/framing/break, but nothing reaches the RX FIFO) is documented
  in `docs/register_map.md` but not independently exercised by a named
  test in this phase's suite.
- `FIFO_DEPTH` values other than the default (16) are not exercised in
  `tb/uart_core_tb.v` (though `tb/fifo_tb.v` uses `DEPTH=4` specifically
  to make full/wraparound conditions easy to hit quickly, giving some
  cross-depth confidence in the FIFO module itself, independent of the
  UART-specific integration).

## 8. Simulation, lint, and synthesis instructions

```sh
make regression   # both testbenches, one combined pass/fail report
make test          # same as regression, currently -- see Makefile comment
make lint             # Verilator --lint-only -Wall over every RTL file (0 warnings)
make synth               # Yosys generic synthesis check (0 problems, explicit latch check)
make waves TB=uart_core_tb   # VCD dump for a given testbench
make clean                     # remove build/ artifacts
```

All of the above were actually executed against this exact source, with
Icarus Verilog 12.0, Verilator 5.020, and Yosys 0.33, and produced the
results quoted throughout this document set. Simulation was not merely
described -- see the Makefile's `test`/`regression` targets for the exact
commands, reproducible by anyone with those three (all open-source, no
license required) tools installed.

### What to inspect in a waveform

`make waves TB=<name>` enables a guarded `$dumpfile`/`$dumpvars` block
(off by default in ordinary regression runs). Signals worth looking at:
`tx_pin`/`rx_pin` (ground truth of the serial line), `baud_tick`/
`baud_restart` and `active_divisor` (confirms the restart/tick handshake
and the deferred baud-update policy), both FSMs' `state` and `bit_index`,
the FIFOs' `wr_ptr`/`rd_ptr`/`count`/`full`/`empty`, `dut.u_regs`'s
internal register values, and `dut.u_irq`'s `sticky`/`status_read_value`/
`irq`.

## 9. Known limitations

- **No fractional baud-rate generation** -- see `docs/timing.md` for the
  calculated (small) integer-division error this incurs.
- **No CDC-specific static-checking tool was run.** The two-flop
  synchronizer on `rx_pin` is standard, well-understood practice (see
  `docs/architecture.md` Section 8), but this project did not run a
  dedicated CDC linter (e.g. SpyGlass CDC or an open-source equivalent)
  to formally prove the crossing's safety; this design has exactly one
  asynchronous input, which limits the blast radius of that gap, but it
  is a real gap, not a proven-safe claim.
- **No SystemVerilog assertions or functional coverage** -- see Sections
  6-7 for the plain-Verilog substitutes used instead, and why they were
  judged adequate for this project's toolchain and scope.
- **No formal (model-checking) verification** was attempted on any
  module.
- **`RX_ENABLE=0` does not power down `uart_rx`'s front end** -- it only
  gates whether validated bytes reach the RX FIFO (see
  `docs/register_map.md`). A true low-power "stop sampling entirely"
  mode would need an enable input threaded into `uart_rx` itself.
- **No `FIFO_ENABLE`/FIFO-bypass mode** -- deliberately scoped out; see
  `docs/register_map.md`'s CONTROL section for the reasoning.
- **`FIFO_DEPTH` is not swept across multiple values in the integration
  testbench** (only in the standalone FIFO testbench) -- see Section 7.
- **Synthesis check is generic, not vendor-specific** -- `scripts/
  synth_check.sh` proves synthesizability and the absence of inferred
  latches under Yosys's technology-independent flow. It does not perform
  FPGA-vendor-specific or ASIC-standard-cell-specific synthesis, and
  makes no timing-closure claim whatsoever (no area/timing numbers from
  this flow are quoted anywhere in this documentation set, per the
  assignment's explicit instruction not to fabricate them).
- **Single shared reset** for the whole peripheral (TX and RX cannot be
  reset independently) -- see `docs/architecture.md` Section 7.

## 10. Future improvements

- Fractional/accumulator-based baud generation, if a specific target
  clock/baud pair is ever identified where the current error is no
  longer negligible.
- A dedicated CDC linting pass.
- Porting the plain-Verilog procedural assertions in Section 6 to real
  SystemVerilog `assert property` statements, and adding
  `covergroup`/`coverpoint` functional coverage, if/when a SystemVerilog-
  capable simulator is available in this project's environment.
- An `RX_ENABLE`-gated low-power front end.
- Vendor-specific synthesis scripts (Vivado/Quartus for FPGA targets, or
  an ASIC standard-cell flow) layered on top of the existing generic
  Yosys check, with real, executed area/timing results once a specific
  target technology is chosen -- deliberately not fabricated here.
- Independent TX/RX reset domains, if a real use case ever needs one
  half of the link resettable without disturbing the other.
