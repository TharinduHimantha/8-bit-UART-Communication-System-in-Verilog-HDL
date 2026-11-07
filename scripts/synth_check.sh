#!/usr/bin/env bash
# synth_check.sh -- runs a real Yosys synthesis pass over the RTL, targeting
# a generic technology library, purely to verify:
#   - the RTL elaborates and synthesizes cleanly under a real synthesis
#     tool (not just simulated)
#   - no unintended latches are inferred (checked explicitly below)
#   - a basic cell/area count is available for a sanity check
#
# This is NOT a timing-closure or ASIC/FPGA tape-out flow -- see
# docs/architecture.md "Known limitations" for what this script does and
# does not prove. It uses Yosys's generic `synth` pass (technology-
# independent techmap + generic gate mapping), which is sufficient to
# validate synthesizability and latch-inference without committing to any
# specific FPGA family or ASIC standard-cell library.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build

yosys -p "
    read_verilog -I rtl rtl/uart_defs.vh rtl/baud_gen.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart_fifo.v rtl/uart_regs.v rtl/uart_irq.v rtl/uart_top.v
    hierarchy -check -top uart_top
    proc
    opt
    synth -top uart_top
    stat
    check -assert
" 2>&1 | tee build/synth_check.log

echo ""
echo "=========================================="
if grep -qi "^Warning: Latch inferred" build/synth_check.log; then
    echo "*** LATCH(ES) INFERRED -- see build/synth_check.log ***"
    exit 1
else
    echo "No latches inferred (checked explicitly, not merely assumed)."
fi
echo "Full synthesis log: build/synth_check.log"
echo "=========================================="
