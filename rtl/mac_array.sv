// mac_array.sv — weight-stationary MAC array for a decoder-layer GEMV
//
// ## What problem this solves
//   Autoregressive decoding is memory-bound, not compute-bound. At batch=1 every
//   token must read the ENTIRE weight matrix to produce ONE output vector.
//   Arithmetic intensity is ~1 MAC per weight word fetched, so the win comes
//   from how weights are fetched and held, not from raw MAC throughput. See
//   docs/PLAN.md for the energy-per-token argument.
//
// ## The array
//   Weights are stationary: once loaded, w[k][c] stays resident in lane c for
//   the whole pass. Activations stream past. Lane c accumulates
//
//       y[c] = sum over k of w[k][c] * x[k]
//
//   which is y = W^T x — the GEMV a decoder layer's attention output projection
//   or FFN up-projection needs. There is exactly ONE index (k, the reduction
//   index); the output index c IS the lane, so each lane writes y[c] at a
//   static index. There is no column counter.
//
//   Physical shape: ARRAY_COLS lanes, each holding one row of the
//   ARRAY_ROWS x ARRAY_COLS weight tile, fed by a single broadcast activation
//   x[k].
//
// ## On-chip SRAM
//   `w_mem` is a flat row-major array (w_mem[k*ARRAY_COLS + c] == w[k][c]) and
//   `x_mem` is one-deep in the reduction index. Both are read through a
//   SYNCHRONOUS port: the address is presented one cycle and the data lands in
//   w_q/x_q the next. That is the coding style that infers SB_RAM40_4K on
//   iCE40-UP5K (one weight RAM per lane, plus one activation RAM) and an SRAM
//   macro or compiler-inferred memory on Sky130. At the default
//   4x4x8 = 128 bits of weights a BRAM would be absurd — the UP5K has 30
//   blocks — so this elaborates to flops. See docs/PLAN.md for the crossover.
//
// ## Reset
//   SYNCHRONOUS, active low, single clock. Reset clears the control state, the
//   result registers, the accumulators AND both memories, so every output is
//   a known value from the first cycle out of reset with no X anywhere.
//
//   Clearing memory is a deliberate trade-off, not free. Per-entry reset logic
//   is what stops these arrays becoming BRAM on iCE40 and what costs area at
//   scale; the alternative is an uninitialised memory plus an explicit
//   assume() on it in formal. The reason it is worth it HERE is that the
//   formal proof below needs no memory assumptions at all, and "no X out of
//   reset" is a property a client of this block can rely on.
//
// ## Timing
//   A pass takes 2*ARRAY_ROWS cycles: one FETCH (present the SRAM row) and one
//   ACC (consume the registered data) per reduction step. `busy` is high for
//   exactly that span; `y_valid` pulses for one cycle when the last row lands.
//   The read is issued unconditionally (no read-enable), which is both
//   BRAM-friendly and one row ahead of consumption; the address is clamped in
//   the final ACC cycle because the read is dead there.
//
// ## Load semantics
//   Loads are accepted ONLY while idle. A load concurrent with `start` IS
//   accepted (both are idle-qualified) and is visible to that pass, which is
//   how you write the last weight and launch in the same cycle. A load during a
//   pass is silently dropped, never applied late — that is what makes the
//   weights provably stationary for the duration of a pass.
//
//   `start` is level-sensitive while idle: holding it high streams back-to-back
//   passes, one commit every 2*ARRAY_ROWS cycles.
//
// ## Parameters
//   DATA_WIDTH : bit width of weights and activations, signed two's complement.
//   ARRAY_ROWS : reduction depth K, i.e. rows in the weight tile.
//   ARRAY_COLS : lane count N, i.e. the width of output vector y.
//   ACC_WIDTH  : accumulator width. Default is the provably sufficient size
//                (2*DATA_WIDTH + ceil(log2(ARRAY_ROWS))); undersizing is
//                caught at elaboration time AND by the formal no-overflow
//                property. See docs/PLAN.md for the bound.

