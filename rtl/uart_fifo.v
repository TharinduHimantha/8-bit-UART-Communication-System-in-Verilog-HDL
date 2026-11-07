//==============================================================================
// Module : uart_fifo
// Purpose: Generic, reusable synchronous FIFO. Used twice in this project
//          (TX FIFO and RX FIFO, see uart_top.v) with different parameters,
//          but is otherwise completely UART-agnostic -- it has no knowledge
//          of bytes, frames, or serial timing, only of DATA_WIDTH-wide
//          entries.
//
// PARAMETERIZATION AND THE POWER-OF-TWO RESTRICTION:
//   DEPTH must be a power of two. This is not an arbitrary restriction --
//   it is what makes the full/empty logic below correct and cheap: the
//   read and write pointers are each ADDR_WIDTH+1 bits wide (one bit wider
//   than needed to index the memory array), and full/empty are distinguished
//   by comparing that extra "wrap" bit rather than by any special-cased
//   count tracking:
//     empty = (wr_ptr == rd_ptr)                    -- pointers fully equal
//     full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
//             (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0])
//             -- same index, but the write pointer has wrapped one more
//                time than the read pointer.
//   This is the standard "one extra pointer bit" FIFO design, and it only
//   produces unambiguous full/empty detection when DEPTH is a power of two
//   (so that ADDR_WIDTH = $clog2(DEPTH) indexes the memory exactly, with no
//   unused/wasted address values that would break the wrap-bit comparison).
//   A non-power-of-two DEPTH is explicitly NOT supported: elaboration
//   deliberately fails (via a generate-block $error) rather than silently
//   synthesizing subtly-incorrect full/empty logic. See docs/fifo.md for
//   the full explanation, including why a modulo-based alternative that
//   *would* support arbitrary depths was not used (added arithmetic cost
//   for a case this project's DEPTH values never actually need).
//
// SEMANTICS (see docs/fifo.md for the complete, exhaustive specification):
//   - Read side is FIRST-WORD-FALL-THROUGH (FWFT): rd_data is a
//     COMBINATIONAL peek of the current front-of-queue entry (0 when
//     empty), visible at all times with zero extra latency -- it does NOT
//     require rd_en to be asserted to be valid, and does NOT lag a pop by
//     a cycle. rd_en's only job is to ADVANCE the read pointer, i.e. to
//     discard the entry currently being peeked and reveal the next one.
//     This was deliberately chosen over a registered/pipelined read
//     (rd_data updating one cycle after rd_en) specifically because a
//     pipelined read is an easy trap for any caller that also needs the
//     popped value the SAME cycle it requests the pop -- which is exactly
//     what a single-cycle, no-wait-states register-interface DATA read
//     needs to do. See docs/architecture.md's "lessons learned" note for
//     the concrete bug this avoided during development.
//   - wr_en && full : write is IGNORED. Data is not written, wr_ptr does
//     not advance, `count` does not change. This is a silent drop from the
//     FIFO's own point of view -- the caller (uart_top.v) is responsible
//     for surfacing this as an overrun/overflow condition if it cares to
//     (see uart_top.v and docs/interrupts.md); the FIFO itself has no
//     concept of "error," only "did the operation happen."
//   - rd_en && empty : the pointer-advance is IGNORED (there is nothing to
//     advance past). rd_data already reads 0 in this case per the FWFT
//     rule above.
//   - wr_en && rd_en simultaneously, FIFO neither full nor empty: BOTH
//     happen in the same cycle -- one entry is written, one entry (the
//     one that was already at the front, per FWFT -- not the one just
//     written this cycle) is popped, and `count` is unchanged (one in,
//     one out). No special-cased "simultaneous" branch is needed for
//     this: the two pointers are genuinely independent state, so this
//     case simply falls out correctly from the write-pointer-advance and
//     read-pointer-advance logic running independently.
//   - wr_en && rd_en simultaneously, FIFO full: the write is ignored (per
//     the full-write rule above) but the read still succeeds (the FIFO is
//     not empty), so this cycle nets to one entry leaving and none
//     entering -- `count` decreases by one.
//   - wr_en && rd_en simultaneously, FIFO empty: symmetric to the above --
//     the read is ignored but the write still succeeds, so `count`
//     increases by one.
//==============================================================================

module uart_fifo #(
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH      = 16
) (
    input  wire                    clk,
    input  wire                    reset,   // synchronous, active-high

    input  wire                    wr_en,
    input  wire [DATA_WIDTH-1:0]   wr_data,
    output wire                    full,

    input  wire                    rd_en,
    output wire [DATA_WIDTH-1:0]   rd_data,  // combinational FWFT peek -- see header
    output wire                    empty,

    output wire [$clog2(DEPTH+1)-1:0] count
);

    localparam ADDR_WIDTH = $clog2(DEPTH);

    // Elaboration-time check: DEPTH must be an exact power of two, per the
    // header comment. (DEPTH & (DEPTH-1)) == 0 is the standard power-of-two
    // test; DEPTH itself must also be nonzero for that test to be
    // meaningful (0 & -1 would trivially "pass" it).
    generate
        if ((DEPTH == 0) || ((DEPTH & (DEPTH - 1)) != 0)) begin : g_depth_check
            $error("uart_fifo: DEPTH must be a nonzero power of two (got %0d)", DEPTH);
        end
    endgenerate

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH:0]   wr_ptr; // one bit wider than ADDR_WIDTH -- see header
    reg [ADDR_WIDTH:0]   rd_ptr;

    wire [ADDR_WIDTH-1:0] wr_addr = wr_ptr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] rd_addr = rd_ptr[ADDR_WIDTH-1:0];

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
                   (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]);
    assign count = wr_ptr - rd_ptr; // correct even across the wrap bit, since
                                      // this is unsigned subtraction of two
                                      // (ADDR_WIDTH+1)-bit pointers that are
                                      // always within DEPTH of each other

    // FWFT combinational peek: always shows the current front-of-queue
    // entry, 0 when empty. See header comment for why this is preferable
    // to a registered/pipelined read for this project's use case.
    assign rd_data = empty ? {DATA_WIDTH{1'b0}} : mem[rd_addr];

    wire do_write = wr_en && !full;
    wire do_read  = rd_en && !empty;

    always @(posedge clk) begin
        if (reset) begin
            wr_ptr <= {(ADDR_WIDTH+1){1'b0}};
        end else if (do_write) begin
            mem[wr_addr] <= wr_data;
            wr_ptr       <= wr_ptr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            rd_ptr  <= {(ADDR_WIDTH+1){1'b0}};
        end else if (do_read) begin
            rd_ptr  <= rd_ptr + 1'b1;
        end
        // rd_data is combinational (see above) -- no register to update here.
    end

endmodule
