// test_counter.sv — self-checking testbench for rtl/counter.sv
//
// This testbench FAILS LOUDLY. It does not print "PASS" and exit 0 while
// quietly tolerating a broken design. Non-zero exit status on any mismatch.
//   iverilog -g2012 -s test_counter -o build/sim.vvp tb/test_counter.sv rtl/counter.sv
//   vvp build/sim.vvp

`timescale 1ns / 1ps

module test_counter;

    parameter WIDTH = 4;
    parameter MOD   = 16;   // 2**WIDTH for WIDTH=4

    reg              clk;
    reg              rst_n;
    reg              en;
    wire [WIDTH-1:0] count;

    // Reference model: mirrors the design intent independently, so a bug
    // shared between DUT and testbench is much less likely than in a
    // hand-written expected-value list.
    reg [WIDTH-1:0] ref_count;

    reg [WIDTH-1:0] held;
    reg [WIDTH-1:0] pre_wrap;   // not named `before`: reserved in SystemVerilog

    integer errors;
    integer checks;

    counter #(.WIDTH(WIDTH)) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .count (count)
    );

    // 10 ns period: 5 ns half-period, 1 ns resolution.
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Reference model: mirrors the design intent independently, so a bug
    // shared between DUT and testbench is much less likely than in a
    // hand-written expected-value list. It models reset explicitly — a
    // reference that ignores reset disagrees with a DUT that honours it,
    // which fakes a failure.
    always @(posedge clk) begin
        if (!rst_n)  ref_count <= 0;
        else if (en) ref_count <= (ref_count + 1'b1) % MOD;
    end

    // Check after the NBA region settles, so we compare settled values and
    // never race the nonblocking assignment.
    always @(posedge clk) begin
        #0.1;
        checks = checks + 1;
        if (count !== ref_count) begin
            errors = errors + 1;
            $display("[FAIL] t=%0t count=%0d (0x%0h) expected %0d (0x%0h) en=%b rst_n=%b",
                     $time, count, count, ref_count, ref_count, en, rst_n);
        end
    end

    // Waveform for gtkwave; harmless under Verilator.
    initial begin
        $dumpfile("build/counter.vcd");
        $dumpvars(0, test_counter);
    end

    task check;
        input        cond;
        input [8*80-1:0] msg;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("[FAIL] %0s", msg);
            end
        end
    endtask

    initial begin
        rst_n     = 1'b0;
        en        = 1'b0;
        ref_count = 0;
        held      = 0;
        pre_wrap  = 0;
        errors    = 0;
        checks    = 0;
        repeat (2) @(posedge clk);

        // --- reset release ---
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk); #0.1;
        check(count === 0, "reset did not clear count");

        // --- count up through a full wrap cycle ---
        @(negedge clk); en = 1'b1;
        repeat (MOD) @(posedge clk);

        // --- hold with en low ---
        @(negedge clk); en  = 1'b0;
        #0.1 held = count;
        repeat (4) @(posedge clk);
        #0.1 check(count === held, "counter advanced while en=0");

        // --- wrap specifically: park one below modulus, step, expect 0 ---
        // MOD-1 increments from 0 lands on MOD-1, not MOD. Getting this wrong
        // is exactly the kind of testbench bug that fakes a DUT failure.
        @(negedge clk); en = 1'b1;
        repeat (MOD-1) @(posedge clk);
        @(negedge clk); en = 1'b0;
        #0.1 pre_wrap = count;
        @(negedge clk); en = 1'b1;
        @(posedge clk); #0.1;
        check(pre_wrap == MOD-1, "did not park at modulus-1 before wrap check");
        check(count === 0, "wrap broken: expected counter to return to 0");

        // --- reset asserted mid-count must clear ---
        @(negedge clk); en = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1'b0;
        @(posedge clk); #0.1;
        check(count === 0, "reset mid-count did not clear count");

        // --- reset is SYNCHRONOUS: asserting between clock edges must not
        //     clear the counter until the next posedge. Mutation testing
        //     showed an async-reset version of this design passes every
        //     other test, so this is the only check that pins the behaviour.
        @(negedge clk); rst_n = 1'b1; en = 1'b1;
        repeat (6) @(posedge clk);
        @(negedge clk); en = 1'b0; #0.1 held = count;

        rst_n = 1'b0;          // asserted mid-cycle, not on an edge
        #0.1;
        check(count === held, "reset cleared count asynchronously (should be sync)");

        @(posedge clk); #0.1;  // now the edge arrives, reset must take effect
        check(count === 0, "synchronous reset did not clear on the clock edge");
        rst_n = 1'b1;

        $display("--------------------------------------");
        $display(" checks=%0d  errors=%0d", checks, errors);
        if (errors == 0) $display(" RESULT: PASS");
        else              $display(" RESULT: FAIL (%0d)", errors);
        $display("--------------------------------------");

        if (errors != 0) $fatal(1, "counter.sv FAILED");
        $finish;
    end

    // Global guard: if the testbench deadlocks, fail instead of hanging CI.
    initial begin
        #100000;
        $fatal(1, "testbench timeout — design likely deadlocked");
    end

endmodule
