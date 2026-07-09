// TG68K_Cache_030_bram.sv — 68030-style I/D cache, BRAM edition (2026-07-09)
//
// Replaces TG68K_Cache_030.vhd (256B register-array caches) with 2KB+2KB
// direct-mapped caches whose tag/data arrays infer M10K block RAM. Written as
// native SystemVerilog so ONE source serves both Quartus (files via
// TG68K.qip) and Verilator (verilator/Makefile V_SRC) — no GHDL step.
//
// Key design decisions (see docs/resume_icache_enabled_2026-07-08.md and
// memory maclcii-cache-fill-fc7-berr-race for the history that forced them):
//
// 1. PIPT — physically indexed, physically tagged, FULL 32-bit physical tag
//    (phys[31:LINES_LOG+4]). Physical tags kill the logical-alias staleness
//    class (the old LOGICAL(+FC) tags let a write-through update one mapping's
//    line while a poller hit its stale alias forever). The tag must cover the
//    FULL 32 bits: a [23:0]-only tag conflated 32-bit slot-space probe
//    addresses ($FE000000 -> [23:0]=$000000) with RAM lines, serving cached
//    RAM data to probes that must bus-error (gate #3 wedge). The intentional
//    24/32-bit RAM/ROM mirror aliasing ($00A0xxxx vs $40A0xxxx = same ROM) is
//    handled by the ALLOCATE decode (wrapper fill_inhibit limits fills to the
//    true RAM/ROM windows), not by truncating tags: a mirror view that is
//    never filled simply misses to the bus, which is always correct.
//    Consequence for the integrator: FC no longer disambiguates CPU-space
//    accesses — the wrapper MUST NOT assert i_req/d_req for FC=7 cycles
//    (the ROM's moves-probe reads of $22000 must bus-error, never hit).
//
// 2. Synchronous (registered) lookup so Quartus infers M10K. The registered
//    read is only trusted when last cycle's read index equals the current
//    index (lookup_stable): after any index change there is one guaranteed
//    hit=0 cycle. The consumer (tg68k.v cache_read_hit -> clkena/s_state)
//    samples at phi1, 4 clk_sys after the kernel last changed the address,
//    so a stable lookup is always ready by the decision point. Sequential
//    accesses within one line keep the same index -> no re-warm penalty.
//
// 3. Valid bits live in fabric FFs (not BRAM) so CACR invalidation clears
//    the whole cache in one cycle. All CACR invalidate scopes (entry, page,
//    all) are implemented as CLEAR-ALL: the boot ROM/OS observed so far only
//    uses clear-all (forensics 2026-07-08: [CACR] INV scope=10), and
//    over-invalidation is always safe, merely un-warm. This also sidesteps
//    translating CAAR (a logical address) against physical tags.
//
// 4. ONE write port per RAM. Fill writes (whole line) and D write-through
//    updates (byte lanes) are muxed onto the single port — they are mutually
//    exclusive in time (fills run only while the kernel bus is parked idle;
//    write-through runs only during a kernel write cycle), and fill wins by
//    priority as a belt. Two write processes on one array make Quartus fall
//    back to a register array and blow the fit (the MacLC fetch_cache
//    lesson, and this file's whole reason to exist: the register-array
//    D-cache pushed the fit to 98% ALM and failed routing).
//
// 5. Write-allocate (cacr_wa) is accepted but ignored, and a D write miss
//    allocates nothing — matching the old module (WinUAE-style: memory is
//    written first; competing line fills on write misses steal bus slots).
//    The old module's 4KB-page alias-invalidation sweep on write misses is
//    DELETED: it was logical-alias insurance, obsolete under PIPT.
//
// Line/lane layout is IDENTICAL to the old module + fill engine convention:
// 128-bit line = 8 bus words, bus word w (addr[3:1]) at bits [16w +: 16];
// the 32-bit i_data/d_data_out groups are line[32g +: 32] for g = addr[3:2].

