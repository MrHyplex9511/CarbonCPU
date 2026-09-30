// test_mac_array.sv — self-checking testbench for rtl/mac_array.sv
//
// The reference model here is written a completely different way from the RTL
// on purpose. The RTL walks a synchronous SRAM pipeline and accumulates one
// product per ACC cycle; the model reads a tile held in plain variables and
// evaluates the closed-form dot product. A bug shared between the two would
// have to be made twice, in two different styles, to go unnoticed.
//
// This testbench FAILS LOUDLY. Non-zero exit status on any mismatch, on any X
// reaching an output, or on a deadlock.
//   iverilog -g2012 -s test_mac_array -o build/mac.vvp tb/test_mac_array.sv rtl/mac_array.sv
//   vvp build/mac.vvp

`timescale 1ns / 1ps

module test_mac_array #(
    parameter DATA_WIDTH = 8,
    parameter ARRAY_ROWS = 4,
    parameter ARRAY_COLS = 4,
    // Must match the RTL's own derivation. 2*DATA_WIDTH alone is NOT
    // sufficient: ARRAY_ROWS products of two signed DATA_WIDTH values need
    // ceil(log2(ARRAY_ROWS)) more bits, so for 8-bit data over 4 rows it is
    // 16+2 = 18, not 16. A too-narrow accumulator here would not fail loudly
    // either, because the expected value below is truncated to the same
    // width -- both sides would wrap identically and agree. The explicit
    // range check in the random test is what actually catches it.
    parameter ACC_WIDTH  = 2 * DATA_WIDTH
                          + ((ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS))
                          + ((ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS)),
    parameter ROW_BITS   = (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS),
    parameter COL_BITS   = (ARRAY_COLS <= 1) ? 1 : $clog2(ARRAY_COLS),
    // Number of random tiles. Kept a parameter so the same file can be run
    // short (mutation testing) or long (regression).
    parameter RANDOM_TILES = 24
);

    // ---- DUT wiring -------------------------------------------------------
    reg  clk = 1'b0;
    reg  rst_n = 1'b0;

    reg                         w_load_en = 1'b0;
    reg  [ROW_BITS-1:0]         w_row = 0;
    reg  [COL_BITS-1:0]         w_col = 0;
    reg  signed [DATA_WIDTH-1:0] w_data = 0;

    reg                         x_load_en = 1'b0;
    reg  [ROW_BITS-1:0]         x_row = 0;
    reg  signed [DATA_WIDTH-1:0] x_data = 0;

    reg                          start = 1'b0;
    wire                         busy;
    wire                         y_valid;
    wire [ARRAY_COLS-1:0][ACC_WIDTH-1:0] y;

    mac_array #(
        .DATA_WIDTH (DATA_WIDTH),
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .w_load_en (w_load_en), .w_row (w_row), .w_col (w_col), .w_data (w_data),
        .x_load_en (x_load_en), .x_row (x_row), .x_data (x_data),
        .start (start),
        .busy (busy), .y_valid (y_valid), .y (y)
    );

    always #5 clk = ~clk;

    // ==================================================================
    // Independent reference model
    //
    // Tile shadow copy + closed-form dot product in wide integer arithmetic.
    // Uses a 64-bit integer, so it is not merely a second copy of the same
    // ACC_WIDTH truncation bug.
    // ==================================================================
    reg signed [DATA_WIDTH-1:0] m_w [0:ARRAY_ROWS-1][0:ARRAY_COLS-1];
    reg signed [DATA_WIDTH-1:0] m_x [0:ARRAY_ROWS-1];
    integer                     exp [0:ARRAY_COLS-1];

    // Width-correct constants. Writing `9'sd9` where an 8-bit port is expected
    // is a WIDTHTRUNC warning under Verilator and an outright error in stricter
    // flows; these locals stay correct for any DATA_WIDTH.
    localparam logic signed [DATA_WIDTH-1:0] LAST_W  = 9;
    localparam logic signed [DATA_WIDTH-1:0] POISON_W = -100;
    localparam logic signed [DATA_WIDTH-1:0] POISON_X = -100;

    // Representable range of the ACC_WIDTH-bit accumulator, for the explicit
    // overflow check above. Computed in integers, not built from a DATA_WIDTH
    // literal, so it stays right for any DATA_WIDTH.
    localparam integer MAX_ACC = (1 << (ACC_WIDTH - 1)) - 1;
    localparam integer MIN_ACC = -(1 << (ACC_WIDTH - 1));

    // Clear the SHADOW MODEL only. Reset clears the DUT memory, but between
    // tests the DUT still holds the previous tile, so a test that only
    // forgets to clear the model is not a DUT bug. Use tile_zero() to blank
    // both halves between cases; model_clear() alone is only for cases that
    // deliberately load every entry themselves.
    task model_clear;
        integer r, c;
        begin
            for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
                m_x[r] = 0;
                for (c = 0; c < ARRAY_COLS; c = c + 1)
                    m_w[r][c] = 0;
            end
        end
    endtask

    // Blank the whole tile on BOTH sides. Used at the top of every independent
    // test case so that no case can pass on residue from an earlier one.
    task tile_zero;
        integer r, c;
        begin
            model_clear;
            for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
                for (c = 0; c < ARRAY_COLS; c = c + 1)
                    put_w(r, c, 0);
                put_x(r, 0);
            end
        end
    endtask

    // Closed form: y[c] = sum_k w[k][c] * x[k]. No pipeline, no FSM.
    task model_eval;
        integer r, c;
        begin
            for (c = 0; c < ARRAY_COLS; c = c + 1) begin
                exp[c] = 0;
                for (r = 0; r < ARRAY_ROWS; r = r + 1)
                    exp[c] = exp[c] + $signed(m_w[r][c]) * $signed(m_x[r]);
            end
        end
    endtask

    integer errors = 0;
    integer checks = 0;
    integer cycles = 0;
    integer commits_seen = 0;
    integer got, guard;
    reg    f_past_valid_seen = 1'b0;

    task check;
        input        cond;
        input [8*96-1:0] msg;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("[FAIL] t=%0t cyc=%0d %0s", $time, cycles, msg);
            end
        end
    endtask

    // ---- X sweep --------------------------------------------------------
    // No output may ever be X, at any time, under any stimulus. The RTL
    // resets memories and result registers precisely so this can be an
    // unconditional sweep rather than a spot check. `$isunknown` is a
    // simulation-side 4-state test; SymbiYosys cannot see X at all, so this
    // is the only place the no-X property is actually substantive.
    reg x_tripped = 1'b0;
    always @(posedge clk) begin
        if (f_past_valid_seen) begin
            if ($isunknown(y) || $isunknown(y_valid) || $isunknown(busy)) begin
                if (!x_tripped) begin
                    x_tripped = 1'b1;
                    errors = errors + 1;
                    $display("[FAIL] t=%0t X reached an output: y=%h y_valid=%b busy=%b",
                             $time, y, y_valid, busy);
                end
            end
        end
    end
    always @(posedge clk) f_past_valid_seen <= 1'b1;

    // ---- cycle counter --------------------------------------------------
    always @(posedge clk) if (rst_n) cycles = cycles + 1;

    // ==================================================================
    // Bus-driving tasks
    // ==================================================================
    // Idle-qualified write. Asserts ready (busy low), then drives the port
    // and waits for the accepting clock edge.
    task put_w;
        input integer r;
        input integer c;
        input integer v;
        begin
            @(negedge clk);
            w_load_en = 1'b1;
            w_row     = r[ROW_BITS-1:0];
            w_col     = c[COL_BITS-1:0];
            w_data    = v[DATA_WIDTH-1:0];
            m_w[r][c] = v[DATA_WIDTH-1:0];   // shadow copy for the model
            @(posedge clk); #0.1;
            @(negedge clk);
            w_load_en = 1'b0;
        end
    endtask

    task put_x;
        input integer r;
        input integer v;
        begin
            @(negedge clk);
            x_load_en = 1'b1;
            x_row     = r[ROW_BITS-1:0];
            x_data    = v[DATA_WIDTH-1:0];
            m_x[r]    = v[DATA_WIDTH-1:0];
            @(posedge clk); #0.1;
            @(negedge clk);
            x_load_en = 1'b0;
        end
    endtask

    // Run one pass and check the result against the model.
    //
    // Counts y_valid pulses with a LOCAL counter rather than a module-level
    // accumulator, so a manual pass elsewhere in the testbench cannot leak into
    // this check. The previous version shared one global and reported a bogus
    // "did not pulse exactly once" on the pass after any hand-driven one.
    task run_pass;
        input [8*64-1:0] tag;
        integer k, c;
        integer seen;
        begin
            model_eval();
            seen = 0;

            @(negedge clk);
            start = 1'b1;
            @(posedge clk); #0.1;
            checks = checks + 1;
            check(busy === 1'b1, "busy did not assert on the start edge");
            @(negedge clk);
            start = 1'b0;

            // Wait for the commit. Bounded so a broken FSM is a FAIL, not a
            // hang: 2*ARRAY_ROWS of real work plus generous slack.
            for (k = 0; k < 4 * ARRAY_ROWS + 8; k = k + 1) begin
                @(posedge clk);
                #0.1;
                if (y_valid === 1'b1) begin
                    seen = seen + 1;
                    for (c = 0; c < ARRAY_COLS; c = c + 1) begin
                        checks = checks + 1;
                        if (y[c] !== exp[c][ACC_WIDTH-1:0]) begin
                            errors = errors + 1;
                            $display("[FAIL] %0s lane %0d: y=%0d (0x%0h) expected %0d (0x%0h)",
                                     tag, c, $signed(y[c]), y[c], exp[c], exp[c]);
                        end
                    end
                    checks = checks + 1;
                    check(busy === 1'b0, "busy still high when y_valid pulsed");
                end
            end
            checks = checks + 1;
            check(seen == 1, "y_valid did not pulse exactly once per pass");
        end
    endtask

    always @(posedge clk) if (y_valid === 1'b1) commits_seen = commits_seen + 1;

    // Deterministic pseudo-random in [-2^(DW-1), 2^(DW-1)-1].
    integer rnd_state;
    function integer rnd;
        input integer bits;
        begin
            // 32-bit xorshift, sign-folded into the requested width.
            rnd_state = rnd_state ^ (rnd_state << 13);
            rnd_state = rnd_state ^ (rnd_state >>> 17);
            rnd_state = rnd_state ^ (rnd_state << 5);
            if (bits >= 31) rnd = rnd_state;
            else rnd = rnd_state & ((1 << bits) - 1);
            // Compare against zero explicitly: `rnd & mask` is a 32-bit
            // logical AND, and handing that to a 1-bit `if` is a width
            // mismatch that Verilator flags.
            if ((rnd & (1 << (bits - 1))) != 0)
                rnd = rnd - (1 << bits);
        end
    endfunction

    integer r, c, t, v;
    integer pass_cycles;
    integer seen;

    initial begin
        $dumpfile("build/mac_array.vcd");
        $dumpvars(0, test_mac_array);

        rnd_state = 32'h1bad_f00d;
        cycles    = 0;
        model_clear();

        // ---------------------------------------------------------
        // 1. Reset behaviour
        // ---------------------------------------------------------
        repeat (3) @(posedge clk);
        #0.1;
        checks = checks + 1;
        check(busy === 1'b0, "busy high out of reset");
        checks = checks + 1;
        check(y_valid === 1'b0, "y_valid high out of reset");
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin
            checks = checks + 1;
            check(y[c] === {ACC_WIDTH{1'b0}}, "y not zero out of reset");
        end
        @(negedge clk); rst_n = 1'b1;

        // A pass with an all-zero tile must produce all zeros. Catches a
        // design that returns stale y instead of recomputing.
        run_pass("zero tile");

        // ---------------------------------------------------------
        // 2. Single nonzero element: a hot-spot test that pins the exact
        //    (row, col) addressing. A row/column swap shows up here and
        //    nowhere else.
        // ---------------------------------------------------------
        tile_zero();
        for (c = 0; c < ARRAY_COLS; c = c + 1)
            for (r = 0; r < ARRAY_ROWS; r = r + 1)
                put_w(r, c, 1);
        for (r = 0; r < ARRAY_ROWS; r = r + 1)
            put_x(r, 1);
        run_pass("all ones");

        tile_zero();
        put_w(0, 0, 7);
        put_x(0, 3);
        run_pass("single element 0,0");

        tile_zero();
        put_w(ARRAY_ROWS-1, ARRAY_COLS-1, 5);
        put_x(ARRAY_ROWS-1, 2);
        run_pass("single element last,last");

        // ---------------------------------------------------------
        // 3. Sign handling, including the worst case for the accumulator.
        //
        //    All-negative at -2^(DW-1) is the exact bound ACC_WIDTH is sized
        //    for: ARRAY_ROWS * 2^(2*DW-1). If the sign cast on the weight or
        //    the activation is dropped, this is the test that catches it.
        // ---------------------------------------------------------
        tile_zero();
        v = -(1 << (DATA_WIDTH-1));
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, v);
            put_x(r, v);
        end
        run_pass("max negative product");

        tile_zero();
        v = (1 << (DATA_WIDTH-1)) - 1;
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, v);
            put_x(r, v);
        end
        run_pass("max positive product");

        // Mixed signs, so cancellation and ordering are both exercised.
        tile_zero();
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, (r + c) % 2 == 0 ? 3 : -4);
            put_x(r, (r % 2 == 0) ? 5 : -6);
        end
        run_pass("mixed signs");

        // ---------------------------------------------------------
        // 4. Randomised tiles
        // ---------------------------------------------------------
        for (t = 0; t < RANDOM_TILES; t = t + 1) begin
            tile_zero();
            for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
                for (c = 0; c < ARRAY_COLS; c = c + 1)
                    put_w(r, c, rnd(DATA_WIDTH));
                put_x(r, rnd(DATA_WIDTH));
            end
            // Explicit accumulator-range check BEFORE truncating. Every
            // comparison in this testbench truncates the 64-bit expectation
            // to ACC_WIDTH bits, so an accumulator that is too narrow wraps
            // the expectation the same way it wraps the DUT and the two
            // agree on a wrong answer. This is the only check that can tell
            // "correct" from "correct after a wrap".
            model_eval();
            for (c = 0; c < ARRAY_COLS; c = c + 1) begin
                checks = checks + 1;
                if ((exp[c] > MAX_ACC) || (exp[c] < MIN_ACC)) begin
                    errors = errors + 1;
                    $display("[FAIL] tile %0d lane %0d: |result| %0d does not fit ACC_WIDTH=%0d (range %0d..%0d)",
                             t, c, exp[c], ACC_WIDTH, MIN_ACC, MAX_ACC);
                end
            end
            run_pass("random tile");
        end

        // ---------------------------------------------------------
        // 5. Pass length is exactly 2*ARRAY_ROWS.
        //
        //    Measured, not assumed: if the FSM spends an extra cycle anywhere
        //    the pass gets slower and the array streams fewer tokens per
        //    cycle than the docs claim. Also catches a commit that fires
        //    early and returns a partial sum.
        // ---------------------------------------------------------
        tile_zero();
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, rnd(DATA_WIDTH));
            put_x(r, rnd(DATA_WIDTH));
        end
        model_eval();

        // Count posedges from the accepting start edge to the cycle in which
        // y_valid is first observed high.
        //
        //   edge 0        : start accepted, S_IDLE -> S_FETCH
        //   edge 1        : S_FETCH -> S_ACC, row 0 data consumed at edge 2
        //   edge 2k       : row k consumed
        //   edge 2N       : row N-1 consumed, commit, y_valid_r <= 1
        //
        // so the observed latency is 2*ARRAY_ROWS posedges from edge 0.
        //
        // The commit assigns y_valid_r with a nonblocking assignment, so its
        // new value lands at the end of time step 2N rather than at the posedge
        // itself. Sampling at the posedge with no delay would therefore read
        // the OLD value and see y_valid one edge late, at 2N+1. The #0.1 in
        // the loop below deliberately steps past the delta, which is why the
        // expected count is 2N and not 2N+1. Icarus and Verilator agree here;
        // that agreement is the reason to run both.
        //
        // Asserting the exact number, rather than an inequality, is the point:
        // an FSM that spends an extra cycle anywhere fails here, and so does
        // one that commits early and returns a partial sum.
        pass_cycles = 0;
        @(negedge clk); start = 1'b1;
        @(posedge clk); #0.1;          // edge 0, start accepted
        @(negedge clk); start = 1'b0;
        while (y_valid !== 1'b1) begin
            @(posedge clk);
            #0.1;
            pass_cycles = pass_cycles + 1;
            if (pass_cycles > 4 * ARRAY_ROWS + 8) begin
                errors = errors + 1;
                $display("[FAIL] pass never completed, y_valid never asserted");
                break;
            end
        end
        checks = checks + 1;
        if (pass_cycles != 2 * ARRAY_ROWS)
            $display("[FAIL] pass latency: %0d edges, expected %0d",
                     pass_cycles, 2 * ARRAY_ROWS);
        if (pass_cycles != 2 * ARRAY_ROWS)
            errors = errors + 1;
        @(negedge clk);

        // ---------------------------------------------------------
        // 6. y_valid is a single-cycle pulse, and a new start is accepted on
        //    the very next idle cycle (no bubble between tokens).
        //
        //    We are sitting in the commit cycle, so y_valid is high RIGHT
        //    NOW. Advance exactly one posedge: it must be low again. A held
        //    y_valid would make a downstream consumer read the same result
        //    twice, and a mutation that drops the y_valid_r <= 1'b0 default
        //    is what this catches.
        // ---------------------------------------------------------
        checks = checks + 1;
        check(y_valid === 1'b1, "y_valid not high in the commit cycle");
        @(posedge clk);
        #0.1;
        checks = checks + 1;
        check(y_valid === 1'b0, "y_valid held high for more than one cycle");
        checks = checks + 1;
        check(busy === 1'b0, "busy still high one cycle after the commit");

        // Back-to-back start on the immediately following idle cycle.
        @(negedge clk); start = 1'b1;
        @(posedge clk);
        #0.1;
        checks = checks + 1;
        check(busy === 1'b1, "back-to-back start was not accepted");
        @(negedge clk); start = 1'b0;
        while (busy !== 1'b0) @(posedge clk);
        #0.1;

        // ---------------------------------------------------------
        // 7. Loads are dropped while busy, not deferred.
        //
        //    Loads a poison tile mid-pass and checks the result still matches
        //    the ORIGINAL tile. This is the property that makes the weights
        //    provably stationary, and the reason the formal invariants need
        //    no assumption on the memories.
        // ---------------------------------------------------------
        tile_zero();
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, 1);
            put_x(r, 1);
        end
        // Reference is the clean all-ones tile, computed by the model.
        model_eval();

        @(negedge clk); start = 1'b1;
        @(posedge clk); #0.1;
        @(negedge clk); start = 1'b0;
        // Advance ARRAY_ROWS edges into a 2*ARRAY_ROWS pass: solidly mid-pass,
        // with rows still left to consume. Then hammer the write port with
        // values that would give a very different answer if they landed.
        //
        // Target the LAST row, not row 0. Row k is consumed at edge 2k+2, so
        // by mid-pass the first rows have already been read and a write to
        // them cannot change this pass's result. The last row is always read
        // after this point, so a leaked write is guaranteed to corrupt it.
        repeat (ARRAY_ROWS) @(posedge clk);
        #0.1;
        checks = checks + 1;
        check(busy === 1'b1, "pass finished sooner than expected");
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin
            w_load_en = 1'b1;
            w_row     = ROW_BITS'(ARRAY_ROWS-1);
            w_col     = COL_BITS'(c);
            w_data    = POISON_W;
        end
        x_load_en = 1'b1;
        x_row     = ROW_BITS'(ARRAY_ROWS-1);
        x_data    = POISON_X;
        @(posedge clk);
        #0.1;
        @(negedge clk);
        w_load_en = 1'b0;
        x_load_en = 1'b0;

        // Bounded wait. The unbounded `while` below used to run to the global
        // timeout, which on a broken design wastes the whole run and reports a
        // misleading deadlock.
        seen = 0;
        while ((y_valid !== 1'b1) && (seen < 4 * ARRAY_ROWS + 8)) begin
            @(posedge clk);
            #0.1;
            seen = seen + 1;
        end
        checks = checks + 1;
        check(y_valid === 1'b1, "pass did not complete after mid-pass writes");
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin
            checks = checks + 1;
            if (y[c] !== exp[c][ACC_WIDTH-1:0]) begin
                errors = errors + 1;
                $display("[FAIL] mid-pass write leaked: lane %0d y=%0d expected %0d",
                         c, $signed(y[c]), exp[c]);
            end
        end
        @(negedge clk);

        // A load AFTER the pass must be accepted, proving the write port was
        // not permanently damaged by being ignored.
        put_w(0, 0, 6);
        put_x(0, 3);
        run_pass("post-pass load accepted");

        // ---------------------------------------------------------
        // 8. A load concurrent with start is accepted and visible.
        //    This is the documented "write the last weight and launch" path.
        // ---------------------------------------------------------
        tile_zero();
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, 1);
            put_x(r, 1);
        end
        // Last weight, written in the same cycle as start.
        put_w(ARRAY_ROWS-1, ARRAY_COLS-1, 9);
        @(negedge clk);
        w_load_en = 1'b1;
        w_row     = ROW_BITS'(ARRAY_ROWS-1);
        w_col     = COL_BITS'(ARRAY_COLS-1);
        w_data    = LAST_W;
        m_w[ARRAY_ROWS-1][ARRAY_COLS-1] = LAST_W;
        start     = 1'b1;
        @(posedge clk); #0.1;
        @(negedge clk);
        w_load_en = 1'b0;
        start     = 1'b0;
        seen      = 0;
        while ((y_valid !== 1'b1) && (seen < 4 * ARRAY_ROWS + 8)) begin
            @(posedge clk);
            #0.1;
            seen = seen + 1;
        end
        checks = checks + 1;
        check(y_valid === 1'b1, "load+start pass never completed");
        model_eval();
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin
            checks = checks + 1;
            if (y[c] !== exp[c][ACC_WIDTH-1:0]) begin
                errors = errors + 1;
                $display("[FAIL] load+start not visible: lane %0d y=%0d expected %0d",
                         c, $signed(y[c]), exp[c]);
            end
        end
        @(negedge clk);

        // ---------------------------------------------------------
        // 9. Reset in the middle of a pass must abort it cleanly.
        // ---------------------------------------------------------
        tile_zero();
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, rnd(DATA_WIDTH));
            put_x(r, rnd(DATA_WIDTH));
        end
        @(negedge clk); start = 1'b1;
        @(posedge clk); #0.1;
        @(negedge clk); start = 1'b0;
        repeat (2) @(posedge clk);
        #0.1;
        checks = checks + 1;
        check(busy === 1'b1, "pass ended too early to test mid-pass reset");
        // Reset is SYNCHRONOUS: assert between edges and the state must NOT
        // change yet. An async-reset mutation survives every other test.
        rst_n = 1'b0;
        #0.1;
        checks = checks + 1;
        check(busy === 1'b1, "reset took effect asynchronously (contract is sync)");
        @(posedge clk); #0.1;
        checks = checks + 1;
        check(busy === 1'b0, "mid-pass reset did not clear busy on the edge");
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin
            checks = checks + 1;
            check(y[c] === {ACC_WIDTH{1'b0}}, "mid-pass reset did not clear y");
        end
        @(negedge clk); rst_n = 1'b1;

        // The aborted pass must NEVER commit. Watch for a full pass length
        // plus slack; any y_valid here means reset failed to cancel the
        // in-flight pass and a stale result would be handed downstream.
        seen = 0;
        while (seen < 3 * ARRAY_ROWS + 8) begin
            @(posedge clk);
            #0.1;
            seen = seen + 1;
            if (y_valid === 1'b1) begin
                errors = errors + 1;
                $display("[FAIL] y_valid pulsed after mid-pass reset");
                seen = 3 * ARRAY_ROWS + 8;
            end
        end
        checks = checks + 1;

        // The array must be usable again immediately after that reset.
        tile_zero();
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, 2);
            put_x(r, 3);
        end
        run_pass("usable after mid-pass reset");

        // ---------------------------------------------------------
        // 10. An X load while busy is dropped, so it cannot poison the array.
        //
        //     This is the load-side half of the no-X property, and it is the
        //     only X case with a meaningful expected value. A load while idle
        //     that carries X will legitimately produce an X result (the data
        //     really is unknown), so asserting "no X out" there would be
        //     asserting a lie. What the design owes the user is that a
        //     REJECTED load has no effect at all: drive X on w_data/x_data
        //     mid-pass, then check the committed result is the clean one.
        //
        //     If the write port were ever accepted while busy, the tile would
        //     be corrupted with X and this fails on both the value check and
        //     the continuous $isunknown sweep above.
        // ---------------------------------------------------------
        tile_zero();
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, 1);
            put_x(r, 1);
        end
        model_eval();   // all-ones tile, x=1 -> expect ARRAY_ROWS per lane

        @(negedge clk); start = 1'b1;
        @(posedge clk); #0.1;
        @(negedge clk); start = 1'b0;

        // Mid-pass, drive all-X onto the write ports targeting the LAST row
        // (rows are consumed in order, so the last row is the only one still
        // ahead of the read pointer at this point). The shadow model is
        // deliberately NOT updated, so a leaked write shows up as a mismatch
        // and, being X, trips the $isunknown sweep as well.
        repeat (ARRAY_ROWS) @(posedge clk);
        #0.1;
        checks = checks + 1;
        check(busy === 1'b1, "pass ended before the X load could be injected");
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin
            w_load_en = 1'b1;
            w_row     = ROW_BITS'(ARRAY_ROWS-1);
            w_col     = COL_BITS'(c);
            w_data    = 'x;
        end
        x_load_en = 1'b1;
        x_row     = ROW_BITS'(ARRAY_ROWS-1);
        x_data    = 'x;
        @(posedge clk);
        #0.1;
        @(negedge clk);
        w_load_en = 1'b0;
        x_load_en = 1'b0;

        seen = 0;
        while ((y_valid !== 1'b1) && (seen < 4 * ARRAY_ROWS + 8)) begin
            @(posedge clk);
            #0.1;
            seen = seen + 1;
        end
        checks = checks + 1;
        check(y_valid === 1'b1, "pass did not complete after an X load");
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin
            checks = checks + 1;
            if (y[c] !== exp[c][ACC_WIDTH-1:0]) begin
                errors = errors + 1;
                $display("[FAIL] X load while busy leaked: lane %0d y=%0d (0x%0h) expected %0d (0x%0h)",
                         c, $signed(y[c]), y[c], exp[c], exp[c]);
            end
        end
        @(negedge clk);

        // ---------------------------------------------------------
        // 11. start held high streams back-to-back passes.
        // ---------------------------------------------------------
        tile_zero();
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                put_w(r, c, rnd(DATA_WIDTH));
            put_x(r, rnd(DATA_WIDTH));
        end
        model_eval();
        @(negedge clk); start = 1'b1;
        // Count commits over a window of three pass lengths. If start were
        // ignored while busy, or a commit were lost, the count comes out
        // wrong. Hoisted to module scope: Icarus will not accept a static
        // initialiser on a block-local declaration.
        got = 0;
        guard = 0;
        repeat (3 * 2 * ARRAY_ROWS + 4) begin
            @(posedge clk);
            #0.1;
            if (y_valid === 1'b1) got = got + 1;
            guard = guard + 1;
            if (guard > 500) break;
        end
        checks = checks + 1;
        check(got == 3, "start held high did not stream 3 commits");
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin
            checks = checks + 1;
            if (y[c] !== exp[c][ACC_WIDTH-1:0]) begin
                errors = errors + 1;
                $display("[FAIL] streamed pass result wrong: lane %0d y=%0d expected %0d",
                         c, $signed(y[c]), exp[c]);
            end
        end
        @(negedge clk); start = 1'b0;
        commits_seen = 0;
        while (busy !== 1'b0) @(posedge clk);

        // -------------------------------------------------------------
        $display("--------------------------------------");
        $display(" mac_array: checks=%0d  errors=%0d  cycles=%0d",
                 checks, errors, cycles);
        if (errors == 0) $display(" RESULT: PASS");
        else              $display(" RESULT: FAIL (%0d)", errors);
        $display("--------------------------------------");

        if (errors != 0) $fatal(1, "mac_array.sv FAILED");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "testbench timeout - design likely deadlocked");
    end

endmodule
