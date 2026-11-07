#==============================================================================
# Makefile -- reproducible simulation flow for the UART project.
#
# Targets:
#   make compile      - elaborate all three (four, with vectors) testbenches
#   make sim_tx        - run the TX unit testbench
#   make sim_rx         - run the RX unit testbench (fault injection)
#   make sim_top          - run the top-level loopback testbench
#   make sim_vectors        - run the Python-vector-driven regression
#   make vectors               - (re)generate tb/vectors/random_vectors.txt
#   make regression               - vectors + all four testbenches, one summary
#   make waves TB=uart_tb            - run a testbench with VCD dumping enabled
#   make clean                          - remove build/simulation artifacts
#
# Simulator: this flow targets Icarus Verilog (iverilog/vvp), which is free,
# open-source, and does not require any proprietary license. See README.md
# for notes on adapting these commands to Verilator or a commercial
# simulator if that's what's available in a given environment.
#==============================================================================

IVERILOG   ?= iverilog
VVP        ?= vvp
PYTHON     ?= python3
IFLAGS     := -g2012 -I rtl -I tb

RTL := rtl/baud_gen.v rtl/uart_tx.v rtl/uart_rx.v rtl/uart.v
BUILD_DIR := build

.PHONY: all compile sim_tx sim_rx sim_top sim_vectors vectors regression waves clean help

all: regression

help:
	@echo "Targets: compile sim_tx sim_rx sim_top sim_vectors vectors regression waves clean"

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

#------------------------------------------------------------------------
# Compile (elaborate) each testbench. Each depends only on the RTL it
# actually needs -- uart_tx_tb.v does not need uart_rx.v, and
# uart_rx_tb.v / uart_vectors_tb.v do not need uart_tx.v or baud_gen.v,
# matching the "independently testable modules" design goal.
#------------------------------------------------------------------------
compile: $(BUILD_DIR)/uart_tb.out $(BUILD_DIR)/uart_tx_tb.out $(BUILD_DIR)/uart_rx_tb.out $(BUILD_DIR)/uart_vectors_tb.out

$(BUILD_DIR)/uart_tb.out: $(RTL) tb/uart_tb.v tb/uart_tasks.v rtl/uart_defs.vh | $(BUILD_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(RTL) tb/uart_tb.v

$(BUILD_DIR)/uart_tx_tb.out: rtl/baud_gen.v rtl/uart_tx.v tb/uart_tx_tb.v tb/uart_tasks.v rtl/uart_defs.vh | $(BUILD_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ rtl/baud_gen.v rtl/uart_tx.v tb/uart_tx_tb.v

$(BUILD_DIR)/uart_rx_tb.out: rtl/uart_rx.v tb/uart_rx_tb.v tb/uart_tasks.v rtl/uart_defs.vh | $(BUILD_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ rtl/uart_rx.v tb/uart_rx_tb.v

$(BUILD_DIR)/uart_vectors_tb.out: rtl/uart_rx.v tb/uart_vectors_tb.v tb/uart_tasks.v rtl/uart_defs.vh | $(BUILD_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ rtl/uart_rx.v tb/uart_vectors_tb.v

#------------------------------------------------------------------------
# Run each testbench individually.
#------------------------------------------------------------------------
sim_top: $(BUILD_DIR)/uart_tb.out
	$(VVP) $(BUILD_DIR)/uart_tb.out

sim_tx: $(BUILD_DIR)/uart_tx_tb.out
	$(VVP) $(BUILD_DIR)/uart_tx_tb.out

sim_rx: $(BUILD_DIR)/uart_rx_tb.out
	$(VVP) $(BUILD_DIR)/uart_rx_tb.out

# uart_vectors_tb.v opens "tb/vectors/random_vectors.txt" as a path
# relative to the current working directory, so this (like the vector file
# it reads) is run from the project root, not from inside build/.
sim_vectors: $(BUILD_DIR)/uart_vectors_tb.out vectors
	$(VVP) $(BUILD_DIR)/uart_vectors_tb.out

#------------------------------------------------------------------------
# Regenerate the Python-produced regression vector file. Deterministic
# unless a different seed/count is passed, e.g.:
#   make vectors SEED=999 NVEC=500
#------------------------------------------------------------------------
SEED ?= 12345
NVEC ?= 200

vectors:
	@mkdir -p tb/vectors
	$(PYTHON) scripts/gen_vectors.py $(SEED) $(NVEC) > tb/vectors/random_vectors.txt
	@echo "Wrote tb/vectors/random_vectors.txt ($$(grep -vc '^#' tb/vectors/random_vectors.txt) vectors, seed=$(SEED))"

#------------------------------------------------------------------------
# Full regression: every testbench, one combined report. Non-zero exit
# status if anything failed, so this is CI-friendly.
#------------------------------------------------------------------------
regression: compile vectors
	@echo "=========================================="
	@echo " UART REGRESSION"
	@echo "=========================================="
	@fail=0; \
	for tb in uart_tb uart_tx_tb uart_rx_tb uart_vectors_tb; do \
		echo ""; echo "---- $$tb ----"; \
		$(VVP) $(BUILD_DIR)/$$tb.out | tee $(BUILD_DIR)/$$tb.log | tail -6; \
		grep -q "ALL TESTS PASSED" $(BUILD_DIR)/$$tb.log || fail=1; \
	done; \
	echo ""; echo "=========================================="; \
	if [ $$fail -eq 0 ]; then \
		echo " REGRESSION RESULT: ALL SUITES PASSED"; \
	else \
		echo " REGRESSION RESULT: *** AT LEAST ONE SUITE FAILED ***"; \
	fi; \
	echo "=========================================="; \
	exit $$fail

#------------------------------------------------------------------------
# Re-run a single testbench with VCD waveform dumping enabled, e.g.:
#   make waves TB=uart_rx_tb
# Requires the testbench to have a $dumpfile/$dumpvars pair guarded by
# the WAVES macro (see tb/*.v); output lands in build/<TB>.vcd.
#------------------------------------------------------------------------
TB ?= uart_tb

waves: | $(BUILD_DIR)
	$(IVERILOG) $(IFLAGS) -DWAVES -o $(BUILD_DIR)/$(TB)_waves.out $(RTL) tb/$(TB).v
	$(VVP) $(BUILD_DIR)/$(TB)_waves.out
	@echo "Waveform written to $(TB).vcd -- open with: gtkwave $(TB).vcd"

clean:
	rm -rf $(BUILD_DIR)