module TG68K_Cache_030_bram #(
	parameter LINES_LOG = 7,                // 2^7 = 128 lines x 16 B = 2 KB per cache
	parameter D_ENABLE  = 1'b0              // 0 = D-side fully un-elaborated (outputs tied).
	                                        // Quartus cannot sweep the dead D lane RAMs +
	                                        // write fan through a tied d_req alone (build #4
	                                        // 2026-07-09 kept ~1K ALMs of D residue); a
	                                        // generate gate removes them for real.
)(
	input  wire         clk,
	input  wire         nreset,             // async assert, sync release ok (matches old)

	// Cache control (CACR register fields)
	input  wire         cacr_ie,
	input  wire         cacr_de,
	input  wire         cacr_ifreeze,
	input  wire         cacr_dfreeze,
	input  wire         cacr_wa,            // accepted, ignored (no write-allocate)

	// CACR-driven invalidation. scope/addr are accepted for interface
	// compatibility; every request invalidates the WHOLE selected cache(s).
	input  wire         inv_req,
	input  wire [1:0]   cache_op_scope,     // unused (clear-all for all scopes)
	input  wire [1:0]   cache_op_cache,     // 00/11=both, 01=data, 10=insn
	input  wire [31:0]  cache_op_addr,      // unused

	// Instruction cache interface (addresses are PHYSICAL)
	input  wire [31:0]  i_addr_phys,
	input  wire         i_req,
	input  wire         i_cache_inhibit,    // blocks new allocation, not hits
	output wire [31:0]  i_data,
	output wire         i_hit,
	output wire         i_fill_req,
	output reg  [31:0]  i_fill_addr,
	input  wire [127:0] i_fill_data,
	input  wire         i_fill_valid,

	// Data cache interface (addresses are PHYSICAL)
	input  wire [31:0]  d_addr_phys,
	input  wire         d_req,
	input  wire         d_we,
	input  wire         d_cache_inhibit,
	input  wire [31:0]  d_data_in,
	output wire [31:0]  d_data_out,
	input  wire [3:0]   d_be,               // byte enables within the 32-bit group
	output wire         d_hit,
	output wire         d_fill_req,
	output wire [31:0]  d_fill_addr,   // wire: driven by assign in both generate arms
	input  wire [127:0] d_fill_data,
	input  wire         d_fill_valid
);

	localparam LINES = 1 << LINES_LOG;
	// FULL 32-bit physical tag (2026-07-09, gate #3 root cause): tagging on
	// phys[23:0] only CONFLATED 32-bit slot-space probe addresses with RAM —
	// $FE000000 truncates to [23:0]=$000000 = RAM line 0's tag, so slot
	// probes that must bus-error HIT cached RAM instead; the ROM saw phantom
	// hardware and wedged in comm-init (A49E74 SCC poll). Distinct 32-bit
	// physical addresses must be distinct tags; de-aliasing the intentional
	// 24/32-bit ROM/RAM mirrors is the allocate decode's job (fill_inhibit in
	// the wrapper), not the tag's.
	localparam TAG_W = 32 - LINES_LOG - 4;  // phys[31 : LINES_LOG+4]

	// ------------------------------------------------------------------
	// Instruction cache
	// ------------------------------------------------------------------
	wire [LINES_LOG-1:0] i_index = i_addr_phys[LINES_LOG+3:4];
	wire [TAG_W-1:0]     i_tag   = i_addr_phys[31:LINES_LOG+4];

	// no_rw_check: a read of the address being written this cycle may return
	// garbage — provably never consumed here (the valid-bit FF for a filled
	// line sets one cycle later, so a same-cycle lookup still reads valid=0;
	// write-through cycles never have their data output consumed, cache hits
	// are ~d_we). Without this Quartus preserves old-data RDW semantics by
	// falling back to a REGISTER array: +9K ALMs, fitter over device capacity
	// (4667/4191 LABs, 2026-07-09 first build of this file).
	// NOTE: plain "no_rw_check" ONLY — the combined "M10K, no_rw_check" string
	// silently disabled inference in Quartus 17 (build #3: i_data fell back to
	// a 2.1K-ALM register array while the plain-attributed arrays inferred).
	(* ramstyle = "no_rw_check" *)       reg [127:0]     i_data_ram [0:LINES-1];
	(* ramstyle = "no_rw_check" *)       reg [TAG_W-1:0] i_tag_ram  [0:LINES-1];
	reg  [LINES-1:0]     i_valid;

	// Fill bookkeeping (latched at miss time — the lookup address may move on
	// before the background fill completes; the old module's BUG #131 lesson)
	reg                  i_fill_pend;
	reg  [LINES_LOG-1:0] i_fill_idx_l;
	reg  [TAG_W-1:0]     i_fill_tag_l;

	// Sync lookup registers
	reg  [127:0]         i_rd_data_q;
	reg  [TAG_W-1:0]     i_rd_tag_q;
	reg  [LINES_LOG-1:0] i_index_q;

	// RAM process: one write port (fill only on the I side) + registered read
	always @(posedge clk) begin
		if (i_fill_valid) begin
			i_data_ram[i_fill_idx_l] <= i_fill_data;
			i_tag_ram [i_fill_idx_l] <= i_fill_tag_l;
		end
		i_rd_data_q <= i_data_ram[i_index];
		i_rd_tag_q  <= i_tag_ram [i_index];
		i_index_q   <= i_index;
	end

	// RDW shadow (2026-07-09, THE first-gate corruption root): when a fill
	// writes the very line being looked up (the common case — the CPU is
	// stalled wanting it), the same-cycle RAM read is no_rw_check GARBAGE and
	// lands in the q registers one cycle later — exactly when the valid FF
	// has just set. That cycle's "hit" compares the true tag against garbage:
	// ~14K fills/boot x 2^-13 tag width ≈ 1-2 statistically-guaranteed FALSE
	// HITS serving garbage instruction words per boot (the subtle boot
	// mis-execution + SCC-poll wedge of the first BRAM gate). Treat that one
	// cycle as lookup-unstable: no hit, no fill re-request, clean next cycle.
	reg  i_rdw_shadow;
	always @(posedge clk) i_rdw_shadow <= i_fill_valid && (i_fill_idx_l == i_index);
	wire i_lookup_stable = (i_index_q == i_index) && !i_rdw_shadow;
	wire i_tag_match     = i_lookup_stable && i_valid[i_index] && (i_rd_tag_q == i_tag);
	wire i_inv_sel       = inv_req && (cache_op_cache != 2'b01);   // insn or both

	assign i_hit      = cacr_ie && i_req && i_tag_match;
	assign i_fill_req = i_fill_pend;

	always @(posedge clk or negedge nreset) begin
		if (!nreset) begin
			i_valid     <= {LINES{1'b0}};
			i_fill_pend <= 1'b0;
			i_fill_addr <= 32'd0;
		end else begin
			if (i_fill_valid) begin
				i_valid[i_fill_idx_l] <= 1'b1;
				i_fill_pend           <= 1'b0;
			end
			// Miss -> request a background fill (once; the wrapper services it
			// at the next kernel-idle bus window). lookup_stable gates a false
			// miss on the first cycle after an index change.
			if (i_req && cacr_ie && !i_cache_inhibit && !i_fill_pend &&
			    i_lookup_stable && !i_tag_match && !cacr_ifreeze) begin
				i_fill_pend  <= 1'b1;
				i_fill_idx_l <= i_index;
				i_fill_tag_l <= i_tag;
				i_fill_addr  <= {i_addr_phys[31:4], 4'b0000};
			end
			if (i_fill_pend && cacr_ifreeze)
				i_fill_pend <= 1'b0;                     // freeze cancels a pending fill
			// Invalidate LAST so a same-cycle fill completion cannot revive a
			// line the flush is killing.
			if (i_inv_sel)
				i_valid <= {LINES{1'b0}};
		end
	end

	// 32-bit group select by phys[3:2] (same mapping as the old module)
	assign i_data = (i_addr_phys[3:2] == 2'b00) ? i_rd_data_q[31:0]   :
	                (i_addr_phys[3:2] == 2'b01) ? i_rd_data_q[63:32]  :
	                (i_addr_phys[3:2] == 2'b10) ? i_rd_data_q[95:64]  :
	                                              i_rd_data_q[127:96];

	// ------------------------------------------------------------------
	// Data cache — whole side behind generate (see D_ENABLE above)
	// ------------------------------------------------------------------
	generate if (D_ENABLE) begin : gen_d
	wire [LINES_LOG-1:0] d_index = d_addr_phys[LINES_LOG+3:4];
	wire [TAG_W-1:0]     d_tag   = d_addr_phys[31:LINES_LOG+4];

	// D data array = SIXTEEN independent byte-lane RAMs. Quartus 17 does NOT
	// infer byte-enabled block RAM from the masked for-loop write form (build
	// #2 2026-07-09: i/d tag + I data all became altsyncram, d_data stayed a
	// register array and the fitter needed 4639/4191 LABs). One 8-bit lane
	// per RAM needs no byte enables at all; each lane lives in its own
	// generate scope with its own single write process (the one-driver rule).
	(* ramstyle = "no_rw_check" *)       reg [TAG_W-1:0] d_tag_ram  [0:LINES-1];
	reg  [LINES-1:0]     d_valid;

	reg                  d_fill_pend;
	reg  [LINES_LOG-1:0] d_fill_idx_l;
	reg  [TAG_W-1:0]     d_fill_tag_l;
	reg  [31:0]          d_fill_addr_r;
	assign d_fill_addr = d_fill_addr_r;

	wire [127:0]         d_rd_data_q;    // concatenated from the 16 lane RAMs
	reg  [TAG_W-1:0]     d_rd_tag_q;
	reg  [LINES_LOG-1:0] d_index_q;

	// Same RDW shadow as the I side (fill-write vs lookup of the same line).
	// Write-through RDW needs no shadow: its garbage q window dies ≥2 cycles
	// before any read access's decision point (bus cycles don't overlap).
	reg  d_rdw_shadow;
	always @(posedge clk) d_rdw_shadow <= d_fill_valid && (d_fill_idx_l == d_index);
	wire d_lookup_stable = (d_index_q == d_index) && !d_rdw_shadow;
	wire d_tag_match     = d_lookup_stable && d_valid[d_index] && (d_rd_tag_q == d_tag);
	wire d_inv_sel       = inv_req && (cache_op_cache != 2'b10);   // data or both

	// Write-through update on a write HIT: byte-lane write into the hit line.
	// Level-held while the (multi-clk) kernel write cycle is active — the
	// rewrite is idempotent (same data, same lanes), exactly like the old
	// module's per-clk write-hit update.
	wire d_wt_strobe = d_req && d_we && cacr_de && d_tag_match;

	// One write port per lane RAM, two sources: fill (all lanes, priority) or
	// write-through (up to 4 byte lanes at the addressed group).
	wire [15:0]  d_wr_lane_en = d_fill_valid ? 16'hFFFF
	                                         : ({12'b0, d_be} << {d_addr_phys[3:2], 2'b00});
	wire [127:0] d_wr_data    = d_fill_valid ? d_fill_data : {4{d_data_in}};
	wire [LINES_LOG-1:0] d_wr_idx = d_fill_valid ? d_fill_idx_l : d_index;
	wire         d_wr_en      = d_fill_valid || d_wt_strobe;

	// (plain for-generate: this whole D section already sits inside the
	// D_ENABLE generate block, and generate regions do not nest)
	genvar gl;
	for (gl = 0; gl < 16; gl = gl + 1) begin : d_lane
		(* ramstyle = "no_rw_check" *) reg [7:0] ram [0:LINES-1];
		reg [7:0] q;
		always @(posedge clk) begin
			if (d_wr_en && d_wr_lane_en[gl])
				ram[d_wr_idx] <= d_wr_data[gl*8 +: 8];
			q <= ram[d_index];
		end
		assign d_rd_data_q[gl*8 +: 8] = q;
	end

	always @(posedge clk) begin
		if (d_fill_valid)
			d_tag_ram[d_fill_idx_l] <= d_fill_tag_l;
		d_rd_tag_q  <= d_tag_ram [d_index];
		d_index_q   <= d_index;
	end

	assign d_hit      = cacr_de && d_req && d_tag_match;
	assign d_fill_req = d_fill_pend;

	always @(posedge clk or negedge nreset) begin
		if (!nreset) begin
			d_valid     <= {LINES{1'b0}};
			d_fill_pend <= 1'b0;
			d_fill_addr_r <= 32'd0;
		end else begin
			if (d_fill_valid) begin
				d_valid[d_fill_idx_l] <= 1'b1;
				d_fill_pend           <= 1'b0;
			end
			// READ miss -> background fill. Write misses allocate nothing.
			if (d_req && cacr_de && !d_we && !d_cache_inhibit && !d_fill_pend &&
			    d_lookup_stable && !d_tag_match && !cacr_dfreeze) begin
				d_fill_pend  <= 1'b1;
				d_fill_idx_l <= d_index;
				d_fill_tag_l <= d_tag;
				d_fill_addr_r <= {d_addr_phys[31:4], 4'b0000};
			end
			if (d_fill_pend && cacr_dfreeze)
				d_fill_pend <= 1'b0;
			if (d_inv_sel)
				d_valid <= {LINES{1'b0}};
		end
	end

	assign d_data_out = (d_addr_phys[3:2] == 2'b00) ? d_rd_data_q[31:0]   :
	                    (d_addr_phys[3:2] == 2'b01) ? d_rd_data_q[63:32]  :
	                    (d_addr_phys[3:2] == 2'b10) ? d_rd_data_q[95:64]  :
	                                                  d_rd_data_q[127:96];

	// A D read that hits the line CURRENTLY being written through cannot
	// happen: d_hit consumers gate on ~d_we (reads only), and the registered
	// d_rd_data_q lags a same-index write-through by one cycle — but a read
	// access never overlaps a write access (one kernel bus cycle at a time),
	// and the read's own stable-lookup window re-reads the updated line.

	end else begin : gen_d_off
		assign d_hit      = 1'b0;
		assign d_fill_req = 1'b0;
		assign d_fill_addr = 32'd0;
		assign d_data_out = 32'd0;
	end endgenerate

	wire _unused = &{1'b0, cacr_wa, cache_op_scope, cache_op_addr,
	                 d_we, d_cache_inhibit, cacr_dfreeze, |d_data_in, |d_be, 1'b0};

endmodule