`timescale 1ns / 1ps

module mac_array #(
    parameter DATA_WIDTH = 8,
    parameter ARRAY_ROWS = 4,
    parameter ARRAY_COLS = 4,
    // Provably sufficient: one product of two DATA_WIDTH signed values needs
    // 2*DATA_WIDTH bits, and ARRAY_ROWS of them summed need ceil(log2) more.
    // The worst case is all-negative: every product = -2^(2*DATA_WIDTH-1).
    parameter ACC_WIDTH  = 2 * DATA_WIDTH
                          + ((ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS)),
    // Index widths for the port handshakes. Derived; do not override.
    parameter ROW_BITS   = (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS),
    parameter COL_BITS   = (ARRAY_COLS <= 1) ? 1 : $clog2(ARRAY_COLS)
) (
    input  wire                          clk,
    input  wire                          rst_n,     // SYNCHRONOUS, active low

    // ---- weight SRAM write port (accepted only while idle) -----------------
    input  wire                          w_load_en,
    input  wire  [ROW_BITS-1:0]          w_row,
    input  wire  [COL_BITS-1:0]          w_col,
    input  wire  signed [DATA_WIDTH-1:0] w_data,

    // ---- activation SRAM write port (accepted only while idle) -------------
    input  wire                          x_load_en,
    input  wire  [ROW_BITS-1:0]          x_row,
    input  wire  signed [DATA_WIDTH-1:0] x_data,

    // ---- control -----------------------------------------------------------
    input  wire                          start,     // level-sensitive while idle
    output wire                          busy,
    output wire                          y_valid,   // 1-cycle pulse
    output logic [ARRAY_COLS-1:0][ACC_WIDTH-1:0] y
);

    // ======================================================================
    // Elaboration-time parameter checks
    //
    // Guarded by `ifndef SYNTHESIS because Yosys and Icarus both refuse to
    // elaborate an `initial` containing $error. The formal flow therefore
    // reads this file with -DSYNTHESIS, which is why `make formal-neg` can
    // undersize ACC_WIDTH on purpose and see the FORMAL property catch it
    // rather than tripping this block.
    // ======================================================================
