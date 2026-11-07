//==============================================================================
// Module : baud_gen
// Purpose: Generates a single-cycle "tick" pulse once every "active_divisor"
//          system clock cycles, where active_divisor is itself a runtime-
//          configurable value (software writes it through the BAUD_DIV
//          register), not a fixed elaboration-time parameter.
//
// PHASE 6-8 CHANGE FROM THE EARLIER (PARAMETER-ONLY) VERSION:
//   Earlier phases fixed CLKS_PER_BIT as a Verilog parameter -- correct for
//   a design with no register interface, but this phase's BAUD_DIV register
//   (see docs/register_map.md) requires the divisor to be changeable by
//   software at runtime. DIV_WIDTH and DIV_RESET_VALUE remain parameters
//   (they size the register and set its value out of reset), but the value
//   actually used for bit timing, active_divisor, is a register loaded from
//   the cfg_divisor input.
//
// Update policy -- "applied after current frame" (see docs/register_map.md
// BAUD_DIV and docs/architecture.md Section on baud reconfiguration):
//   active_divisor only loads a new value from cfg_divisor while
//   cfg_update_allowed is asserted. The top-level module drives
//   cfg_update_allowed = !(tx_busy || rx_busy), i.e. only while the link is
//   completely idle. This means:
//     - A BAUD_DIV write that lands while the link is idle takes effect
//       immediately, in time for the very next frame.
//     - A BAUD_DIV write that lands mid-frame is held (visible in the
//       BAUD_DIV register immediately, since that register itself is a
//       simple read/write store elsewhere -- see uart_regs.v) but does NOT
//       affect active_divisor, and therefore does not affect timing, until
//       the current frame finishes and the link goes idle.
//   This is deterministic and avoids the alternative of applying a divisor
//   change mid-frame, which would corrupt that frame's bit timing (some
//   bits at the old rate, some at the new rate).
//
// The restart/tick handshake with uart_tx is otherwise unchanged from the
// earlier phases -- see docs/architecture.md for the full derivation of why
// both are combinational (zero extra latency, so every bit -- including the
// start bit -- is exactly active_divisor cycles wide).
//==============================================================================

module baud_gen #(
    parameter integer DIV_WIDTH       = 16,
    parameter integer DIV_RESET_VALUE = 434   // e.g. 50,000,000 / 115200, truncated
) (
    input  wire                   clk,
    input  wire                   reset,             // synchronous, active-high
    input  wire [DIV_WIDTH-1:0]   cfg_divisor,        // from BAUD_DIV register
    input  wire                   cfg_update_allowed, // link fully idle
    input  wire                   restart,            // realign to a new frame
    output wire                   tick,
    output wire [DIV_WIDTH-1:0]   active_divisor_out  // frame-stable divisor;
                                                         // see header -- RX must
                                                         // use THIS, not cfg_divisor
                                                         // directly, or a mid-frame
                                                         // register write corrupts
                                                         // RX timing even though TX
                                                         // is correctly protected.
);

    reg [DIV_WIDTH-1:0] active_divisor;
    assign active_divisor_out = active_divisor;

    always @(posedge clk) begin
        if (reset)
            active_divisor <= DIV_RESET_VALUE[DIV_WIDTH-1:0];
        else if (cfg_update_allowed)
            active_divisor <= cfg_divisor;
        // else: hold -- a pending divisor change waits for idle (see header).
    end

    reg [DIV_WIDTH-1:0] count;

    // Combinational tick: see docs/architecture.md for why this must not be
    // registered (a registered tick reintroduces a one-cycle error on the
    // start bit specifically, which was caught during earlier-phase
    // development by directly measuring captured line timing).
    assign tick = (count == active_divisor - 1'b1);

    always @(posedge clk) begin
        if (reset) begin
            count <= {DIV_WIDTH{1'b0}};
        end else if (restart) begin
            count <= {DIV_WIDTH{1'b0}};
        end else if (tick) begin
            count <= {DIV_WIDTH{1'b0}};
        end else begin
            count <= count + 1'b1;
        end
    end

endmodule
