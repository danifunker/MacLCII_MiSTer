//============================================================================
//  Macintosh LC
//
//  Based on MacPlus core by Sorgelig
//  Copyright (C) 2025-2026 Dani Sarfati
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [45:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output   [7:0] VGA_R,
	output   [7:0] VGA_G,
	output   [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER, 
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);
	assign ADC_BUS  = 'Z;
	assign USER_OUT = '1;

	assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
	assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

	assign LED_USER  = dio_download || (disk_act ^ |diskMotor);
	assign LED_DISK  = 0;
	assign LED_POWER = 0;
	assign BUTTONS   = 0;
	assign VGA_SCALER= 0;
	assign VGA_DISABLE = 0;
	assign HDMI_FREEZE = 0;
	assign HDMI_BLACKOUT = 0;
	assign HDMI_BOB_DEINT = 0;

	wire [1:0] ar = status[8:7];
	video_freak video_freak
	(
		.*,
		.VGA_DE_IN(VGA_DE),
		.VGA_DE(),

		.ARX((!ar) ? 12'd256 : (ar - 1'd1)),
		.ARY((!ar) ? 12'd171 : 12'd0),
		.CROP_SIZE(0),
		.CROP_OFF(0),
		.SCALE(status[13:12])
	);
	
	`include "build_id.v"
	localparam CONF_STR = {
		"MACLC;UART115200;",
		"-;",
		"F1,DSK,Mount Pri Floppy;",
		"F2,DSK,Mount Sec Floppy;",
		"-;",
		"SC0,IMGVHD,Mount SCSI-6;",
		"SC1,IMGVHD,Mount SCSI-5;",
		"-;",
		"O78,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
		"OCD,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
		"OA,Monitor,640x480 VGA,512x384 12in RGB;",
		"-;",
		"O4,Memory,2MB,10MB;",
		"-;",
		"R0,Reset & Apply CPU+Memory;",
		"V,v",`BUILD_DATE
	};

	////////////////////   CLOCKS   ///////////////////

	wire clk_sys, clk_mem;
	wire pll_locked;

	pll pll
	(
		.refclk(CLK_50M),
		.outclk_0(clk_mem),
		.outclk_1(clk_sys),
		.locked(pll_locked)
	);

	reg       status_mem = 1'b1;
	localparam [1:0] status_cpu = 2'b10; // 68020
	reg       n_reset = 0;
	// Mac LC always runs at C15M (~15.67 MHz) - use 16 MHz clock enables
	always @(posedge clk_sys) begin
		reg [15:0] rst_cnt;

		if (clk8_en_p) begin
			// various sources can reset the mac
			// NOTE: Do NOT include ~_cpuReset_o here — the CPU executes the RESET
			// instruction during boot to reset peripherals, which would cause an
			// infinite reset loop if fed back to the system reset.
			if(~pll_locked || status[0] || buttons[1] || RESET || dio_download) begin
				rst_cnt <= '1;
				n_reset <= 0;
			end
			else if(rst_cnt) begin
				rst_cnt    <= rst_cnt - 1'd1;
				status_mem <= status[4];
			end
			else begin
				n_reset <= 1;
			end
		end
	end

	///////////////////////////////////////////////////

	localparam SCSI_DEVS = 2;

	// the status register is controlled by the on screen display (OSD)
	wire [31:0] status;
	wire  [1:0] buttons;
	wire [31:0] sd_lba[SCSI_DEVS];
	wire  [SCSI_DEVS-1:0] sd_rd;
	wire  [SCSI_DEVS-1:0] sd_wr;
	wire  [SCSI_DEVS-1:0] sd_ack;
	wire            [7:0] sd_buff_addr;
	wire           [15:0] sd_buff_dout;
	wire           [15:0] sd_buff_din[SCSI_DEVS];
	wire                  sd_buff_wr;
	wire  [SCSI_DEVS-1:0] img_mounted;
	wire           [63:0] img_size;
	wire        ioctl_write;
	reg         ioctl_wait = 0;
	wire [10:0] ps2_key;
	wire [24:0] ps2_mouse;
	wire        capslock;

	wire [24:0] ioctl_addr;
	wire [15:0] ioctl_data;

	wire [32:0] TIMESTAMP;

	hps_io #(.CONF_STR(CONF_STR), .VDNUM(SCSI_DEVS), .WIDE(1)) hps_io
	(
		.clk_sys(clk_sys),
		.HPS_BUS(HPS_BUS),

		.buttons(buttons),
		.status(status),

		.sd_lba(sd_lba),
		.sd_rd(sd_rd),
		.sd_wr(sd_wr),
		.sd_ack(sd_ack),

		.sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr),
		
		.img_mounted(img_mounted),
		.img_size(img_size),

		.ioctl_download(dio_download),
		.ioctl_index(dio_index),
		.ioctl_wr(ioctl_write),
		.ioctl_addr(ioctl_addr),
		.ioctl_dout(ioctl_data),
		.ioctl_wait(ioctl_wait),

		.TIMESTAMP(TIMESTAMP),

		.ps2_key(ps2_key),
		.ps2_kbd_led_use(3'b001),
		.ps2_kbd_led_status({2'b00, capslock}),

		.ps2_mouse(ps2_mouse)
	);

	assign CLK_VIDEO = clk_sys;
	assign CE_PIXEL  = v8_ce_pix;

	// (Former on-screen debug HUD removed — boot reaches the floppy screen on
	// hardware. Signal-level debug is preserved via the SignalTap `stp_*` keeps
	// below and the dataController/v8_video debug telemetry outputs.)

	// Video Output — straight V8 video, no overlays.
	assign VGA_R  = v8_vga_r;
	assign VGA_G  = v8_vga_g;
	assign VGA_B  = v8_vga_b;
	assign VGA_DE = v8_de;
	assign VGA_VS = v8_vsync;
	assign VGA_HS = v8_hsync;
	assign VGA_F1 = 0;
	assign VGA_SL = 0;

	// ASC samples drive AUDIO_L/R directly (Commit C). Legacy DMA gone.
	assign AUDIO_L = asc_sample_l;
	assign AUDIO_R = asc_sample_r;
	assign AUDIO_S = 1;
	assign AUDIO_MIX = 0;

	// Mac LC memory configuration
	// V8 RAM config byte (MAME encoding):
	//   Bits 7:6 = SIMM bank A size (00=0MB, 01=2MB, 10=4MB, 11=8MB)
	//   Bit 5 = Motherboard bank B (0=4MB, 1=2MB)
	//   Bit 2 = Always set on read (handled in pseudovia)
	// The Mac LC has 2MB soldered (bank B, bit5=1) plus TWO 30-pin SIMM sockets
	// (bank A). The V8 reports bank A as a single linear size; "8MB" bank A is
	// physically two 4MB SIMMs. Populated configs:
	//   2MB  = $24  (2MB board, no SIMMs)
	//   4MB  = $64  (2MB board + 2MB SIMM bank A)
	//   6MB  = $A4  (2MB board + 4MB SIMM bank A)
	//   10MB = $E4  (2MB board + 4MB + 4MB SIMMs => 8MB bank A)
	// NOTE: currently only the 2MB config is validated against MAME (-ramsize 2M).
	// The 10MB path is not yet verified — see docs and addrController_top.v.
	wire [7:0] configRAMSize = status[4] ? 8'hE4 : 8'h24; // 1=10MB (2MB board + 4MB+4MB SIMM), 0=2MB (board only)
	wire [7:0] pvia_ram_config_out;   // Active RAM config from pseudovia
	wire       pvia_ram_configured;   // ROM has programmed V8 RAM config ($0 mirror enable)
				  
	// Serial Ports
	wire serialOut;
	wire serialIn;
	wire serialCTS = 1'b1; // Idle/deasserted when no serial device connected
	wire serialRTS;

	// V8 Video system wires
	wire [21:0] v8_video_addr;
	wire v8_hsync, v8_vsync, v8_hblank, v8_vblank, v8_de;
	wire v8_ce_pix;
	wire [7:0] v8_vga_r, v8_vga_g, v8_vga_b;
	wire [7:0] ariel_pixel_addr;
	wire [23:0] ariel_palette_data;
	wire [7:0] ariel_reg_dout;
	wire selectAriel;      // From address decoder
	wire selectPseudoVIA;  // From address decoder
	wire selectVRAM;       // From address decoder
	wire [7:0] pseudovia_dout;
	wire pseudovia_irq;

	// GEMINI: Force serialIn to 1 (Idle) to prevent SCC Break detection loop in ROM
	// assign serialIn =  UART_RXD;
	assign serialIn = 1'b1; 
	assign UART_TXD = serialOut;
	assign UART_RTS = serialRTS ;
	assign UART_DTR = UART_DSR;


	// interconnects
	// CPU
	wire clk8, _cpuReset, _cpuReset_o, _cpuUDS, _cpuLDS, _cpuRW, _cpuAS;
	wire clk8_en_p, clk8_en_n;
	wire clk16_en_p, clk16_en_n;
	// V8 SCSI_PCLK / SCC RTxC source — see rtl/v8_clocks.sv and plan_040526.md Step 5.
	wire scsi_pclk_en;
	v8_clocks v8_clocks_inst (
		.clk_sys     (clk_sys),
		.reset       (~n_reset),
		.scsi_pclk_en(scsi_pclk_en)
	);
	wire _cpuVMA, _cpuVPA, _cpuDTACK;
	wire E_rising, E_falling;
	wire [2:0] _cpuIPL;
	wire [2:0] cpuFC;
	wire [7:0] cpuAddrHi;
	wire [31:0] cpuAddr;
	assign cpuAddr[0] = 1'b0;
	wire [7:0]  cpuAddrFullHi = cpuAddr[31:24];
	wire [15:0] cpuDataOut;

	// RAM/ROM
	wire _romOE;
	wire _ramOE, _ramWE;
	wire _memoryUDS, _memoryLDS;
	wire videoBusControl;
	wire dioBusControl;
	wire cpuBusControl;
	wire [22:0] memoryAddr;  // 23-bit SDRAM word address from address controller
	wire [15:0] memoryDataOut;
	wire memoryLatch;
	// Video latch: only pulse when memoryLatch AND in video bus cycle
	wire v8_video_latch = memoryLatch && videoBusControl;
	// peripherals
	wire pds_slot_irq = 1'b0;  // PDS slot interrupt — single point for future PDS work
	wire vid_alt;
	wire memoryOverlayOn, selectSCSI, selectSCC, selectIWM, selectVIA, selectRAM, selectROM, selectASC, selectUnmapped;
	wire [23:0] overlay_trigger_addr;
	wire [15:0] dataControllerDataOut;

	// ========== SignalTap debug probes ==========
	// Active-preserved copies so Quartus keeps them visible to SignalTap.
	wire        stp_cpuReset      = _cpuReset              /* synthesis keep */;
	wire        stp_cpuAS         = _cpuAS                 /* synthesis keep */;
	wire        stp_cpuRW         = _cpuRW                 /* synthesis keep */;
	wire [23:1] stp_cpuAddr       = cpuAddr[23:1]          /* synthesis keep */;
	wire        stp_overlay       = memoryOverlayOn        /* synthesis keep */;
	wire        stp_selectROM     = selectROM              /* synthesis keep */;
	wire        stp_selectRAM     = selectRAM              /* synthesis keep */;
	wire [22:0] stp_memAddr       = memoryAddr             /* synthesis keep */;
	wire        stp_memLatch      = memoryLatch            /* synthesis keep */;
	wire        stp_cpuBusCtl     = cpuBusControl          /* synthesis keep */;
	wire        stp_romOE         = _romOE                 /* synthesis keep */;
	wire        stp_ramOE         = _ramOE                 /* synthesis keep */;
	wire        stp_dtack         = _cpuDTACK              /* synthesis keep */;
	wire        stp_dtack_en      = dtack_en               /* synthesis keep */;
	wire [15:0] stp_dataOut       = dataControllerDataOut  /* synthesis keep */;
	// V8 video debug signals (preserved for SignalTap / JTAG probes)
	wire [31:0] stp_v8_latch_cnt  = v8_dbg_latch_count     /* synthesis keep */;
	wire [15:0] stp_v8_last_data  = v8_dbg_last_data       /* synthesis keep */;
	wire [21:0] stp_v8_last_addr  = v8_dbg_last_addr       /* synthesis keep */;
	wire [15:0] stp_v8_nonzero    = v8_dbg_nonzero_count   /* synthesis keep */;
	wire [2:0]  stp_v8_mode       = v8_video_mode          /* synthesis keep */;
	wire [3:0]  stp_v8_monid      = v8_monitor_id          /* synthesis keep */;
	wire        stp_v8_de         = v8_de                  /* synthesis keep */;
	wire        stp_v8_vsync      = v8_vsync               /* synthesis keep */;
	wire        stp_v8_vlatch     = v8_video_latch         /* synthesis keep */;

	// floppy disk image interface
	wire dskReadAckInt;
	wire [21:0] dskReadAddrInt;
	wire dskReadAckExt;
	wire [21:0] dskReadAddrExt;

	// dtack generation for 16 MHz mode
	reg  dtack_en, cpuBusControl_d;
	always @(posedge clk_sys) begin
		if (!_cpuReset) begin
			dtack_en <= 0;
		end
		else begin
			cpuBusControl_d <= cpuBusControl;
			if (_cpuAS) dtack_en <= 0;
			// VRAM is SDRAM-backed and reads via the same cpu-slot as RAM,
			// so it must take the slot-aligned DTACK path (cpuBusControl rising
			// edge), NOT the immediate !ROM&!RAM peripheral path. Excluding
			// selectVRAM here stops DTACK asserting before the SDRAM cpu-slot
			// commits the read/write (was truncating longword writes / sampling
			// stale data on the old VPA routing).
			if (!_cpuAS & ((!cpuBusControl_d & cpuBusControl) | (!selectROM & !selectRAM & !selectVRAM))) dtack_en <= 1;
		end
	end

	// VRAM ($F40000-$FBFFFF, cpuAddr[23:21]==111) must use async DTACK like RAM,
	// not the 6800 E-clock VPA peripheral path — the VPA path samples on a fixed
	// E-phase that misses the SDRAM cpu-slot and returns stale data, mis-sizing
	// the video bank and leaving the screen black.
	// FC=7 is the 68k CPU space. cpuAddr[19:16] is the CPU-space cycle-type field:
	//   $F = interrupt acknowledge  -> autovector via VPA (Mac autovectored IRQs)
	//   else ($0 breakpoint, $2 coprocessor, ...) = no responder -> bus error.
	// The boot ROM probes for hardware with `moves.w $22000,D1` (SFC=7), an
	// access that MUST bus-error; asserting VPA there wrongly completes the probe
	// and corrupts the machine-config word, routing the boot into the STM
	// serial diagnostic instead of the desktop. See memory: stm-root-cause-moves-berr.
	wire        fc7_iack = (cpuFC == 3'b111) && (cpuAddr[19:16] == 4'hF);
	// FC=7 non-IACK = CPU space with no responder (breakpoint/coprocessor/probe).
	// It MUST bus-error: suppress BOTH VPA and DTACK so no responder completes the
	// cycle, regardless of the (possibly garbage) address the EA computed. The boot
	// ROM's `moves.w $22000,D1` (SFC=7) relies on this fault; if VPA/DTACK answer it
	// the probe completes inline and boot diverts into the STM serial diagnostic.
	wire        fc7_berr = (cpuFC == 3'b111) && !fc7_iack;
	assign      _cpuVPA = fc7_iack ? 1'b0 : (fc7_berr ? 1'b1 : ~(!_cpuAS && cpuAddr[23:21] == 3'b111 && !selectVRAM));
	assign      _cpuDTACK = fc7_berr ? 1'b1 : (~(!_cpuAS && (cpuAddr[23:21] != 3'b111 || selectVRAM)) | !dtack_en);
	wire        cpu_en_p      = clk16_en_p;
	wire        cpu_en_n      = clk16_en_n;
	assign      _cpuReset_o   = tg68_reset_n;
	assign      _cpuRW        = tg68_rw;
	assign      _cpuAS        = tg68_as_n;
	assign      _cpuUDS       = tg68_uds_n;
	assign      _cpuLDS       = tg68_lds_n;
	assign      E_falling     = tg68_E_falling;
	assign      E_rising      = tg68_E_rising;
	assign      _cpuVMA       = tg68_vma_n;
	assign      cpuFC[0]      = tg68_fc0;
	assign      cpuFC[1]      = tg68_fc1;
	assign      cpuFC[2]      = tg68_fc2;
	assign      cpuAddr[31:1] = tg68_a[31:1];
	assign      cpuDataOut    = tg68_dout;

	wire        tg68_rw;
	wire        tg68_as_n;
	wire        tg68_uds_n;
	wire        tg68_lds_n;
	wire        tg68_E_rising;
	wire        tg68_E_falling;
	wire        tg68_vma_n;
	wire        tg68_fc0;
	wire        tg68_fc1;
	wire        tg68_fc2;
	wire [15:0] tg68_dout;
	wire [31:0] tg68_a;
	wire        tg68_reset_n;

	// BERR: autovector path only for now. Unmapped-BERR disabled — see
	// docs/plan_040526.md: enabling it regresses boot because the CPU
	// emits high-bit addresses ($50xxxxxx etc.) early in ROM execution.
	// Diagnostic $display below stays enabled so we can study the pattern.
	// Bus-error CPU-space (FC=7) accesses that are NOT interrupt acknowledges:
	// these are the boot ROM's hardware-presence probes (`moves` to CPU space),
	// which a real 68030 faults because nothing decodes the cycle. Without this
	// the probe completes via VPA and the boot mis-detects hardware -> STM.
	wire cpu_berr = fc7_berr && !_cpuAS;
`ifdef SIMULATION
	reg _cpuAS_d;
	always @(posedge clk_sys) _cpuAS_d <= _cpuAS;
	always @(posedge clk_sys) begin
`ifdef VERBOSE_TRACE
		if (_cpuAS_d && !_cpuAS && cpuBusControl && selectUnmapped)
			$display("BERR_UNMAPPED: addr=%h fc=%b rw=%b @%0t", cpuAddr, cpuFC, _cpuRW, $time);
		if (_cpuAS_d && !_cpuAS && |cpuAddrFullHi)
			$display("HIGH_ADDR: hi=%h addr=%h fc=%b rw=%b @%0t", cpuAddrFullHi, cpuAddr, cpuFC, _cpuRW, $time);
`endif
	end
`endif

	tg68k tg68k (
		.clk        ( clk_sys      ),
		.reset      ( !_cpuReset ),
		.phi1       ( cpu_en_p  ),
		.phi2       ( cpu_en_n  ),
		.cpu        ( {status_cpu[1], |status_cpu} ),

		.dtack_n    ( _cpuDTACK  ),
		.rw_n       ( tg68_rw    ),
		.as_n       ( tg68_as_n  ),
		.uds_n      ( tg68_uds_n ),
		.lds_n      ( tg68_lds_n ),
		.fc         ( { tg68_fc2, tg68_fc1, tg68_fc0 } ),
		.reset_n    ( tg68_reset_n ),

		.E          (  ),
		.E_div      ( 1'b1 ),
		.E_PosClkEn ( tg68_E_falling ),
		.E_NegClkEn ( tg68_E_rising  ),
		.vma_n      ( tg68_vma_n ),
		.vpa_n      ( _cpuVPA ),

		.br_n       ( 1'b1    ),
		.bg_n       (  ),
				.bgack_n    ( 1'b1 ),
				.ipl        ( _cpuIPL ),
				.berr       ( cpu_berr ),
				.din        ( dataControllerDataOut ),
				.dout       ( tg68_dout ),
				.addr       ( tg68_a )
			);
	
	addrController_top ac0
	(
		.clk(clk_sys),
		.clk8(clk8),
		.clk8_en_p(clk8_en_p),
		.clk8_en_n(clk8_en_n),
		.clk16_en_p(clk16_en_p),
		.clk16_en_n(clk16_en_n),
		._cpuReset(_cpuReset),
		.cpuAddr(cpuAddr),
		._cpuUDS(_cpuUDS),
		._cpuLDS(_cpuLDS),
		._cpuRW(_cpuRW),
		._cpuAS(_cpuAS),
		.cpuFC(cpuFC),
		.ram_config(pvia_ram_config_out),
		.ram_configured(pvia_ram_configured),
		.memoryAddr(memoryAddr),
		.memoryLatch(memoryLatch),
		._memoryUDS(_memoryUDS),
		._memoryLDS(_memoryLDS),
		._romOE(_romOE),
		._ramOE(_ramOE),
		._ramWE(_ramWE),
		.videoBusControl(videoBusControl),
		.dioBusControl(dioBusControl),
		.cpuBusControl(cpuBusControl),
		.selectSCSI(selectSCSI),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		.selectRAM(selectRAM),
		.selectROM(selectROM),
		.selectAriel(selectAriel),
		.selectPseudoVIA(selectPseudoVIA),
		.selectVRAM(selectVRAM),
		.selectUnmapped(selectUnmapped),
		.v8_video_addr(v8_video_addr),
		.v8_hblank(v8_hblank),
		.v8_vblank(v8_vblank),
		.memoryOverlayOn(memoryOverlayOn),
		.overlay_trigger_addr(overlay_trigger_addr),

		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt)
	);


	wire [1:0] diskEject;
	wire [1:0] diskMotor, diskAct;
	
	// Video Mode Selection Logic
	// 0=1bpp, 1=2bpp, 2=4bpp, 3=8bpp, 4=16bpp
	// Mapped from OSD (status[16:15]) for now:
	// DEBUG: Allow CPU to set video mode (via PseudoVIA)
	wire [2:0] v8_video_mode = pvia_video_config[2:0];
	/*
	wire [2:0] v8_video_mode = status[16:15] == 2'b00 ? 3'd2 : // 4bpp
							   status[16:15] == 2'b01 ? 3'd1 : // 2bpp
							   status[16:15] == 2'b10 ? 3'd0 : // 1bpp
							   status[16:15] == 2'b11 ? 3'd3 : // 8bpp
							   status[17] ? 3'd4 : 3'd2;       // 16bpp override
	*/

	// Monitor ID Selection — OSD-selectable between 640x480 VGA (default,
	// MAME-faithful) and 512x384 12" RGB. Portrait is not supported. This is
	// the sense ID the ROM reads to pick V8 timing.
	wire [3:0] v8_monitor_id = status[10] ? 4'h2 :  // 512x384 12" RGB
	                                         4'h6;   // 640x480 VGA (default)

	ariel_ramdac ariel(
		.clk_sys(clk_sys),
		.reset(~n_reset),
		.reg_addr(cpuAddr[10:0]),
		.uds_n(_cpuUDS),
		.lds_n(_cpuLDS),
		.data_in(cpuDataOut[7:0]),
		.data_out(ariel_reg_dout),
		.we(selectAriel && !_cpuRW && cpuBusControl),
		.req(selectAriel && cpuBusControl),

		// The RAMDAC takes the pixel index from v8_video and returns RGB data
		.pixel_index(ariel_pixel_addr),
		.rgb_out(ariel_palette_data),
		.ariel_written(ariel_written)
	);
	wire ariel_written;

	wire [7:0] pvia_video_config;
	wire [7:0] asc_data_out;
	wire asc_irq;

	pseudovia pvia(
		.clk_sys(clk_sys),
		.reset(~n_reset),
		.addr({cpuAddr[12:1], tg68_a[0]}),
		.data_in(cpuDataOut[7:0]),
		.data_out(pseudovia_dout),
		.we(selectPseudoVIA && !_cpuRW && cpuBusControl),
		.req(selectPseudoVIA && cpuBusControl),
		.vblank_irq(v8_vblank),
		.slot_irq(pds_slot_irq),
		.asc_irq(asc_irq),
		.irq_out(pseudovia_irq),
		.ram_config(configRAMSize),
		.monitor_id(v8_monitor_id),
		.video_config(pvia_video_config),
		.ram_config_out(pvia_ram_config_out),
		.ram_configured(pvia_ram_configured)
	);

	wire [31:0] v8_dbg_latch_count;
	wire [15:0] v8_dbg_last_data;
	wire [21:0] v8_dbg_last_addr;
	wire [15:0] v8_dbg_nonzero_count;

	maclc_v8_video v8_video(
		.clk_sys(clk_sys),
		.clk8_en_p(clk8_en_p),
		.reset(~n_reset),

		// VRAM Interface (byte offset from VRAM start, translated in addrController)
		.video_addr(v8_video_addr),
		.video_data_in(sdram_do), // Data from SDRAM (valid when video_latch=1)
		.video_latch(v8_video_latch),

		// Configuration
		.video_mode(v8_video_mode),
		.monitor_id(v8_monitor_id),

		// Test / diagnostic controls — disabled (OSD test options removed).
		.test_bypass_vram(1'b0),
		.test_pattern_sel(2'b00),

		// Video Signals
		.hsync(v8_hsync),
		.vsync(v8_vsync),
		.hblank(v8_hblank),
		.vblank(v8_vblank),
		.vga_r(v8_vga_r),
		.vga_g(v8_vga_g),
		.vga_b(v8_vga_b),
		.de(v8_de),
		.ce_pix(v8_ce_pix),

		// Palette Interface (Connected to Ariel RAMDAC)
		.palette_addr(ariel_pixel_addr),
		.palette_data(ariel_palette_data),

		// Debug telemetry
		.dbg_latch_count(v8_dbg_latch_count),
		.dbg_last_data(v8_dbg_last_data),
		.dbg_last_addr(v8_dbg_last_addr),
		.dbg_nonzero_count(v8_dbg_nonzero_count)
	);

	// ASC sample outputs (Commit C will route to AUDIO_L/R)
	wire signed [15:0] asc_sample_l;
	wire signed [15:0] asc_sample_r;
	wire               asc_sample_tick;

	// V8 schematic SND[0:2]/DFAC_CLK/CULTDAC0: see rtl/asc.sv / rtl/ariel_ramdac.sv
	asc asc_inst(
		.clk(clk_sys),
		.reset(~n_reset),
		.cs(selectASC),
		.addr(cpuAddr[11:0]),
		.data_in(cpuDataOut[7:0]),
		.data_out(asc_data_out),
		.we(!_cpuRW && cpuBusControl),
		.sample_l(asc_sample_l),
		.sample_r(asc_sample_r),
		.sample_tick(asc_sample_tick),
		.irq(asc_irq)
	);

	/*
	always @(posedge clk_sys) begin
		if (!_cpuAS && clk8_en_p) begin
			$display("DC: AS_active addr=%h fc=%d rw=%b @%0t", cpuAddr, cpuFC, _cpuRW, $time);
		end
	end
	*/

	// v8_vblank debug removed - fires every frame, too noisy

	reg memoryOverlayOn_prev;
	always @(posedge clk_sys) begin
		if (memoryOverlayOn != memoryOverlayOn_prev) begin
			$display("DC: memoryOverlayOn changed: %b @%0t", memoryOverlayOn, $time);
		end
		memoryOverlayOn_prev <= memoryOverlayOn;
	end

	dataController_top dataController (
		.clk32(clk_sys),
		.clk8_en_p(clk8_en_p),
		.clk8_en_n(clk8_en_n),
		.scsi_pclk_en(scsi_pclk_en),
		.E_rising(E_rising),
		.E_falling(E_falling),
		._systemReset(n_reset),
		.pseudovia_irq(pseudovia_irq),
		._cpuReset(_cpuReset), 
		._cpuIPL(_cpuIPL),
		._cpuUDS(_cpuUDS), 
		._cpuLDS(_cpuLDS), 
		._cpuRW(_cpuRW), 
		._cpuVMA(_cpuVMA),
		.cpuDataIn(cpuDataOut),
		.cpuDataOut(dataControllerDataOut), 	
		.cpuAddrRegHi(cpuAddr[12:9]),
		.cpuAddrRegMid(cpuAddr[6:4]),  // for SCSI
		.cpuAddrRegLo(cpuAddr[2:1]),		
		.selectSCSI(selectSCSI),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		.selectASC(selectASC),
		.asc_data_in(asc_data_out),
		.cpuBusControl(cpuBusControl),
		.videoBusControl(videoBusControl),
		.memoryDataOut(memoryDataOut),
		.memoryDataIn(sdram_do),
		.memoryLatch(memoryLatch),
		.selectAriel(selectAriel),
		.ariel_data_in(ariel_reg_dout),
		.selectPseudoVIA(selectPseudoVIA),
		.pseudovia_data_in(pseudovia_dout),
		.selectUnmapped(selectUnmapped),
		
		// peripherals
		.ps2_key(ps2_key), 
		.capslock(capslock),
		.ps2_mouse(ps2_mouse),
		// serial uart
		.serialIn(serialIn),
		.serialOut(serialOut),
		.serialCTS(serialCTS),
		.serialRTS(serialRTS),

		// rtc unix ticks
		.timestamp(TIMESTAMP),

		// video
		._hblank(~v8_hblank),
		._vblank(~v8_vblank),
		.vid_alt(vid_alt),


		// floppy disk interface
		.insertDisk({dsk_ext_ins, dsk_int_ins}),
		.diskSides({dsk_ext_ds, dsk_int_ds}),
		.diskEject(diskEject),
		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt),
		.diskMotor(diskMotor),
		.diskAct(diskAct),

		// block device interface for scsi disk
		.img_mounted(img_mounted),
		.img_size(img_size[40:9]),
		.io_lba(sd_lba),
		.io_rd(sd_rd),
		.io_wr(sd_wr),
		.io_ack(sd_ack),

		.sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr)
	);

	reg disk_act;
	always @(posedge clk_sys) begin
		integer timeout = 0;

		if(timeout) begin
			timeout <= timeout - 1;
			disk_act <= 1;
		end else begin
			disk_act <= 0;
		end

		if(|diskAct) timeout <= 500000;
	end

	//////////////////////// DOWNLOADING ///////////////////////////

	// Download handler: ROM (boot0.rom, 512KB) and floppy disk images
	// MiSTer loads boot0.rom with ioctl_index=0, F1/F2 mounts use index 1/2
	wire dio_download;
	wire [23:0] dio_addr = ioctl_addr[24:1];  // word address from byte address
	wire  [7:0] dio_index;

	// good floppy image sizes are 819200 bytes and 409600 bytes
	reg dsk_int_ds, dsk_ext_ds;
	reg dsk_int_ss, dsk_ext_ss;  // single sided image inserted

	// any known type of disk image inserted?
	wire dsk_int_ins = dsk_int_ds || dsk_int_ss;
	wire dsk_ext_ins = dsk_ext_ds || dsk_ext_ss;
	// at the end of a download latch file size
	// diskEject is set by macos on eject
	always @(posedge clk_sys) begin
		reg old_down;
		old_down <= dio_download;
		if(old_down && ~dio_download && dio_index == 1) begin
			dsk_int_ds <= (dio_addr == 409600);
			// double sides disk, addr counts words, not bytes
			dsk_int_ss <= (dio_addr == 204800);   // single sided disk
		end

		if(diskEject[0]) begin
			dsk_int_ds <= 0;
			dsk_int_ss <= 0;
		end
	end	

	always @(posedge clk_sys) begin
		reg old_down;

		old_down <= dio_download;
		if(old_down && ~dio_download && dio_index == 2) begin
			dsk_ext_ds <= (dio_addr == 409600);
			// double sided disk, addr counts words, not bytes
			dsk_ext_ss <= (dio_addr == 204800);   // single sided disk
		end

		if(diskEject[1]) begin
			dsk_ext_ds <= 0;
			dsk_ext_ss <= 0;
		end
	end

	// Download addresses (SDRAM word addresses):
	//   ROM:      $500000 + offset
	//   Floppy 1: $600000 + offset
	//   Floppy 2: $700000 + offset
	reg [22:0] dio_a;
	reg [15:0] dio_data;
	reg        dio_write;

	always @(posedge clk_sys) begin
		reg old_cyc = 0;
		if(ioctl_write) begin
			dio_data <= {ioctl_data[7:0], ioctl_data[15:8]};
			case (dio_index[1:0])
				2'b01:   dio_a <= 23'h600000 + {3'b0, dio_addr[19:0]};  // Floppy 1
				2'b10:   dio_a <= 23'h700000 + {3'b0, dio_addr[19:0]};  // Floppy 2
				default: dio_a <= {5'b01010, dio_addr[17:0]};            // ROM at $500000
			endcase
			ioctl_wait <= 1;
		end

		old_cyc <= dioBusControl;
		if(~dioBusControl) dio_write <= ioctl_wait;
		if(old_cyc & ~dioBusControl & dio_write) ioctl_wait <= 0;
	end


	// sdram used for ram/rom maps directly into 68k address space
	wire download_cycle = dio_download && dioBusControl;

	// ============================================================
	// VRAM is left uninitialized — the Mac's video driver clears and
	// fills the framebuffer itself (matches real hardware). The old
	// rainbow test-pattern seeder was removed.
	// ============================================================

	////////////////////////// SDRAM /////////////////////////////////

	// SDRAM Address mapping for Mac LC (V8-style):
	// memoryAddr[22:0] is already the SDRAM word address from addrController
	// Download path uses dio_a[22:0] directly
	wire [24:0] sdram_addr = download_cycle ? {2'b00, dio_a[22:0]} :
	                                          {2'b00, memoryAddr[22:0]};
	wire [15:0] sdram_din  = download_cycle ? dio_data :
	                                          memoryDataOut;
	wire  [1:0] sdram_ds   = download_cycle ? 2'b11 :
	                                          { !_memoryUDS, !_memoryLDS };
	wire        sdram_we   = download_cycle ? dio_write :
	                                          !_ramWE;
	wire        sdram_oe   = download_cycle ? 1'b0 :
	                                          (!_ramOE || !_romOE || dskReadAckInt || dskReadAckExt);
	wire [15:0] sdram_do   = download_cycle ? 16'hffff :
	                         (dskReadAckInt || dskReadAckExt) ? extra_rom_data_demux :
	                                                            sdram_out;
	// during rom/disk download ffff is returned so the screen is black during download
	// "extra rom" is used to hold the disk image. It's expected to be byte wide and
	// we thus need to properly demultiplex the word returned from sdram in that case
	wire [15:0] extra_rom_data_demux = memoryAddr[0]?
							 {sdram_out[7:0],sdram_out[7:0]}:{sdram_out[15:8],sdram_out[15:8]};
	wire [15:0] sdram_out;

	// SignalTap SDRAM probes
	wire [15:0] stp_sdramOut      = sdram_out              /* synthesis keep */;
	wire        stp_sdramOE       = sdram_oe               /* synthesis keep */;
	wire        stp_sdramWE       = sdram_we               /* synthesis keep */;
	wire        stp_downloading   = dio_download           /* synthesis keep */;

	assign SDRAM_CKE = 1;

	sdram sdram
	(
		// system interface
		.init           ( !pll_locked              ),
		.clk_64         ( clk_mem                  ),
		.clk_8          ( clk8                     ),

		.sd_clk         ( SDRAM_CLK                ),
		.sd_data        ( SDRAM_DQ                 ),
		.sd_addr        ( SDRAM_A                  ),
		.sd_dqm         ( {SDRAM_DQMH, SDRAM_DQML} ),
		.sd_cs          ( SDRAM_nCS                ),
		.sd_ba          ( SDRAM_BA                 ),
		.sd_we          ( SDRAM_nWE                ),
		.sd_ras         ( SDRAM_nRAS               ),
		.sd_cas         ( SDRAM_nCAS               ),


		// cpu/chipset interface
		// map rom to sdram word address $200000 - $20ffff
		.din            ( sdram_din                ),
		.addr           ( sdram_addr               ),
		.ds             ( sdram_ds                 ),
		.we             ( sdram_we                 ),
		.oe             ( sdram_oe                 ),
		.dout           ( sdram_out                )
	);

endmodule