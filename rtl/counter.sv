// counter.sv — parameterized up-counter with enable and wrap
//
// ## Interface
//   clk    : rising-edge clock, posedge triggers all state changes
//   rst_n  : synchronous, active-low. When low, `count` is held at 0.
//   en     : when high, `count` increments on the active clock edge
//   count  : WIDTH bits, wraps modulo 2**WIDTH
//
// ## Timing
//   Tclk -> Tq(count) : 1 clock edge. No combinational path input->output.
//   Setup required on en/rst_n relative to the active edge (standard FF timing).
//
// ## Why this module exists
//   It is the day-0 flow probe, not a useful design. It exercises:
//     - lint (Verilator), simulation (Icarus + VCD), synthesis (Yosys),
//       place & route (nextpnr-ice40), and the SkyWater GDS path.
//   It is deliberately tiny so that when something breaks, the cause is the
//   toolchain and never the design.
//
// ## Measured
//   (filled in after `make syn` / `make fpga` run)

`timescale 1ns / 1ps

module counter #(
    parameter WIDTH = 4
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              en,
    output reg  [WIDTH-1:0]  count
);

    // Natural wraparound: the counter's own width is the modulus. No masking
    // or saturation logic, so this maps to plain D flip-flops with no
    // combinational logic in the feedback path.
    always @(posedge clk) begin
        if (!rst_n) begin
            count <= {WIDTH{1'b0}};
        end else if (en) begin
            count <= count + 1'b1;
        end
    end

endmodule
