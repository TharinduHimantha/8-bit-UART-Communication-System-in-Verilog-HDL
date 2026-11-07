//==============================================================================
// Module : uart_regs
// Purpose: Generic memory-mapped register storage and decode for the UART
//          peripheral. Owns CONTROL, BAUD_DIV, FRAME_CONFIG, FIFO_CONTROL
//          as plain read/write storage, and read-only construction of
//          STATUS and FIFO_STATUS from live signals supplied by uart_top.
//          DATA and the IRQ_ENABLE/IRQ_STATUS pair are handled elsewhere
//          (DATA's side effects belong with the FIFOs in uart_top.v;
//          IRQ_STATUS's write-1-to-clear/sticky semantics belong with the
//          rest of the interrupt subsystem in uart_irq.v) -- see
//          docs/register_map.md for the complete map this module
//          implements, and docs/architecture.md for why DATA and
//          IRQ_STATUS specifically live outside this module instead of
//          being folded in for the sake of having "one register module."
//
// BUS PROTOCOL (see docs/register_map.md Section "Register access
// protocol" for the complete specification):
//   - Single-cycle, no wait states: `ready` is tied to 1'b1 at the top
//     level (see uart_top.v) because every operation this interface
//     supports completes combinationally/in the same cycle it is issued.
//     `ready` is still a real port, not a tie-off hidden inside this
//     module, specifically so a future version of this peripheral (e.g.
//     one where a register access needs to stall) can introduce wait
//     states without changing the port list any caller already depends on.
//   - Reads are COMBINATIONAL: read_data reflects whatever `addr` and
//     read_en currently select, with no registration delay. This keeps
//     read latency at zero extra cycles, appropriate for a simple
//     control/status interface.
//   - Writes are REGISTERED (synchronous): a write takes effect on the
//     clock edge at which write_en is high, using write_data sampled that
//     same edge.
//   - Unmapped addresses: reads return 32'h0000_0000; writes are silently
//     ignored (no bus error signal exists in this simple protocol -- see
//     docs/register_map.md for why that was judged unnecessary complexity
//     for this project's scope).
//   - Reserved bits within a mapped register: always read as 0; writes to
//     them are accepted (no error) but have no effect, exactly like
//     writing to a mapped register's unimplemented address range would
//     with a wider mask -- this keeps write behavior uniform and
//     predictable rather than needing per-bit write-masking logic.
//==============================================================================

