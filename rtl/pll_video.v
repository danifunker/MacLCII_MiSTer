// pll_video.v - dedicated pixel-clock PLL for the Mac LC V8 scanout.
//
// FIXED-PLL VARIANT (2026-07-07): runtime reconfiguration REMOVED. Plain General
// fractional altera_pll, single fixed 25.175 MHz output - VGA 640x480, 800x525
// total, 59.94 Hz (the headline fix; the V8 used to scan at clk_sys/2 = 16.25
// MHz = 38.7 Hz in every mode).
//
// Parameterized to MIRROR the project's proven main PLL (rtl/pll/pll_0002.v):
// pll_type/pll_subtype "General" so Quartus solves the VCO / counters / charge-
// pump / bandwidth automatically. The old form used pll_type("Cyclone V") with
// an explicit-counter block + a runtime reconfig core (pll_cfg) - that reconfig
// core was the HW black-screen cause: at 97% ALM density the reconfigurable
// pixel PLL had no placement margin and lost lock ("desktop then black").
//
// Runtime 12" RGB / Portrait monitor-switching is dropped until a separately
// bench-proven reconfig returns; it was OSD-unreachable anyway. For reference,
// the former per-monitor rates were VGA 25.175 / 12" 15.664 / Portrait 58.742.

`timescale 1 ps / 1 ps
module pll_video (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,          // pixel clock: fixed 25.175 MHz (VGA, 59.94 Hz)
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0("25.175000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("0 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst      (rst),
		.outclk   ({outclk_0}),
		.locked   (locked),
		.fboutclk ( ),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);
endmodule
