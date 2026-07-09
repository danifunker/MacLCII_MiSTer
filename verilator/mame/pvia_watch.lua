-- pvia_watch.lua — per-frame watch of the LC pseudo-VIA (V8) registers in a
-- healthy MAME maclc2 boot, for diffing against the MacLCii core's wedge at
-- the slot-interrupt dispatcher ($A06EC0 reads (A1+$203)).
-- Logs IFR ($03), the $203 byte the ROM dispatcher polls, slot IER ($12),
-- IER ($13), and slot status ($02) once per frame WHEN ANY CHANGES (plus a
-- heartbeat every 60). Physical base: V8 maps the pseudo-VIA at $50F26000
-- (24-bit CPU alias F26000). Lua space reads are physical/untranslated.
-- Env: OUT (default /tmp/pvia_watch.txt), MAX_FRAME (default 2700).
local OUT       = os.getenv("OUT") or "/tmp/pvia_watch.txt"
local MAX_FRAME = tonumber(os.getenv("MAX_FRAME") or "2700")
local BASE      = 0x50F26000

local f = io.open(OUT, "w")
local frame, installed = 0, false
local cpu, space, last = nil, nil, ""

local function RD8(a) local v=-1; pcall(function() v=space:read_u8(a) end); return v end

emu.register_frame_done(function()
  frame = frame + 1
  if not installed then
    installed = true
    cpu = manager.machine.devices[":maincpu"]
    space = cpu.spaces["program"]
    f:write("# pvia_watch installed\n"); f:flush()
  end
  local line = string.format("ifr=%02X p203=%02X sier=%02X ier=%02X sstat=%02X",
    RD8(BASE+3), RD8(BASE+0x203), RD8(BASE+0x12), RD8(BASE+0x13), RD8(BASE+2))
  if line ~= last then
    f:write(string.format("F%d %s\n", frame, line)); f:flush()
    last = line
  elseif frame % 60 == 0 then
    f:write(string.format("HB F%d %s\n", frame, line))
  end
  if frame >= MAX_FRAME then
    f:write(string.format("DONE F%d\n", frame)); f:close()
    manager.machine:exit()
  end
end)