`include "uart_defs.vh"

module uart_regs (
    input  wire        clk,
    input  wire        reset,

    // Register bus (see header for protocol)
    input  wire [7:0]  addr,
    input  wire        write_en,
    // verilator lint_off UNUSEDSIGNAL
    // write_data[31:16] is genuinely unused: every register in this map
    // is 16 bits or narrower (BAUD_DIV is the widest, at 16 bits), and
    // the bus is a plain 32-bit word per docs/register_map.md's chosen
    // protocol. This is an intentional width choice, not an oversight --
    // see docs/register_map.md for why a 32-bit bus was kept even though
    // no register needs the full width.
    input  wire [31:0] write_data,
    // verilator lint_on UNUSEDSIGNAL
    input  wire        read_en,
    output reg  [31:0] read_data,

    // ---- CONTROL (0x08): plain read/write storage, with two self-clearing
    //      write-pulse bits (TX_FIFO_RESET/RX_FIFO_RESET) -- see
    //      docs/register_map.md.
    output reg          ctrl_tx_enable,
    output reg          ctrl_rx_enable,
    output reg          ctrl_loopback_enable,
    output wire          ctrl_tx_fifo_reset_pulse, // 1 cycle, the cycle after the write
    output wire          ctrl_rx_fifo_reset_pulse,

    // ---- BAUD_DIV (0x0C)
    output reg  [15:0]  baud_div,

    // ---- FRAME_CONFIG (0x10)
    output reg  [1:0]   frame_parity_mode,
    output reg           frame_stop_bits2,

    // ---- FIFO_CONTROL (0x18): interrupt thresholds
    output reg  [7:0]   fifo_ctrl_tx_thresh,
    output reg  [7:0]   fifo_ctrl_rx_thresh,

    // ---- STATUS (0x04) sources, all live signals supplied by uart_top
    input  wire         st_tx_busy,
    input  wire         st_tx_empty,
    input  wire         st_tx_full,
    input  wire         st_rx_empty,
    input  wire         st_rx_full,
    input  wire         st_parity_error_sticky,
    input  wire         st_framing_error_sticky,
    input  wire         st_overrun_sticky,
    input  wire         st_break_live,

    // ---- FIFO_STATUS (0x14) sources
    input  wire [7:0]   st_tx_count,
    input  wire [7:0]   st_rx_count,

    // ---- DATA (0x00): side effects owned by uart_top (TX/RX FIFO access);
    //      this module only signals which address was targeted so
    //      uart_top can drive the FIFOs, and supplies the RX FIFO's
    //      current front-of-queue byte for reads.
    output wire         data_write_strobe, // 1 the cycle a write to DATA occurs
    output wire [7:0]   data_write_value,
    output wire         data_read_strobe,  // 1 the cycle a read of DATA occurs
    input  wire [7:0]   data_read_value,   // RX FIFO's rd_data, muxed in by uart_top

    // ---- IRQ_ENABLE (0x1C) / IRQ_STATUS (0x20): storage/clear owned by
    //      uart_irq.v; this module only decodes the address and forwards
    //      the write, and reads back whatever uart_irq.v currently holds.
    output wire         irq_enable_write_strobe,
    output wire [7:0]   irq_enable_write_value,
    output wire         irq_status_write_strobe, // write-1-to-clear pulse
    output wire [7:0]   irq_status_write_value,
    input  wire [7:0]   irq_enable_read_value,
    input  wire [7:0]   irq_status_read_value
);

    wire sel_data         = (addr == `UART_REG_DATA);
    wire sel_status       = (addr == `UART_REG_STATUS);
    wire sel_control      = (addr == `UART_REG_CONTROL);
    wire sel_baud_div     = (addr == `UART_REG_BAUD_DIV);
    wire sel_frame_config = (addr == `UART_REG_FRAME_CONFIG);
    wire sel_fifo_status  = (addr == `UART_REG_FIFO_STATUS);
    wire sel_fifo_control = (addr == `UART_REG_FIFO_CONTROL);
    wire sel_irq_enable   = (addr == `UART_REG_IRQ_ENABLE);
    wire sel_irq_status   = (addr == `UART_REG_IRQ_STATUS);

    assign data_write_strobe = write_en && sel_data;
    assign data_write_value  = write_data[7:0];
    assign data_read_strobe  = read_en && sel_data;

    assign irq_enable_write_strobe = write_en && sel_irq_enable;
    assign irq_enable_write_value  = write_data[7:0];
    assign irq_status_write_strobe = write_en && sel_irq_status;
    assign irq_status_write_value  = write_data[7:0];

    // TX_FIFO_RESET / RX_FIFO_RESET are self-clearing write-pulse bits:
    // the pulse uart_top actually uses to reset a FIFO is generated
    // directly from the write itself (one cycle wide, the cycle the write
    // happens), NOT from a stored bit that software would then have to
    // remember to clear back to 0. Reading CONTROL always reflects these
    // two bits as 0 -- see the read mux below -- since there is nothing
    // meaningful to read back (the action is already complete by the next
    // cycle).
    assign ctrl_tx_fifo_reset_pulse = write_en && sel_control && write_data[`CONTROL_BIT_TX_FIFO_RESET];
    assign ctrl_rx_fifo_reset_pulse = write_en && sel_control && write_data[`CONTROL_BIT_RX_FIFO_RESET];

    always @(posedge clk) begin
        if (reset) begin
            ctrl_tx_enable       <= 1'b1; // TX enabled out of reset: see
            ctrl_rx_enable       <= 1'b1; // docs/register_map.md CONTROL
            ctrl_loopback_enable <= 1'b0;
            baud_div             <= 16'd434; // matches baud_gen's DIV_RESET_VALUE
                                                // default; see docs/timing.md
            frame_parity_mode    <= `UART_PARITY_NONE;
            frame_stop_bits2     <= 1'b0;
            fifo_ctrl_tx_thresh  <= 8'd0;
            fifo_ctrl_rx_thresh  <= 8'd1;
        end else if (write_en) begin
            if (sel_control) begin
                ctrl_tx_enable       <= write_data[`CONTROL_BIT_TX_ENABLE];
                ctrl_rx_enable       <= write_data[`CONTROL_BIT_RX_ENABLE];
                ctrl_loopback_enable <= write_data[`CONTROL_BIT_LOOPBACK_ENABLE];
                // TX_FIFO_RESET/RX_FIFO_RESET: pulse only, not stored (see above).
            end else if (sel_baud_div) begin
                baud_div <= write_data[15:0];
            end else if (sel_frame_config) begin
                frame_parity_mode <= write_data[`FRAME_CONFIG_PARITY_MODE_HI:`FRAME_CONFIG_PARITY_MODE_LO];
                frame_stop_bits2  <= write_data[`FRAME_CONFIG_BIT_STOP_BITS2];
            end else if (sel_fifo_control) begin
                fifo_ctrl_tx_thresh <= write_data[`FIFO_CONTROL_TX_THRESH_HI:`FIFO_CONTROL_TX_THRESH_LO];
                fifo_ctrl_rx_thresh <= write_data[`FIFO_CONTROL_RX_THRESH_HI:`FIFO_CONTROL_RX_THRESH_LO];
            end
            // sel_data, sel_irq_enable, sel_irq_status: handled by uart_top
            // / uart_irq.v, not stored here (see header comment).
            // sel_status, sel_fifo_status: read-only; writes silently
            // ignored, per header comment on reserved/read-only behavior.
        end
    end

    // Combinational read mux.
    always @(*) begin
        read_data = 32'h0000_0000; // unmapped address default; see header
        if (sel_data) begin
            read_data = {24'h0, data_read_value};
        end else if (sel_status) begin
            read_data[`STATUS_BIT_TX_BUSY]           = st_tx_busy;
            read_data[`STATUS_BIT_TX_EMPTY]          = st_tx_empty;
            read_data[`STATUS_BIT_TX_FULL]           = st_tx_full;
            read_data[`STATUS_BIT_RX_EMPTY]          = st_rx_empty;
            read_data[`STATUS_BIT_RX_FULL]           = st_rx_full;
            read_data[`STATUS_BIT_RX_DATA_AVAILABLE] = !st_rx_empty;
            read_data[`STATUS_BIT_PARITY_ERROR]      = st_parity_error_sticky;
            read_data[`STATUS_BIT_FRAMING_ERROR]     = st_framing_error_sticky;
            read_data[`STATUS_BIT_OVERRUN]           = st_overrun_sticky;
            read_data[`STATUS_BIT_BREAK]             = st_break_live;
        end else if (sel_control) begin
            read_data[`CONTROL_BIT_TX_ENABLE]       = ctrl_tx_enable;
            read_data[`CONTROL_BIT_RX_ENABLE]       = ctrl_rx_enable;
            read_data[`CONTROL_BIT_LOOPBACK_ENABLE] = ctrl_loopback_enable;
            read_data[`CONTROL_BIT_TX_FIFO_RESET]   = 1'b0; // pulse, not stored
            read_data[`CONTROL_BIT_RX_FIFO_RESET]   = 1'b0;
        end else if (sel_baud_div) begin
            read_data = {16'h0, baud_div};
        end else if (sel_frame_config) begin
            read_data[`FRAME_CONFIG_PARITY_MODE_HI:`FRAME_CONFIG_PARITY_MODE_LO] = frame_parity_mode;
            read_data[`FRAME_CONFIG_BIT_STOP_BITS2] = frame_stop_bits2;
        end else if (sel_fifo_status) begin
            read_data[`FIFO_STATUS_TX_COUNT_HI:`FIFO_STATUS_TX_COUNT_LO] = st_tx_count;
            read_data[`FIFO_STATUS_RX_COUNT_HI:`FIFO_STATUS_RX_COUNT_LO] = st_rx_count;
            read_data[`FIFO_STATUS_BIT_TX_FULL]  = st_tx_full;
            read_data[`FIFO_STATUS_BIT_TX_EMPTY] = st_tx_empty;
            read_data[`FIFO_STATUS_BIT_RX_FULL]  = st_rx_full;
            read_data[`FIFO_STATUS_BIT_RX_EMPTY] = st_rx_empty;
        end else if (sel_fifo_control) begin
            read_data[`FIFO_CONTROL_TX_THRESH_HI:`FIFO_CONTROL_TX_THRESH_LO] = fifo_ctrl_tx_thresh;
            read_data[`FIFO_CONTROL_RX_THRESH_HI:`FIFO_CONTROL_RX_THRESH_LO] = fifo_ctrl_rx_thresh;
        end else if (sel_irq_enable) begin
            read_data = {24'h0, irq_enable_read_value};
        end else if (sel_irq_status) begin
            read_data = {24'h0, irq_status_read_value};
        end
    end

endmodule
