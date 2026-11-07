//==============================================================================
// Module : uart_irq
// Purpose: Dedicated interrupt subsystem. Owns IRQ_STATUS storage and the
//          final IRQ_ENABLE-gated `irq` output. Deliberately the ONLY place
//          in this project that decides "should the irq pin be asserted" --
//          see docs/interrupts.md for why interrupt generation is
//          centralized here rather than scattered across uart_tx.v/
//          uart_rx.v/uart_regs.v.
//
// TWO DIFFERENT INTERRUPT BEHAVIORS, BY DESIGN (see docs/interrupts.md for
// the full per-source semantics table):
//
//   1. STICKY, EDGE-LATCHED, WRITE-1-TO-CLEAR (bits 0-3: parity error,
//      framing error, overrun, break): these are one-shot EVENTS. Once the
//      underlying condition pulses (or, for break, transitions low-to-high),
//      the corresponding IRQ_STATUS bit latches to 1 and STAYS there,
//      regardless of what the underlying condition does next, until
//      software explicitly writes a 1 to that bit to acknowledge it. This
//      is the right behavior for events, because an event can be missed
//      entirely if it isn't sticky (a parity error that lasts exactly one
//      clock cycle could not otherwise ever be observed by software polling
//      on its own schedule).
//
//   2. LIVE, LEVEL-MIRRORED, NOT CLEARABLE BY WRITING (bits 4-7: RX
//      available, RX threshold, TX empty, TX threshold): these directly
//      reflect a CURRENT, ongoing condition (e.g. "the RX FIFO currently
//      has at least one byte in it"). Making these sticky/clearable would
//      be actively misleading: if software "cleared" a still-true
//      condition, the interrupt would either immediately reassert (if
//      cleared and re-latched combinationally) or, worse, silently vanish
//      until some unrelated future edge re-triggered it -- neither is
//      useful. The correct, unambiguous way to make a level-type interrupt
//      go away is to make its underlying condition false (drain the RX
//      FIFO below its threshold, fill the TX FIFO above its threshold).
//      Writing 1 to one of these bits in IRQ_STATUS is therefore defined
//      to have NO EFFECT, and this is exercised directly by a test in
//      tb/uart_core_tb.v (not left as an unstated assumption).
//
// irq = OR over all 8 sources of (irq_status[i] & irq_enable[i]) -- the
// architecture explicitly suggested in the assignment, and implemented
// literally.
//==============================================================================

`include "uart_defs.vh"

module uart_irq (
    input  wire       clk,
    input  wire       reset,

    // Raw event/condition inputs, one per source (see uart_defs.vh for bit
    // assignment and docs/interrupts.md for the full semantics table).
    input  wire        raw_parity_error_pulse,   // 1-cycle pulse from uart_rx
    input  wire        raw_framing_error_pulse,   // 1-cycle pulse from uart_rx
    input  wire        raw_overrun_pulse,          // 1-cycle pulse from uart_top
    input  wire        raw_break_level,             // LEVEL from uart_rx; edge-detected below
    input  wire        raw_rx_available_level,       // LEVEL: rx fifo not empty
    input  wire        raw_rx_threshold_level,        // LEVEL: rx count >= threshold
    input  wire        raw_tx_empty_level,              // LEVEL: tx fifo empty
    input  wire        raw_tx_threshold_level,           // LEVEL: tx count <= threshold

    // Register-interface side (from uart_regs.v)
    input  wire        enable_write_strobe,
    input  wire [7:0]  enable_write_value,
    input  wire        status_write_strobe,  // write-1-to-clear
    // verilator lint_off UNUSEDSIGNAL
    // status_write_value[7:4] is genuinely unused: bits 4-7 are the
    // level-mirrored FIFO conditions (see header comment), which are NOT
    // clearable by writing -- only bits 0-3 (the sticky event bits) are
    // ever read out of this vector. This is intentional, documented
    // behavior, not an oversight; see the header comment above and
    // docs/interrupts.md.
    input  wire [7:0]  status_write_value,
    // verilator lint_on UNUSEDSIGNAL
    output reg  [7:0]  enable_read_value,
    output wire [7:0]  status_read_value,

    output wire        irq
);

    // ---- IRQ_ENABLE storage: plain read/write, no side effects. ----------
    always @(posedge clk) begin
        if (reset)
            enable_read_value <= 8'h00; // all sources disabled out of reset
        else if (enable_write_strobe)
            enable_read_value <= enable_write_value;
    end

    // ---- Break: edge-detect the level into a one-shot pulse, so it can
    //      share the same sticky-latch logic as the genuinely pulsed
    //      sources below. ----------------------------------------------
    reg break_level_prev;
    always @(posedge clk) begin
        if (reset)
            break_level_prev <= 1'b0;
        else
            break_level_prev <= raw_break_level;
    end
    wire raw_break_pulse = raw_break_level && !break_level_prev;

    // ---- Sticky bits (0-3): latch on pulse, clear on write-1. ------------
    reg [3:0] sticky;
    wire [3:0] sticky_set_pulse = {raw_break_pulse, raw_overrun_pulse,
                                    raw_framing_error_pulse, raw_parity_error_pulse};

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_sticky
            always @(posedge clk) begin
                if (reset)
                    sticky[gi] <= 1'b0;
                else if (sticky_set_pulse[gi])
                    sticky[gi] <= 1'b1; // event wins over a simultaneous clear;
                                           // see docs/interrupts.md
                else if (status_write_strobe && status_write_value[gi])
                    sticky[gi] <= 1'b0;
            end
        end
    endgenerate

    // ---- Level bits (4-7): pure combinational mirrors. Writes to these
    //      bit positions in IRQ_STATUS are accepted (no bus error) but
    //      have no effect -- see header comment. --------------------------
    wire [3:0] level_bits = {raw_tx_threshold_level, raw_tx_empty_level,
                              raw_rx_threshold_level, raw_rx_available_level};

    assign status_read_value = {level_bits, sticky};

    // ---- Final IRQ: literally OR(IRQ_STATUS & IRQ_ENABLE). ---------------
    assign irq = |(status_read_value & enable_read_value);

endmodule