`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH < 2)
            $error("mac_array: DATA_WIDTH must be >= 2 (got %0d)", DATA_WIDTH);
        if (ARRAY_ROWS < 1)
            $error("mac_array: ARRAY_ROWS must be >= 1 (got %0d)", ARRAY_ROWS);
        if (ARRAY_COLS < 1)
            $error("mac_array: ARRAY_COLS must be >= 1 (got %0d)", ARRAY_COLS);
        // A single product needs 2*DATA_WIDTH bits, and ARRAY_ROWS of them
        // summed need that plus ceil(log2(ARRAY_ROWS)). Undersizing here is
        // what the formal no-overflow property exists to catch, so the two
        // checks are deliberately the same inequality.
        if (ACC_WIDTH < 2 * DATA_WIDTH + ((ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS)))
            $error("mac_array: ACC_WIDTH (%0d) too small, need %0d for DATA_WIDTH=%0d ARRAY_ROWS=%0d",
                   ACC_WIDTH, 2 * DATA_WIDTH + ((ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS)),
                   DATA_WIDTH, ARRAY_ROWS);
    end
`endif

    // ======================================================================
    // On-chip SRAM
    // ======================================================================
    localparam int W_ENTRIES = ARRAY_ROWS * ARRAY_COLS;

    // Row-major, so one reduction step reads a whole row of the tile.
    reg [DATA_WIDTH-1:0] w_mem [0:W_ENTRIES-1];
    reg [DATA_WIDTH-1:0] x_mem [0:ARRAY_ROWS-1];

    reg [ROW_BITS-1:0]   rd_row;              // next row to present to the SRAM
    reg [ROW_BITS-1:0]   row_idx;             // reduction index k being consumed
    reg [DATA_WIDTH-1:0] w_q [0:ARRAY_COLS-1]; // registered weight-row read
    reg [DATA_WIDTH-1:0] x_q;                 // registered activation read

    // ======================================================================
    // Control
    // ======================================================================
    localparam [1:0] S_IDLE  = 2'd0,
                     S_FETCH = 2'd1,
                     S_ACC   = 2'd2;
    localparam [ROW_BITS-1:0] LAST_ROW = ROW_BITS'(ARRAY_ROWS - 1);

    reg [1:0] state;
    reg       y_valid_r;

    wire accept_loads = (state == S_IDLE);
    wire new_pass     = accept_loads && start;
    wire do_acc       = (state == S_ACC) && (row_idx != LAST_ROW);
    wire do_commit    = (state == S_ACC) && (row_idx == LAST_ROW);
    wire clear_acc    = do_commit | new_pass;

    // The read is issued unconditionally, one row ahead of consumption. In the
    // final ACC cycle rd_row has already wrapped to ARRAY_ROWS and the data
    // read there is dead, so the address is clamped to keep every SRAM access
    // in range. Formal property a_addr_sane checks that this is the only
    // out-of-range case that exists.
    wire [ROW_BITS-1:0] raddr = (do_commit) ? {ROW_BITS{1'b0}} : rd_row;

    assign busy    = (state != S_IDLE);
    assign y_valid = y_valid_r;

    // ======================================================================
    // Control sequencer
    // ======================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            row_idx   <= {ROW_BITS{1'b0}};
            rd_row    <= {ROW_BITS{1'b0}};
            y_valid_r <= 1'b0;
        end else begin
            y_valid_r <= 1'b0;   // single-cycle pulse by construction

            case (state)
                S_IDLE: begin
                    // Park the reduction indices every idle cycle, not just on
                    // the transition that entered idle. Relying on the entry
                    // transition alone is what makes a_idle_clean a
                    // reachability claim rather than a safety one, and
                    // k-induction cannot prove reachability: it happily finds
                    // a stuttering state (idle, rd_row=1, start=0) that
                    // satisfies every assertion and never leaves, so the
                    // property fails there. That state is unreachable from
                    // reset, but "unreachable" is not a property a solver can
                    // discharge, and a design whose correctness argument
                    // needs one is fragile.
                    //
                    // Clearing unconditionally makes the invariant 1-inductive
                    // by construction: from ANY idle state the next state has
                    // clean indices. Costs nothing -- these are flops that
                    // hold stale values while idle otherwise, and flop count
                    // is unchanged.
                    rd_row  <= {ROW_BITS{1'b0}};
                    row_idx <= {ROW_BITS{1'b0}};
                    if (start) begin
                        state   <= S_FETCH;
                    end
                end
                // w_q/x_q hold row rd_row from this edge onward.
                S_FETCH: begin
                    rd_row <= rd_row + 1'b1;
                    state  <= S_ACC;
                end
                S_ACC: begin
                    if (do_commit) begin
                        y_valid_r <= 1'b1;
                        state     <= S_IDLE;
                        rd_row    <= {ROW_BITS{1'b0}};
                        row_idx   <= {ROW_BITS{1'b0}};
                    end else begin
                        row_idx <= row_idx + 1'b1;
                        state   <= S_FETCH;
                    end
                end
                // Recovery path. Unreachable from reset, because the only
                // assignments to `state` are the three encodings above, so
                // this never fires on real hardware. It exists to stop an
                // illegal encoding from propagating forever.
                //
                // It must reset the reduction INDICES as well as the state.
                // Resetting only `state` lands the FSM in S_IDLE with
                // row_idx/rd_row still wherever the corruption left them,
                // which contradicts a_idle_clean and, worse, would start the
                // next pass from an arbitrary row. That is a real latent bug
                // even while the path is unreachable today, because adding a
                // fourth state later would make the encoding live. Found by
                // the FORMAL_NO_REF proof, which is a stronger invariant set
                // than the reference model happens to be: the reference
                // properties masked it at reduced geometry.
                default: begin
                    state     <= S_IDLE;
                    row_idx   <= {ROW_BITS{1'b0}};
                    rd_row    <= {ROW_BITS{1'b0}};
                end
            endcase
        end
    end

    // ======================================================================
    // Synchronous read port
    // ======================================================================
    integer q;
    always @(posedge clk) begin
        if (!rst_n) begin
            x_q <= {DATA_WIDTH{1'b0}};
            for (q = 0; q < ARRAY_COLS; q = q + 1)
                w_q[q] <= {DATA_WIDTH{1'b0}};
        end else begin
            x_q <= x_mem[raddr];
            for (q = 0; q < ARRAY_COLS; q = q + 1)
                w_q[q] <= w_mem[raddr * ARRAY_COLS + q];
        end
    end

    // ======================================================================
    // Write ports, gated to idle
    //
    // A load issued while busy is DROPPED, not deferred. That is what makes
    // the weights provably stationary for the duration of a pass, which in
    // turn is what lets the formal invariants be unconditional — no assume()
    // on memory anywhere in this file.
    // ======================================================================
    integer wr;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (wr = 0; wr < W_ENTRIES; wr = wr + 1)
                w_mem[wr] <= {DATA_WIDTH{1'b0}};
        end else if (accept_loads && w_load_en) begin
            w_mem[w_row * ARRAY_COLS + w_col] <= w_data;
        end
    end

    integer xr;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (xr = 0; xr < ARRAY_ROWS; xr = xr + 1)
                x_mem[xr] <= {DATA_WIDTH{1'b0}};
        end else if (accept_loads && x_load_en) begin
            x_mem[x_row] <= x_data;
        end
    end

    // ======================================================================
    // The array: one lane per output index, weights stationary
    // ======================================================================
    genvar c;
    generate
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin : g_lane
            reg   signed [ACC_WIDTH-1:0]        acc;
            wire signed [2*DATA_WIDTH-1:0]       prod_full;
            wire signed [ACC_WIDTH-1:0]          prod;

            // Both operands are explicitly cast to signed. w_q[c] is a select
            // out of an unsigned reg array; an unsigned operand here would
            // silently turn a negative weight into a huge positive product.
            assign prod_full = $signed(w_q[c]) * $signed(x_q);
            // Sign-extends (never truncates) because ACC_WIDTH >= 2*DATA_WIDTH,
            // which the elaboration check above enforces. Written out rather
            // than relying on implicit extension so the intent survives lint.
            assign prod      = {{(ACC_WIDTH - 2 * DATA_WIDTH){prod_full[2*DATA_WIDTH-1]}},
                                 prod_full};

            always @(posedge clk) begin
                if (!rst_n) begin
                    acc  <= {ACC_WIDTH{1'b0}};
                    y[c] <= {ACC_WIDTH{1'b0}};
                end else begin
                    if (do_commit) y[c] <= acc + prod;
                    if (do_acc)    acc  <= acc + prod;
                    if (clear_acc) acc  <= {ACC_WIDTH{1'b0}};
                end
            end
        end
    endgenerate

    // ======================================================================
    // Formal properties. Compiled only by SymbiYosys, which defines FORMAL.
    //
    // These live inside the module because the inductive invariants need the
    // internal accumulators, the read pipeline and the memories. A harness
    // cannot see them and flattening to expose them would blow up the proof.
    // Port-level properties that need nothing internal live in
    // formal/mac_array_props.sv instead.
    //
    // The reference model is ACC_WIDTH+2 bits wide, not ACC_WIDTH+1. With only
    // one extra bit the "extra bit" is the sign of the result, so it is 1 for
    // every legitimately negative partial sum and the overflow property would
    // fire on correct hardware. Two extra bits give room to tell "this value
    // needs more than ACC_WIDTH bits" apart from "this value is negative".
    //
    // FORMAL_NO_REF drops the reference model and the five arithmetic
    // properties that consume it, leaving the control-plane and read-pipeline
    // properties. This exists because the reference is ARRAY_COLS*(ARRAY_ROWS
    // + 1) multipliers wide, and at the real 8-bit 4x4 geometry that is 20
    // unconstrained 8x8 multipliers re-evaluated combinationally in every
    // induction step. Solvers do not finish that, and an unfinished proof is
    // not evidence.
    //
    // The split is deliberate rather than a compromise:
    //   * structure (pipeline, addressing, FSM, pulse discipline) is
    //     width-independent in FORM, so it is proven unbounded at the real
    //     configuration with FORMAL_NO_REF;
    //   * arithmetic (accumulation, no-overflow, dot-product equality) is
    //     proven unbounded at reduced geometry, where the solver terminates,
    //     and the width-critical claim is checked at full width by the `neg`
    //     negative control, which fails exactly on the no-overflow property
    //     when ACC_WIDTH is too small.
    // A reader should treat "arithmetic proven at 4 bits" as a statement about
    // the structure of the datapath, and the full-width `neg` result as the
    // statement that the width itself is right.
    // ======================================================================
`ifdef FORMAL
`ifndef FORMAL_NO_REF
    localparam integer REF_WIDTH = ACC_WIDTH + 2;

    logic f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    // ---- tracked reference: mirrors the DUT accumulator -------------------
    reg   signed [REF_WIDTH-1:0] f_acc [0:ARRAY_COLS-1];
    wire signed [REF_WIDTH-1:0] f_prod [0:ARRAY_COLS-1];

    genvar fp_g;
    generate
        for (fp_g = 0; fp_g < ARRAY_COLS; fp_g = fp_g + 1) begin : g_fprod
            wire signed [2*DATA_WIDTH-1:0] fp;
            assign fp       = $signed(w_q[fp_g]) * $signed(x_q);
            assign f_prod[fp_g] = $signed(fp);
        end
    endgenerate

    integer fi;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (fi = 0; fi < ARRAY_COLS; fi = fi + 1)
                f_acc[fi] <= {REF_WIDTH{1'b0}};
        end else if (clear_acc) begin
            // do_commit and new_pass both clear, exactly as the DUT's acc does.
            for (fi = 0; fi < ARRAY_COLS; fi = fi + 1)
                f_acc[fi] <= {REF_WIDTH{1'b0}};
        end else if (do_acc) begin
            for (fi = 0; fi < ARRAY_COLS; fi = fi + 1)
                f_acc[fi] <= f_acc[fi] + f_prod[fi];
        end
    end

    // ---- closed form: the true dot product straight out of the SRAMs -----
    // Computed with no reference to the control FSM or to w_q/x_q, so it is an
    // independent statement of intent: y = W^T x.
    wire signed [REF_WIDTH-1:0] dot [0:ARRAY_COLS-1];
    genvar dc;
    generate
        for (dc = 0; dc < ARRAY_COLS; dc = dc + 1) begin : g_dot
            reg signed [REF_WIDTH-1:0] acc_d;
            integer kk;
            always @* begin
                acc_d = {REF_WIDTH{1'b0}};
                for (kk = 0; kk < ARRAY_ROWS; kk = kk + 1)
                    acc_d = acc_d
                          + $signed(w_mem[kk * ARRAY_COLS + dc]) * $signed(x_mem[kk]);
            end
            assign dot[dc] = acc_d;
        end
    endgenerate

    // ---- prefix: the partial sum over exactly the rows consumed so far ----
    // This is the strengthening invariant that makes the proof inductive.
    wire signed [REF_WIDTH-1:0] prefix [0:ARRAY_COLS-1];
    genvar pc;
    generate
        for (pc = 0; pc < ARRAY_COLS; pc = pc + 1) begin : g_prefix
            reg signed [REF_WIDTH-1:0] acc_p;
            integer kp;
            always @* begin
                acc_p = {REF_WIDTH{1'b0}};
                for (kp = 0; kp < ARRAY_ROWS; kp = kp + 1)
                    if (ROW_BITS'(kp) < row_idx)
                        acc_p = acc_p
                              + $signed(w_mem[kp * ARRAY_COLS + pc]) * $signed(x_mem[kp]);
            end
            assign prefix[pc] = acc_p;
        end
    endgenerate

`endif // !FORMAL_NO_REF

    // ---- control-plane properties ----------------------------------------
    // Kept under FORMAL_NO_REF: none of these touch the reference model, so
    // they scale to the real configuration.
    always @(posedge clk) begin
        if (f_past_valid && rst_n) begin
            // Every SRAM access is in range. raddr is the only address the
            // datapath actually uses, and it is never allowed to run off the
            // end of the array.
            a_addr_sane:   assert (raddr < ARRAY_ROWS);
            a_row_sane:    assert (row_idx < ARRAY_ROWS);

            // Idle really is a clean slate: the reduction index and the read
            // address are both parked at 0, so a fresh pass starts at row 0.
            if (state == S_IDLE) begin
                a_idle_clean: assert ((row_idx == 0) && (rd_row == 0));
            end

            // The read address runs exactly one row ahead of the row being
            // consumed, which is what ties the synchronous pipeline to the
            // reduction order. Without this the accumulator invariant below is
            // not inductive.
            if (state == S_FETCH) begin
                a_read_ahead: assert (rd_row == row_idx);
            end
            if (state == S_ACC) begin
                a_read_ahead1: assert ((row_idx == LAST_ROW && rd_row == LAST_ROW + 1'b1)
                                    || (row_idx != LAST_ROW && rd_row == row_idx + 1'b1));
            end

            // y_valid is a single-cycle pulse, never held.
            if ($past(y_valid_r)) begin
                a_pulse: assert (!y_valid_r);
            end
        end
    end

    // ---- read-pipeline property -------------------------------------------
    // w_q/x_q are loaded at every edge with the value the SRAM held BEFORE
    // that edge, at the address presented before that edge. The write ports
    // may only change the SRAM while idle, so the value sampled one edge ago
    // is still there now — unless a write landed in between, which the guard
    // excludes.
    always @(posedge clk) begin
        if (f_past_valid && rst_n && !$past(!rst_n)
                      && !($past(accept_loads) && $past(x_load_en))) begin
            a_x_pipe: assert (x_q == x_mem[$past(raddr)]);
        end
    end

    // Unlabelled: Yosys flattens generate blocks and does not scope assertion
    // names by block, so a label repeated across iterations is a hard error.
    // The line number in the failure report identifies it unambiguously.
    genvar wg;
    generate
        for (wg = 0; wg < ARRAY_COLS; wg = wg + 1) begin : g_wpipe
            always @(posedge clk) begin
                if (f_past_valid && rst_n && !$past(!rst_n)
                              && !($past(accept_loads) && $past(w_load_en)))
                    assert (w_q[wg] == w_mem[$past(raddr) * ARRAY_COLS + wg]);
            end
        end
    endgenerate

    // ---- data-plane properties, one instance per lane ----------------------
    // Written inside a generate so that the hierarchical reference
    // g_lane[n].acc and every array index are compile-time constants. A
    // procedural loop variable cannot be used in a hierarchical path, and
    // Yosys will not elaborate it.
    //
    // Excluded from FORMAL_NO_REF: every one of these five reads the reference
    // model, and the reference model is the multiplier cone.
`ifndef FORMAL_NO_REF
    genvar pa;
    generate
        for (pa = 0; pa < ARRAY_COLS; pa = pa + 1) begin : g_props
            always @(posedge clk) begin
                if (f_past_valid && rst_n) begin
                    // All unlabelled, same reason as the read-pipeline
                    // property above: these are instantiated ARRAY_COLS times.
                    // Failure reports name the file and line.

                    // (1) NO OVERFLOW, accumulator. The true partial sum needs
                    //     no more than ACC_WIDTH bits: the reference's high
                    //     bits must be nothing but a copy of its sign.
                    //     Undersized ACC_WIDTH makes this fail on a real pair.
                    assert (f_acc[pa][REF_WIDTH-1:ACC_WIDTH]
                            == {(REF_WIDTH-ACC_WIDTH){f_acc[pa][ACC_WIDTH-1]}});

                    // (2) NO OVERFLOW, result. Unconditional, over all possible
                    //     tile and activation contents, not just the ones a
                    //     pass happens to have seen.
                    assert (dot[pa][REF_WIDTH-1:ACC_WIDTH]
                            == {(REF_WIDTH-ACC_WIDTH){dot[pa][ACC_WIDTH-1]}});

                    // (3) CORRECT ACCUMULATION, tracked. The DUT accumulator is
                    //     the reference accumulator truncated to ACC_WIDTH.
                    //     Together with (1) that is exact equality with the
                    //     mathematics, not a masked comparison.
                    assert (g_lane[pa].acc == f_acc[pa][ACC_WIDTH-1:0]);

                    // (4) CORRECT ACCUMULATION, inductive. In ACC the
                    //     accumulator holds the sum over exactly the rows
                    //     already consumed, for ALL input pairs. This is the
                    //     invariant the induction actually leans on.
                    if (state == S_ACC)
                        assert (g_lane[pa].acc == prefix[pa][ACC_WIDTH-1:0]);

                    // (5) CORRECT RESULT. When the pass completes the output is
                    //     the exact dot product of the stationary tile with the
                    //     activation vector.
                    if (y_valid_r)
                        assert (y[pa] == dot[pa][ACC_WIDTH-1:0]);
                end
            end
        end
    endgenerate
`endif // !FORMAL_NO_REF
`endif // FORMAL

endmodule
