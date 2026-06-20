# MacLCii project timing constraints (read after sys/sys_top.sdc).
#
# ----------------------------------------------------------------------------
# TG68 kernel multicycle — REQUIRED for reliable timing closure.
# ----------------------------------------------------------------------------
# The TG68 kernel (TG68KdotC_Kernel) is a clock-enabled CPU: it advances ONLY on
# clkena = phi1 && (s_state==7 || busstate==01)  (see rtl/tg68k/tg68k.v:43), and
# phi1 = clk16_en_p = !busPhase[0] (addrController_top.v) is high only on EVEN
# clk_sys phases. So clkena can never pulse on two consecutive clk_sys cycles —
# consecutive kernel updates are always >= 2 clk_sys periods apart. Every kernel
# register (including the inferred register-file RAM regfile_rtl_0/1 and its
# read-during-write bypass) takes its meaningful input from, and feeds, other
# clkena-gated kernel logic. So kernel-internal reg->reg paths genuinely have TWO
# clk_sys periods to settle, not one.
#
# Without this, STA over-constrains the kernel to a single clk_sys period (~30.8ns
# @ 32.5MHz). The CPU's long decode/datapath/regfile-bypass paths are ~33ns, so
# they "fail" (the worst, regfile WE->bypass, measured -2.699ns) yet are
# placement-fragile enough to *sometimes* squeak by (+0.2ns) — the design was
# closing timing by luck. Relaxing the genuinely-2-cycle kernel paths to 2 periods
# takes the worst kernel slack hugely positive; the design's real limiter becomes
# the framework ascal scaler (~+0.56ns), independent of the CPU and of the DDR3
# video work. See docs/handoff_ddr3_video_2026-06-06.md.
#
# Scope is kernel-INTERNAL only (-from kernel -to kernel): it deliberately does NOT
# touch the tg68k WRAPPER state machine (s_state/eCntr update on phi1|phi2 = every
# clk_sys = genuine 1-cycle) nor any CPU<->SDRAM/peripheral path (those sample at
# full clk_sys rate and must stay single-cycle). HW-validated by a clean boot to
# the Finder desktop (the CPU executes millions of instructions through these paths
# to boot; a wrong multicycle would corrupt/crash it).
set_multicycle_path -setup -end 2 -from [get_keepers {*TG68KdotC_Kernel*}] -to [get_keepers {*TG68KdotC_Kernel*}]
set_multicycle_path -hold  -end 1 -from [get_keepers {*TG68KdotC_Kernel*}] -to [get_keepers {*TG68KdotC_Kernel*}]

# ----------------------------------------------------------------------------
# CPU write-data -> SDRAM capture multicycle (clk_sys 32.5MHz -> clk_mem 65MHz).
# ----------------------------------------------------------------------------
# clk_sys (general[1], 32.5MHz, the CPU domain) and clk_mem (general[0], 65MHz,
# the sdram.v state machine on .clk_64) are a 2:1 pair off the SAME PLL, so STA
# analyzes clk_sys->clk_mem transfers synchronously and gives a register in the
# CPU domain only ONE 65MHz period (15.38ns) to reach a register in the sdram
# domain. The 68k write-data bus is exactly such a path: a kernel reg drives,
# combinationally, dout -> sdram_din -> sdram|sd_data[*] (the write-data output
# register). After the 030 MMU sync this cone runs kernel reg -> PMMU reg-read
# mux -> ALU adder -> data_write_mux -> dout, ~21.3ns of mostly routing at 95%
# ALM fill, so it misses the 15.38ns window (worst -6.18ns; the whole 16-bit
# bus = -77ns TNS). It is the ONLY clk_sys->clk_mem failure (address/control
# and the sdram->CPU read direction all close).
#
# Relaxing it to 2 clk_mem periods (30.76ns) is physically correct, not a paper
# fix: sd_data is loaded from din ONLY at t==STATE_CMD_CONT (state 2 of the
# 8-state, ~123ns sdram cycle, rtl/sdram.v:174), and during a write the 68k is
# stalled on DTACK so din is held stable for the WHOLE access (many clk_mem
# periods) before state 2 samples it. Independently, the launching kernel regs
# only advance on clkena (>= 2 clk_sys = 4 clk_mem periods apart, same basis as
# the kernel multicycle above), so din cannot change within a single clk_mem
# period regardless. Either way the 1-period-early edge would latch the same
# settled value, so -setup -end 2 is safe. Scope is -from clk_sys -to the
# sd_data registers only: it does NOT touch the clk_mem->sd_data load-enable
# (we_latch) path nor the address/command paths, which stay single-cycle.
set_multicycle_path -setup -end 2 \
    -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}] \
    -to   [get_keepers {*sdram:sdram|sd_data[*]~reg0}]
set_multicycle_path -hold  -end 1 \
    -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}] \
    -to   [get_keepers {*sdram:sdram|sd_data[*]~reg0}]
