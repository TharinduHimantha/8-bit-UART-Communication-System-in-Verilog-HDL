//==============================================================================
// Module : uart_top
// Purpose: Top-level integration of the configurable 8-bit UART IP core:
//          baud generator, TX/RX serial engines, TX/RX FIFOs, the
//          memory-mapped register interface, and the interrupt subsystem,
//          behind a clean external interface (register bus + serial pins +
//          irq). This is the module a larger system instantiates.
//
// TX AUTO-FEED (register interface -> TX FIFO -> uart_tx), timing explained:
//   uart_fifo's rd_data is a REGISTERED output: asserting rd_en pops the
//   FIFO, but the popped value only becomes visible on rd_data one cycle
//   later (see uart_fifo.v). uart_tx, meanwhile, latches tx_data on the
//   SAME cycle it accepts tx_start. Naively asserting tx_fifo_rd_en and
//   tx_start on the same cycle would therefore feed uart_tx the PREVIOUS
//   rd_data value, not the byte actually being popped this cycle -- an
//   off-by-one that would silently transmit stale data.
//
//   The fix is a one-cycle pipeline: tx_fifo_rd_en pops the FIFO on cycle
//   N; tx_start (driven from a registered copy of that pop request, not
//   from the pop request itself) fires on cycle N+1, by which time
//   rd_data correctly reflects the byte just popped. A one-cycle guard
//   (tx_pop_in_flight, folded into the pop-request condition below)
//   prevents a second pop from being issued during the single cycle where
//   tx_busy has not yet risen to reflect the first pop's in-flight start
//   request -- without it, two FIFO entries could be popped for what
//   should be one transmitted frame. This was verified directly in
//   simulation (tb/uart_core_tb.v's FIFO-to-TX streaming tests) before
//   being trusted as correct.
//
// RX AUTO-FEED (uart_rx -> RX FIFO -> register interface): simpler, no
// pipeline hazard -- rx_valid is already a clean one-cycle pulse
// representing "this byte is ready right now," and pushing it into the RX
// FIFO the same cycle (wr_data = rx_data, wr_en = rx_valid && ...) is
// exactly the FIFO's normal write protocol.
//
// OVERRUN: if a byte is validated (rx_valid) while RX is enabled but the
// RX FIFO is already full, the new byte is discarded (there is nowhere to
// put it) and a one-cycle overrun pulse is raised for the interrupt
// subsystem and the sticky STATUS.OVERRUN bit. The RX FIFO's existing
// contents are completely undisturbed by an overrun -- see
// docs/register_map.md and docs/interrupts.md.
//==============================================================================

