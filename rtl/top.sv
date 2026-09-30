// top.sv — iCEBreaker board top level (iCE40-UP5K, package sg48)
//
// Free-running counter with a visible bring-up pattern. This exists so that
// `make fpga` place-and-routes the ACTUAL design under test (rtl/counter.sv),
// not a decorative blinker — the day-0 milestone is a flow proof, and a flow
// proof of a different circuit proves nothing about ours.
//
// ## iCEBreaker pin assignments (see constraints/icebreaker.pcf for provenance)
//   clk_12mhz  : 35   12 MHz oscillator
//   led_red_n  : 11   on-board red   LED (active low)
//   led_green_n: 37   on-board green LED (active low)
//   btn_n      : 10   on-board button (active low)
//   rgb_*_n    : 39/40/41  external RGB LED driver (active low)
//
// ## What you should see on the board
//   Red and green LEDs blink at different rates, both derived from the counter,
//   and stop while btn_n is held (reset). That is enough to confirm the clock,
//   the pin constraints, the counter, and the reset path on real silicon.

module top #(
    // Counter width. A real parameter (not a localparam) so that
    // `make lint WIDTH=8` / `verilator -GWIDTH=8` and `chparam` can override
    // it and drive the width of the design under test.
    parameter WIDTH = 4,
    // 12 MHz / 2**23 ~= 1.43 Hz for the green LED, and the red LED is the
    // next bit down, so they blink at visibly different rates.
    parameter DIV_BITS = 23
) (
    input  wire clk_12mhz,
    input  wire btn_n,          // active low; held low = reset
    output wire led_green_n,
    output wire led_red_n,
    output wire rgb_red_n,
    output wire rgb_grn_n,
    output wire rgb_blu_n
);

    // The LED pattern below addresses count[3:0] directly, so a narrower WIDTH
    // would silently read out-of-range bits. Fail loudly at elaboration instead.
    if (WIDTH < 4) begin : g_bad_width
        $error("top: WIDTH must be >= 4 (got %0d); the LED pattern needs count[3:0]", WIDTH);
    end

    // The design under test. Held in reset while the button is pressed.
    wire [WIDTH-1:0] count;
    wire             rst_n = btn_n;
    wire             en    = 1'b1;

    counter #(.WIDTH(WIDTH)) dut (
        .clk   (clk_12mhz),
        .rst_n (rst_n),
        .en    (en),
        .count (count)
    );

    // Divide the 12 MHz input down so the counter's low bits are visible as a
    // slow human-scale blink instead of an invisible 3 MHz hash.
    reg [DIV_BITS-1:0] prescale;
    always @(posedge clk_12mhz) begin
        prescale <= prescale + 1'b1;
    end

    // Blink when the prescaler wraps. Both LEDs come from counter bits, so a
    // stuck or misconstrained bit is visible on the board.
    assign led_green_n = ~(prescale[DIV_BITS-1] & count[3]);
    assign led_red_n   = ~(prescale[DIV_BITS-1] & count[2]);

    // Light the RGB driver with the low counter bits as a static signature.
    assign rgb_red_n = ~count[1];
    assign rgb_grn_n = ~count[0];
    assign rgb_blu_n = ~(count[3] ^ count[2]);

endmodule
