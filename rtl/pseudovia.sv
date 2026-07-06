// Mac LC Pseudo-VIA
// Faithful port of MAME's pseudovia_device (src/devices/machine/pseudovia.cpp,
// V8 variant = v8_pseudovia_device), 2026-07-06 rewrite.
//
// Mapped at $F26000-$F27FFF in CPU space (V8 internal 0x526000).
//
// The 2026-07-06 rewrite replaces the old "native <$100 / compat >=$100 with
// only regs 13/14" model, which came from an OLD MAME pseudovia.cpp and
// diverged from real hardware in five load-bearing ways (all verified against
// current MAME source + a healthy MAME maclc2 7.5.5 boot register watch):
//
//  1. READS alias EVERY offset via `offset & 0x13` — so the ROM's slot
//     interrupt dispatcher read of ($203,VIA2base) returns THE IFR, not $00.
//     Returning $00 starved the whole slot-interrupt dispatch tree
//     ($A06EC0/$A06EEC): slot-VBL queue tasks and the interrupt-driven SCSI
//     driver's completion callbacks never ran. System 7.1 (polled ROM SCSI
//     driver) survived; System 7.5.5 (HD SC 4.3 interrupt driver + launch
//     VBL tasks) wedged at menu-bar draw waiting for a completion that
//     could never be dispatched.
//  2. The IFR readback is the RECALC'd value: when (pending & IER & $1B)
//     is nonzero the stored IFR is REPLACED by that masked set | $80, so
//     the dispatcher only ever sees ENABLED sources ($3F-masked) and never
//     walks an empty queue (which would _SysError). Level sources re-assert
//     their bits on the next cycle, matching MAME's callback re-set.
//  3. The VBLANK slot source is STATE (regs[2] bit 6, active low): asserted
//     at vblank start, deasserted at vblank end AND by the ROM's ack write
//     of $40 to reg 2. The old live `~vblank_irq` wire made the ack a no-op,
//     so the slot IRQ re-fired for the whole vblank period (~950 acks/frame
//     interrupt storm, confirmed in both 7.1 and 7.5.5 sim logs).
//  4. WRITES: (offset >> 9) == 1 ($200-$3FF) hits the V8's port A (unwired
//     on the LC → ignored); everything else decodes offset & $1F exactly
//     like v8_pseudovia_device::write. The old invented "$1A00 compat IFR /
//     $1C00 compat IER" registers are gone (current MAME maps those to
//     port B / reg 0; the ROM's real acks go to $F26002/3, seen in sim logs).
//  5. IFR ack ignores bit 4 (ASC is level-triggered on V8 — write is a NOP)
//     and the IER "write $FF => $1F" quirk is base-RBV/IIci only, NOT V8.
//
// Reset values per pseudovia_device::device_reset(): regs[2]=$7F, regs[3]=$1B.

module pseudovia(
    input clk_sys,
    input reset,

    // CPU interface - full offset within $F26000-$F27FFF range
    input [12:0] addr,  // Offset 0x0000-0x1FFF
    input [7:0] data_in,
    output reg [7:0] data_out,
    input we,
    input req,

    // Interrupts
    input vblank_irq,    // Active high VBlank signal -> slot bit 6 (latched)
    input slot_irq,      // Slot interrupt            -> slot bit 5 (latched)
    input asc_irq,       // ASC interrupt (LEVEL)     -> IFR bit 4
    input scsi_irq,      // NCR5380 latched interrupt (LEVEL) -> IFR bit 3 ("CB2")
    input scsi_drq,      // NCR5380 DREQ (LEVEL)              -> IFR bit 0 ("CA2")
    output reg irq_out,

    // Config from top level
    input [7:0] ram_config,  // V8 RAM config byte (MAME encoding)
    input [3:0] monitor_id,  // Monitor ID for video config

    // Video config output (set by ROM, bits 2:0 = bpp mode)
    output reg [7:0] video_config,

    // RAM config output (active value, writable by ROM)
    output [7:0] ram_config_out,

    // Candidate B: set on the ROM's first write to the V8 RAM-config register.
    // Mirrors MAME v8.cpp: the $0 motherboard-low mirror is installed only once
    // the ROM programs the config (via2_config_w -> ram_size(data)). Before that,
    // the overlay-clear map is ram_size(0xc0) == only $800000-$9FFFFF, so the
    // boot RAM-bank probe never finds a (phantom) bank at $0.
    output reg ram_configured
);

// RAM config output: expose current value for address controller
assign ram_config_out = ram_cfg;