`include "uart_defs.vh"

module uart_top #(
    parameter integer FIFO_DEPTH       = 16,
    parameter integer BAUD_DIV_RESET   = 434, // matches uart_regs.v's CONTROL reset
    parameter integer CLKS_PER_BIT_MAX = 4096
) (
    input  wire        clk,
    input  wire        reset,       // synchronous, active-high

    // Register bus
    input  wire [7:0]  addr,
    input  wire        write_en,
    input  wire [31:0] write_data,
    input  wire        read_en,
    output wire [31:0] read_data,
    output wire        ready,       // tied 1'b1 -- see uart_regs.v header

    // Serial pins
    output wire        tx_pin,
    input  wire        rx_pin,

    // Interrupt
    output wire        irq
);

    assign ready = 1'b1; // see header / uart_regs.v: no wait states needed

    //--------------------------------------------------------------------
    // Register file
    //--------------------------------------------------------------------
    wire        ctrl_tx_enable, ctrl_rx_enable, ctrl_loopback_enable;
    wire        ctrl_tx_fifo_reset_pulse, ctrl_rx_fifo_reset_pulse;
    wire [15:0] baud_div;
    wire [1:0]  frame_parity_mode;
    wire        frame_stop_bits2;
    wire [7:0]  fifo_ctrl_tx_thresh, fifo_ctrl_rx_thresh;

    wire        data_write_strobe;
    wire [7:0]  data_write_value;
    wire        data_read_strobe;
    wire [7:0]  data_read_value;

    wire        irq_enable_write_strobe;
    wire [7:0]  irq_enable_write_value;
    wire        irq_status_write_strobe;
    wire [7:0]  irq_status_write_value;
    wire [7:0]  irq_enable_read_value;
    wire [7:0]  irq_status_read_value;

    wire        tx_busy, tx_done_unused;
    wire        rx_valid, rx_busy;
    wire        parity_error, framing_error, break_detected;
    wire [7:0]  rx_data_serial;

    wire        tx_fifo_full, tx_fifo_empty;
    wire [$clog2(FIFO_DEPTH+1)-1:0] tx_fifo_count;
    wire [7:0]  tx_fifo_count_w = {{(8-$clog2(FIFO_DEPTH+1)){1'b0}}, tx_fifo_count};
    wire        rx_fifo_full, rx_fifo_empty;
    wire [$clog2(FIFO_DEPTH+1)-1:0] rx_fifo_count;
    wire [7:0]  rx_fifo_count_w = {{(8-$clog2(FIFO_DEPTH+1)){1'b0}}, rx_fifo_count};

    uart_regs u_regs (
        .clk(clk), .reset(reset),
        .addr(addr), .write_en(write_en), .write_data(write_data),
        .read_en(read_en), .read_data(read_data),

        .ctrl_tx_enable(ctrl_tx_enable),
        .ctrl_rx_enable(ctrl_rx_enable),
        .ctrl_loopback_enable(ctrl_loopback_enable),
        .ctrl_tx_fifo_reset_pulse(ctrl_tx_fifo_reset_pulse),
        .ctrl_rx_fifo_reset_pulse(ctrl_rx_fifo_reset_pulse),

        .baud_div(baud_div),
        .frame_parity_mode(frame_parity_mode),
        .frame_stop_bits2(frame_stop_bits2),
        .fifo_ctrl_tx_thresh(fifo_ctrl_tx_thresh),
        .fifo_ctrl_rx_thresh(fifo_ctrl_rx_thresh),

        .st_tx_busy(tx_busy),
        .st_tx_empty(tx_fifo_empty),
        .st_tx_full(tx_fifo_full),
        .st_rx_empty(rx_fifo_empty),
        .st_rx_full(rx_fifo_full),
        .st_parity_error_sticky(irq_status_read_value[`IRQ_BIT_PARITY_ERROR]),
        .st_framing_error_sticky(irq_status_read_value[`IRQ_BIT_FRAMING_ERROR]),
        .st_overrun_sticky(irq_status_read_value[`IRQ_BIT_OVERRUN]),
        .st_break_live(break_detected), // live level, deliberately NOT the
                                          // sticky IRQ bit -- see
                                          // docs/register_map.md STATUS
        .st_tx_count(tx_fifo_count_w),
        .st_rx_count(rx_fifo_count_w),

        .data_write_strobe(data_write_strobe),
        .data_write_value(data_write_value),
        .data_read_strobe(data_read_strobe),
        .data_read_value(data_read_value),

        .irq_enable_write_strobe(irq_enable_write_strobe),
        .irq_enable_write_value(irq_enable_write_value),
        .irq_status_write_strobe(irq_status_write_strobe),
        .irq_status_write_value(irq_status_write_value),
        .irq_enable_read_value(irq_enable_read_value),
        .irq_status_read_value(irq_status_read_value)
    );

    //--------------------------------------------------------------------
    // TX FIFO + auto-feed pipeline (see header comment)
    //--------------------------------------------------------------------
    wire       tx_fifo_wr_en = data_write_strobe && !tx_fifo_full;
    wire [7:0] tx_fifo_rd_data; // FWFT: always the current front entry

    // With an FWFT FIFO, tx_fifo_rd_data already reflects the byte that
    // WILL be popped this cycle, so tx_start and the pop can fire on the
    // SAME cycle -- no pipeline delay needed (see uart_fifo.v and
    // docs/architecture.md's "lessons learned" for the registered-read
    // version of this logic that this replaced, and the bug it had).
    wire tx_pop_request = ctrl_tx_enable && !tx_fifo_empty && !tx_busy;

    uart_fifo #(.DATA_WIDTH(8), .DEPTH(FIFO_DEPTH)) u_tx_fifo (
        .clk(clk), .reset(reset || ctrl_tx_fifo_reset_pulse),
        .wr_en(tx_fifo_wr_en), .wr_data(data_write_value), .full(tx_fifo_full),
        .rd_en(tx_pop_request), .rd_data(tx_fifo_rd_data), .empty(tx_fifo_empty),
        .count(tx_fifo_count)
    );

    //--------------------------------------------------------------------
    // Baud generator + TX + RX serial engines
    //--------------------------------------------------------------------
    wire        baud_tick, baud_restart;
    wire [15:0] active_divisor;
    wire        cfg_update_allowed = !tx_busy && !rx_busy;

    baud_gen #(
        .DIV_WIDTH(16), .DIV_RESET_VALUE(BAUD_DIV_RESET)
    ) u_baud_gen (
        .clk(clk), .reset(reset),
        .cfg_divisor(baud_div), .cfg_update_allowed(cfg_update_allowed),
        .restart(baud_restart), .tick(baud_tick),
        .active_divisor_out(active_divisor)
    );

    uart_tx #(.DATA_BITS(8)) u_uart_tx (
        .clk(clk), .reset(reset),
        .tx_start(tx_pop_request), .tx_data(tx_fifo_rd_data),
        .cfg_parity_mode(frame_parity_mode), .cfg_stop_bits2(frame_stop_bits2),
        .baud_tick(baud_tick), .baud_restart(baud_restart),
        .tx(tx_pin), .tx_busy(tx_busy), .tx_done(tx_done_unused)
    );

    // Loopback mux: internal (uart_tx's own output) vs. external pin. The
    // external tx_pin is always driven from uart_tx regardless of loopback
    // mode (see header/docs/architecture.md); only uart_rx's source
    // changes.
    wire rx_source = ctrl_loopback_enable ? tx_pin : rx_pin;

    uart_rx #(
        .CLKS_PER_BIT_MAX(CLKS_PER_BIT_MAX), .DATA_BITS(8)
    ) u_uart_rx (
        .clk(clk), .reset(reset),
        .rx(rx_source),
        .cfg_clks_per_bit(active_divisor),
        .cfg_parity_mode(frame_parity_mode), .cfg_stop_bits2(frame_stop_bits2),
        .rx_data(rx_data_serial), .rx_valid(rx_valid), .rx_busy(rx_busy),
        .parity_error(parity_error), .framing_error(framing_error),
        .break_detected(break_detected)
    );

    //--------------------------------------------------------------------
    // RX FIFO + overrun detection
    //--------------------------------------------------------------------
    wire overrun_pulse = rx_valid && ctrl_rx_enable && rx_fifo_full;
    wire rx_fifo_wr_en = rx_valid && ctrl_rx_enable && !rx_fifo_full;

    wire       rx_fifo_rd_en = data_read_strobe && !rx_fifo_empty;
    wire [7:0] rx_fifo_rd_data;

    assign data_read_value = rx_fifo_empty ? 8'h00 : rx_fifo_rd_data;

    uart_fifo #(.DATA_WIDTH(8), .DEPTH(FIFO_DEPTH)) u_rx_fifo (
        .clk(clk), .reset(reset || ctrl_rx_fifo_reset_pulse),
        .wr_en(rx_fifo_wr_en), .wr_data(rx_data_serial), .full(rx_fifo_full),
        .rd_en(rx_fifo_rd_en), .rd_data(rx_fifo_rd_data), .empty(rx_fifo_empty),
        .count(rx_fifo_count)
    );

    //--------------------------------------------------------------------
    // Interrupt subsystem
    //--------------------------------------------------------------------
    wire rx_threshold_level = (rx_fifo_count_w >= fifo_ctrl_rx_thresh);
    wire tx_threshold_level = (tx_fifo_count_w <= fifo_ctrl_tx_thresh);

    uart_irq u_irq (
        .clk(clk), .reset(reset),

        .raw_parity_error_pulse(parity_error),
        .raw_framing_error_pulse(framing_error),
        .raw_overrun_pulse(overrun_pulse),
        .raw_break_level(break_detected),
        .raw_rx_available_level(!rx_fifo_empty),
        .raw_rx_threshold_level(rx_threshold_level),
        .raw_tx_empty_level(tx_fifo_empty),
        .raw_tx_threshold_level(tx_threshold_level),

        .enable_write_strobe(irq_enable_write_strobe),
        .enable_write_value(irq_enable_write_value),
        .status_write_strobe(irq_status_write_strobe),
        .status_write_value(irq_status_write_value),
        .enable_read_value(irq_enable_read_value),
        .status_read_value(irq_status_read_value),

        .irq(irq)
    );

endmodule
