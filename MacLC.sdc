# MacLC project timing constraints (read after sys/sys_top.sdc).
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
