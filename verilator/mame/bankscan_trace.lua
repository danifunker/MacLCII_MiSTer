-- bankscan_trace.lua — MAME maclc2 oracle: does it run the same RAM-detection
-- code path as the FPGA core? The core's boot runs StartTest1 ($A46540) + the
-- bank-scan RAM enumeration ($A4A5xx); this checks whether MAME (same byte-identical
-- ROM) executes them, and samples what PC MAME's POST RAM-test writes come from.
--
-- Env: BS_OUT (default /tmp/bankscan_mame.txt), MAX_FRAME (default 240).
-- Run: verilator/mame/run_mame_maclc2.sh \
--        -autoboot_script verilator/mame/bankscan_trace.lua -seconds_to_run 8

local BS_OUT = os.getenv("BS_OUT") or "/tmp/bankscan_mame.txt"
local function envnum(n,d) local v=os.getenv(n); return v and (tonumber(v) or d) or d end
local MAX_FRAME = envnum("MAX_FRAME", 240)

local f = io.open(BS_OUT, "w")
local frame, installed = 0, false
local cpu, space
local ftap, wtap
local buf = {}
local function emit(s) buf[#buf+1] = s end
local function pcnow() local v=0; pcall(function() v = cpu.state["CURPC"].value end); return v end

-- Narrow probe-address windows (so pc() per access is affordable): the top-of-RAM
-- walk $X0FFF0..$X0FFFF for X=0..9 (covers $0FFFFE..$9FFFFE + the 'PanD' $1FFFFE),
-- plus the data-bus-width test region $400000-$40000F.
local probe_taps = {}
local cap = 0
local function logacc(kind, off, data)
	if cap < 3000 then
		cap = cap + 1
		emit(string.format("%s F=%d pc=%08X addr=%06X data=%08X", kind, frame, pcnow(), off, data))
	end
end

local function install()
	for _,t in ipairs(probe_taps) do pcall(function() t:remove() end) end
	probe_taps = {}
	local function win(lo, hi)
		probe_taps[#probe_taps+1] = space:install_read_tap(lo, hi, "pr", function(o,d,m) logacc("R", o, d) end)
		probe_taps[#probe_taps+1] = space:install_write_tap(lo, hi, "pw", function(o,d,m) logacc("W", o, d) end)
	end
	for x = 0, 9 do win((x << 20) | 0xFFFF0, (x << 20) | 0xFFFFF) end
	win(0x400000, 0x40000F)
	-- Capture d0/d1 at the bank-scan branch $A4A5C2 (btst #7,d1; beq $a4a638):
	-- if MAME takes beq (d1 bit7 clear) it SKIPS the extensive probe our core runs.
	probe_taps[#probe_taps+1] = space:install_read_tap(0xA4A5C2, 0xA4A5C3, "brp", function(o,d,m)
		local d0,d1,a0v = 0,0,0
		pcall(function() d0 = cpu.state["D0"].value; d1 = cpu.state["D1"].value; a0v = cpu.state["A0"].value end)
		if cap < 3000 then cap = cap + 1
			emit(string.format("BRANCH F=%d $A4A5C2 D0=%08X D1=%08X(bit7=%d) A0=%08X", frame, d0, d1, (d1>>7)&1, a0v)) end
	end)
end

local function setup()
	cpu = manager.machine.devices[":maincpu"]
	space = cpu.spaces["program"]
	f:write(string.format("# bankscan_trace max_frame=%d\n", MAX_FRAME)); f:flush()
	install()
end

emu.register_frame_done(function()
	frame = frame + 1
	if not installed then installed = true; setup() end
	install()
	if frame % 20 == 0 then emit(string.format("# F=%d probe_accs=%d", frame, cap)) end
	if #buf > 0 then f:write(table.concat(buf, "\n")); f:write("\n"); buf = {}; f:flush() end
	if frame >= MAX_FRAME then
		f:write(string.format("# END F=%d accs=%d\n", frame, cap)); f:flush(); f:close()
		manager.machine:exit()
	end
end)
