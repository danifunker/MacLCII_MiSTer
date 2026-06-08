// ============================================================================
// vram_bram.sv — On-chip dual-port framebuffer (VRAM) for the Mac LC V8 core.
//
// WHY: the Mac LC framebuffer was kept in external memory (shared SDRAM, then an
// HPS-DDR3 experiment). Both starved the video fetch (~64 of 160 words/line at
// 4bpp) — not from lack of *bandwidth* (4bpp needs only ~9 MB/s) but from bus
// sharing + read latency. On-chip BRAM is true dual-port and single-cycle, so the
// CPU can write port A while video reads port B every clock with zero contention,
// eliminating the wall for every Mac LC video mode that fits on-chip.
//
// SIZE: DEPTH = 196,608 words (384 KB) = the largest supported framebuffer,
// 16bpp @ 512x384. The DE10-Nano Cyclone V (5CSEBA6) has 553 M10K blocks; the
// rest of the design uses 73, so this (~384 blocks at 16-bit width) fits.
// 640x480 @ 16bpp is NOT a Mac LC mode and is out of scope.
//
// ADDRESSING: callers pass a *packed* word address. The V8 hardware scans the
// framebuffer at a fixed 1024-byte (512-word) stride for 1..8 bpp, but only the
// first `words_per_line` (= h_active*bpp/16) words of each line are visible. The
// caller packs out the stride gap (packed = line*words_per_line + col) so 640-wide
// modes fit in 384 KB; for 16bpp@512 (words_per_line=512) the packing degenerates
// to the natural 1:1 word offset.
//
// Single clk_sys domain => CPU writes and video reads are coherent with no CDC.
// Reads are registered (1-cycle latency) for clean M10K inference.
// ============================================================================
module vram_bram #(
    parameter integer DEPTH = 196608,   // 16bpp @ 512x384 = 384KB / 2 bytes
    parameter integer AW    = 18         // ceil(log2(DEPTH))
)(
    input             clk,

    // Port A — CPU read/write (byte-masked)
    input  [AW-1:0]   a_addr,
    input  [15:0]     a_din,
    input  [1:0]      a_be,     // {upper, lower} byte write strobes
    input             a_we,
    output reg [15:0] a_dout,

    // Port B — video read
    input  [AW-1:0]   b_addr,
    output reg [15:0] b_dout
);

    (* ramstyle = "M10K, no_rw_check" *)
    reg [15:0] mem [0:DEPTH-1];

    // Port A: byte-masked write + registered read (read-before-write).
    always @(posedge clk) begin
        if (a_we) begin
            if (a_be[0]) mem[a_addr][7:0]  <= a_din[7:0];
            if (a_be[1]) mem[a_addr][15:8] <= a_din[15:8];
        end
        a_dout <= mem[a_addr];
    end

    // Port B: registered read (video).
    always @(posedge clk) begin
        b_dout <= mem[b_addr];
    end

endmodule
