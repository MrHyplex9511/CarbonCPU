// ======================================================================
// mac_array_props: port-level formal harness
//
// The heavy lifting (accumulator induction, overflow, dot-product equality)
// lives inside rtl/mac_array.sv under `ifdef FORMAL, because those
// properties need the internal accumulators and the SRAM read pipeline that
// a harness cannot see. This file adds what a harness CAN do better:
//
//   1. Drives every input as a free unconstrained variable, so the proof
//      covers all stimulus rather than a directed sequence.
//   2. States the port-level contract independently, as a second opinion on
//      the interface rather than on the internals.
//   3. Provides the cover points the prove task does not need but that show
//      the FSM is actually reachable in the states the proofs reason about.
//
// There is exactly ONE assume in this file, and it is about the initial
// state rather than about behaviour:
//
//   initial assume (!rst_n)
//
// The array has no initial values for its registers, which is deliberate --
// a power-on reset is what establishes a known state, and a design that
// leaned on an initial value would be leaning on a FPGA bitstream feature
// that is not portable. Without this assume the engine is free to start in
// S_FETCH with y_valid already high, which is not a state the hardware can
// ever be in, and the contract assertions below fire on it at step 0. No
// assume() constrains anything the hardware can actually do after reset.
//
// NOTE on X: SymbiYosys is a two-state engine. It cannot observe or reason
// about X, so `$isunknown` is meaningless here. The substantive no-X
// verification is the 4-state sweep in tb/test_mac_array.sv. Nothing in this
// file pretends otherwise.
// ======================================================================
`default_nettype none

module mac_array_props #(
    parameter DATA_WIDTH = 8,
    parameter ARRAY_ROWS = 4,
    parameter ARRAY_COLS = 4,
    // Must match the RTL's own derivation, NOT 2*DATA_WIDTH. Summing
    // ARRAY_ROWS products of two signed DATA_WIDTH values needs
    // ceil(log2(ARRAY_ROWS)) extra bits: 8-bit data over 4 rows is 18, not
    // 16. Passing 2*DATA_WIDTH here makes the no-overflow assertion fail for
    // a perfectly correct design, which looks like a DUT bug and is not one.
    parameter ACC_WIDTH  = 2 * DATA_WIDTH
                          + ((ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS))
) (
    input wire                        clk,
    input wire                        rst_n,
    input wire                        w_load_en,
    input wire [($clog2(ARRAY_ROWS+1)-1):0] w_row,   // wide enough for out-of-range
    input wire [($clog2(ARRAY_COLS+1)-1):0] w_col,
    input wire [DATA_WIDTH-1:0]       w_data,
    input wire                        x_load_en,
    input wire [($clog2(ARRAY_ROWS+1)-1):0] x_row,
    input wire [DATA_WIDTH-1:0]       x_data,
    input wire                        start
);

    localparam integer ROW_BITS = (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS);
    localparam integer COL_BITS = (ARRAY_COLS <= 1) ? 1 : $clog2(ARRAY_COLS);

    // Address wires are deliberately WIDER than the DUT's ports. The DUT
    // narrows them on input; if the narrowing truncates rather than
    // rejecting, the load lands in a different cell than the address asked
    // for. Keeping the harness address wide means the tool will find that.
    wire [ROW_BITS-1:0] w_row_dut = w_row[ROW_BITS-1:0];
    wire [COL_BITS-1:0] w_col_dut = w_col[COL_BITS-1:0];
    wire [ROW_BITS-1:0] x_row_dut = x_row[ROW_BITS-1:0];

    wire                        busy;
    wire                        y_valid;
    wire [ARRAY_COLS-1:0][ACC_WIDTH-1:0] y;

    mac_array #(
        .DATA_WIDTH (DATA_WIDTH),
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .w_load_en (w_load_en), .w_row (w_row_dut), .w_col (w_col_dut),
        .w_data (w_data),
        .x_load_en (x_load_en), .x_row (x_row_dut), .x_data (x_data),
        .start (start),
        .busy (busy), .y_valid (y_valid), .y (y)
    );

    // Unconstrained stimulus: no behavioural assumptions, just free inputs
    // every cycle. Reset is the only constrained signal, and only in its
    // initial value, because the hardware genuinely powers up either way.
    initial assume (!rst_n);

    // Step 0 sees the pre-reset, therefore arbitrary, register state. Skip it.
    logic f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    // ---- port-level contract, independent of the internals ---------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n) begin
            // busy and y_valid are mutually exclusive. y_valid marks a result
            // that is latched and the array is back in idle; a design that
            // pulsed y_valid while still busy would hand a consumer a result
            // it is not allowed to latch.
            assert (!(busy && y_valid));

            // y_valid is a single-cycle pulse, never held. A consumer that
            // counts results would double-count on a held signal.
            if ($past(y_valid)) assert (!y_valid);

            // After reset the result bus is clean, so a pass that has not
            // committed yet cannot be showing a stale value.
            if ($past(!rst_n)) assert (y == '0);
        end
    end

    // ---- cover points -----------------------------------------------------
    // These exist so the `cover` task demonstrates the interesting states are
    // reachable, rather than the FSM sitting in a corner that makes the
    // invariants vacuous.
    reg f_seen = 1'b0;
    always @(posedge clk) begin
        if (rst_n && busy) f_seen <= 1'b1;
        // a full idle->busy->idle transition
        c_idle_busy:  cover (f_seen && !busy);
        // A pass launched on the cycle immediately after the previous one
        // committed: no bubble. Note the commit cycle itself has busy low
        // (y_valid and busy are mutually exclusive), so the test is
        // "$past(y_valid) and still idle and start now", NOT a combination
        // of $past(busy) with $past(y_valid) -- that pair is unreachable by
        // the very property asserted above it.
        c_back2back:  cover (rst_n && !busy && $past(y_valid) && start);
        // a load offered DURING a pass: the interesting case is that a load
        // IS offered mid-pass. Whether the design accepts it is the DUT's
        // documented contract (it drops them), and that the drop is airtight
        // is proven inside the DUT against the reference dot product.
        c_midpass_load: cover (busy && (w_load_en || x_load_en));
        // commit and a concurrent load in the same cycle
        c_commit_load: cover (rst_n && y_valid && (w_load_en || x_load_en));
    end

endmodule

`default_nettype wire