// Register state, mirroring MAME m_pseudovia_regs[]:
reg [7:0] port_b;        // regs[0]  (stored; LC readback returns stored value)
reg [7:0] ram_cfg;       // regs[1]  (via in/out_config handlers in MAME v8)
reg [7:0] slot_pending;  // regs[2]  slot status, ACTIVE LOW, bit6=VBL bit5=slot
reg [7:0] ifr;           // regs[3]  stored IFR incl. bit 7 = IRQ active
reg [7:0] slot_ier;      // regs[$12]
reg [7:0] ier;           // regs[$13]

// vblank / slot edge detect (MAME gets edge callbacks; we get level inputs)
reg vblank_irq_d, slot_irq_d;

// --- pseudovia_recalc_irqs(), evaluated combinationally each cycle ---
// Level sources (ASC/SCSI/DRQ) follow their inputs INTO the stored ifr every
// cycle below, so build the recalc view from the live values directly.
// Bits 6,5,2 are stored-only (no V8 source ever sets them; reset leaves them
// 0; the IFR-ack write clears them) — included for structural fidelity.
wire [7:0] slot_irqs = (~slot_pending) & 8'h78 & (slot_ier & 8'h78);
wire any_slot_irq = |slot_irqs;
wire [7:0] ifr_pending = { 1'b0, ifr[6], ifr[5], asc_irq, scsi_irq, ifr[2], any_slot_irq, scsi_drq };
wire [7:0] ifr_masked = ifr_pending & ier & 8'h1B;
wire irq_pending = |ifr_masked;

// Debug counter
integer pvia_reg10_reads = 0;

// MAME read() aliases the whole window via `offset &= 0x13` — decoded below
// as {addr[4], addr[1:0]}. MAME v8 write(): port A window then offset &= 0x1f.
wire wr_is_porta = (addr[12:9] == 4'd1);   // (offset >> 9) == 1
wire [4:0] wr_sel = addr[4:0];             // offset & 0x1f

always @(posedge clk_sys) begin
    if (reset) begin
        port_b <= 8'h00;
        ram_cfg <= ram_config;  // Init from hardware config (MAME: ram_size(0xC0))
        ram_configured <= 1'b0; // $0 mirror disabled until ROM programs config
        slot_pending <= 8'h7F;  // MAME device_reset: regs[2] = 0x7f
        ifr <= 8'h1B;           // MAME device_reset: regs[3] = 0x1b
        slot_ier <= 8'h00;
        ier <= 8'h00;
        irq_out <= 1'b0;
        video_config <= 8'h03;  // Default to 8bpp mode (kept from pre-rewrite RTL)
        vblank_irq_d <= 1'b0;
        slot_irq_d <= 1'b0;
    end else begin
        // --- source followers (MAME slot_irq_w / asc_irq_w / scsi_*_w) ---
        // VBLANK: slot bit 6 goes PENDING (0) on the rising edge and clears
        // on the falling edge; the ROM's $40 ack (below) can clear it mid-
        // vblank and it must NOT re-assert until the next rising edge.
        vblank_irq_d <= vblank_irq;
        if (vblank_irq & ~vblank_irq_d)
            slot_pending[6] <= 1'b0;
        else if (~vblank_irq & vblank_irq_d)
            slot_pending[6] <= 1'b1;

        slot_irq_d <= slot_irq;
        if (slot_irq & ~slot_irq_d)
            slot_pending[5] <= 1'b0;
        else if (~slot_irq & slot_irq_d)
            slot_pending[5] <= 1'b1;

        // Level sources follow into stored IFR (MAME sets/clears + recalc)
        ifr[4] <= asc_irq;
        ifr[3] <= scsi_irq;
        ifr[0] <= scsi_drq;
        // Slot summary (recalc: |=2 / &= ~2)
        ifr[1] <= any_slot_irq;

        // --- recalc result -> stored IFR bit 7 (MAME: regs[3] = masked|0x80
        // when active; the destructive replace only drops bits 6,5,2, which
        // no V8 source ever sets — the read mux below reproduces the masked
        // readback exactly, so the stored side just tracks bit 7 here).
        if (irq_pending) begin
            ifr[7] <= 1'b1;
            irq_out <= 1'b1;
        end else begin
            ifr[7] <= 1'b0;
            irq_out <= 1'b0;
        end

        if (req) begin
            if (we) begin
                // ---- MAME v8_pseudovia_device::write ----
                if (wr_is_porta) begin
                    // $200-$3FF: V8 port A — unwired on the LC, ignore.
                    `ifdef SIMULATION
                    $display("PVIA: WRITE portA window (ignored) addr=%03x data=%02x", addr, data_in);
                    `endif
                end else begin
                    case (wr_sel)
                        5'h00: begin  // Port B
                            port_b <= data_in;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Port B = %02x @%0t", data_in, $time);
                            `endif
                            `ifdef SIMULATION
                            if (addr >= 13'h100)
                                $display("PVIA: NOTE aliased port-B write via addr=%03x data=%02x", addr, data_in);
                            `endif
                        end

                        5'h01: begin  // RAM Config (writable per MAME)
                            ram_cfg <= data_in;
                            ram_configured <= 1'b1;  // enables $0 motherboard mirror
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE RAM Config = %02x @%0t", data_in, $time);
                            `endif
                        end

                        5'h02: begin  // Slot pending: only bit 6 writable, W1C-style deassert
                            if (data_in[6])
                                slot_pending[6] <= 1'b1;   // regs[2] |= (data & 0x40)
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Slot ack = %02x @%0t", data_in, $time);
                            `endif
                        end

                        5'h03: begin  // IFR ack — MAME v8: data &= ~0x10 (ASC level-NOP),
                                      // then regs[3] &= ~(data & 0x7f), then recalc.
                            // Bits 4,3,1,0 are re-derived from live sources every
                            // cycle above (recalc semantics), so the ack only has
                            // lasting effect on the stored-only bits 6,5,2 — the
                            // W1C below is exact; level bits self-heal next cycle
                            // if their source is still asserted, as on real V8.
                            if (data_in[6]) ifr[6] <= 1'b0;
                            if (data_in[5]) ifr[5] <= 1'b0;
                            if (data_in[2]) ifr[2] <= 1'b0;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE IFR ACK %02x @%0t", data_in & 8'h7F, $time);
                            `endif
                        end

                        5'h10: begin  // Video Config
                            video_config <= data_in;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Video Config = %02x (bpp mode = %d) addr=%h @%0t",
                                     data_in, data_in[2:0], addr, $time);
                            `endif
                        end

                        5'h12: begin  // Slot IER (bit7-directed set/clear)
                            if (data_in[7])
                                slot_ier <= slot_ier | (data_in & 8'h7F);
                            else
                                slot_ier <= slot_ier & ~(data_in & 8'h7F);
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Slot IER = %02x @%0t", data_in, $time);
                            `endif
                        end

                        5'h13: begin  // IER (bit7-directed set/clear; NO $FF->$1F quirk on V8)
                            if (data_in[7])
                                ier <= ier | (data_in & 8'h7F);
                            else
                                ier <= ier & ~(data_in & 8'h7F);
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE IER = %02x @%0t", data_in, $time);
                            `endif
                        end

                        default: ;  // 4-$0F, $11, $14-$1F: ignored (MAME has no case)
                    endcase
                end
            end else begin
                // ---- MAME pseudovia_device::read — offset &= 0x13 ----
                case ({addr[4], addr[1:0]})
                    3'b000: begin  // reg 0: Port B
                        data_out <= port_b;
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: READ Port B -> %02x @%0t", port_b, $time);
                        `endif
                    end

                    3'b001: begin  // reg 1: RAM Config (OR bit 2 on read)
                        data_out <= ram_cfg | 8'h04;
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: READ RAM Config -> %02x @%0t", ram_cfg | 8'h04, $time);
                        `endif
                    end

                    3'b010: begin  // reg 2: Slot pending (active low)
                        data_out <= slot_pending;
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: READ Slot pending -> %02x @%0t", slot_pending, $time);
                        `endif
                    end

                    3'b011: begin  // reg 3: IFR (stored/recalc'd — THE $203 dispatcher read)
                        data_out <= irq_pending ? (ifr_masked | 8'h80)
                                                : (ifr_pending & 8'h7F);
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: READ IFR -> %02x @%0t",
                                 irq_pending ? (ifr_masked | 8'h80) : (ifr_pending & 8'h7F), $time);
                        `endif
                    end

                    3'b100: begin  // reg $10: Video Config
                        // MAME v8.cpp via2_video_config_r returns ONLY the
                        // monitor sense (montype << 3) — the stored config
                        // byte is write-only. (read handler: data &= ~0x38,
                        // data |= in_video; LC in_video = montype << 3.)
                        data_out <= {1'b0, monitor_id[3:0], 3'b000};  // montype << 3
                        pvia_reg10_reads <= pvia_reg10_reads + 1;
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: READ Video Config -> %02x @%0t",
                                 {1'b0, monitor_id[3:0], 3'b000}, $time);
                        `endif
                    end

                    3'b101: begin  // reg $11: unused
                        data_out <= 8'h00;
                    end

                    3'b110: begin  // reg $12: Slot IER (bit 7 reads 0)
                        data_out <= slot_ier & 8'h7F;
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: READ Slot IER -> %02x @%0t", slot_ier & 8'h7F, $time);
                        `endif
                    end

                    3'b111: begin  // reg $13: IER (bit 7 reads 0)
                        data_out <= ier & 8'h7F;
                        `ifdef VERBOSE_TRACE
                        $display("PVIA: READ IER -> %02x @%0t", ier & 8'h7F, $time);
                        `endif
                    end
                endcase
            end
        end
    end
end

endmodule
