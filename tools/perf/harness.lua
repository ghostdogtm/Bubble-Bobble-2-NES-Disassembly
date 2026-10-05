-- Bubble Bobble Part 2 (US) headless regression / perf harness for Mesen 2 (--testrunner).
--
-- tools/perf/perf.py prepends a global table CFG to a copy of this script for each run
-- (or, if CFG is absent, it is loaded from "harness_cfg.lua" in the working directory):
--   out          absolute path prefix for output files
--   ticks        number of game logic ticks to run
--   seed         seed for the deterministic input generator
--   start_round  (optional) round number to warp to when a new game starts
--   inf_lives    (bool) keep playerLives topped up
--   dump         (bool) write per-tick RAM/VRAM snapshots to <out>.dump
--   profile      (bool) write PRG-ROM exec counters to <out>.prof at the end
--   style        (optional) "camper": stand still, shoot every 240 ticks
--   shots        (optional) list of tick numbers to screenshot (<out>_tNNNNN.png)
--
-- A "tick" is one full run of the game's NMI-driven logic: the game runs all its logic inside
-- the NMI handler, guarded by nmiProgress ($15):  0 -> 1 (full NMI entered, vblank work)
-- -> 3 (banked game logic done, audio next) -> 0 (done).  An NMI arriving while nmiProgress
-- is non-zero takes the short path (lag frame).  Input is generated per tick (not per frame),
-- so a build that lags less still sees the identical input sequence per logic tick.
--
-- lag_nmis = NMIs that arrived while the logic of the tick was still running (lag frames).
-- All hooks are on RAM writes to nmiProgress, so they do not depend on code layout.

if not CFG then dofile("harness_cfg.lua") end

local NMI_PROGRESS = 0x15
local CUR_ROUND    = 0xD8
local PLAYER_LIVES = 0x0479

local MT_CPU  = emu.memType.nesMemory
local MT_RAM  = emu.memType.nesInternalRam
local MT_NT   = emu.memType.nesNametableRam
local MT_PAL  = emu.memType.nesPaletteRam

local csv = io.open(CFG.out .. ".csv", "w")
csv:write("tick,frame,vblank_cyc,logic_cyc,audio_cyc,lag_nmis,round,irq_effect,wide\n")
local dump = nil
if CFG.dump then dump = io.open(CFG.out .. ".dump", "wb") end

local function cycles()
  return emu.getState()["cpu.cycleCount"]
end

------------------------------------------------------------------------------------------
-- deterministic input generator (pure function of tick sequence)
------------------------------------------------------------------------------------------
local rng = (CFG.seed or 1) % 2147483647
if rng == 0 then rng = 1 end
local function rand(n) -- 0..n-1
  rng = (rng * 48271) % 2147483647
  return rng % n
end

local pendingRound = nil  -- deferred round warp
local started = false      -- new game has begun (currentRound written with 1)
local startTick = 0
local dir, dirLeft = nil, 0
local jumpLeft = 0
local shootWait = 0
local curInput = {}

-- play is split into segments with different styles so that slow game paths (bubbles that
-- expire, trapped enemies that escape, idle player) get exercised, not just constant shooting
local mode, modeLeft = "aggressive", 0
local function genInput(tick)
  local inp = {}
  if not started then
    -- title / menus: tap Start every 50 ticks
    if tick % 50 >= 20 and tick % 50 < 24 then inp.start = true end
    return inp
  end
  if CFG.style == "camper" then
    -- stand still and blow a bubble now and then: lets bubbles and trapped enemies time out
    if (tick - startTick) % 240 < 2 then inp.b = true end
    if (tick - startTick) % 1200 == 600 then inp.left = true end
    return inp
  end
  if modeLeft <= 0 then
    local r = rand(8)
    if r < 4 then mode = "aggressive" elseif r < 7 then mode = "passive" else mode = "idle" end
    modeLeft = 150 + rand(450)
  end
  modeLeft = modeLeft - 1
  if mode == "idle" then
    -- stand still, very occasional jump
    if rand(64) == 0 then inp.a = true end
    return inp
  end
  if dirLeft <= 0 then
    local r = rand(6)
    if r == 0 or r == 1 then dir = "left" elseif r == 2 or r == 3 then dir = "right"
    elseif r == 4 then dir = nil else dir = "down" end
    dirLeft = 8 + rand(56)
  end
  dirLeft = dirLeft - 1
  if dir then inp[dir] = true end
  if jumpLeft > 0 then
    jumpLeft = jumpLeft - 1
    inp.a = true
  elseif rand(16) == 0 then
    jumpLeft = 1 + rand(12)
    inp.a = true
  end
  if shootWait <= 0 then
    inp.b = true
    if mode == "aggressive" then shootWait = 2 + rand(9) else shootWait = 40 + rand(160) end
  end
  shootWait = shootWait - 1
  -- after game over the continue screen needs Start; tap it rarely (deterministic)
  if CFG.start_taps and (tick - startTick) % 997 == 500 then inp.start = true end
  return inp
end

------------------------------------------------------------------------------------------
-- tick bookkeeping
------------------------------------------------------------------------------------------
local tick = -1
local frame = 0
local tNmi, tStart, tLogicEnd = 0, 0, 0
local nmisInTick = 0
local logicCyc, vblankCyc, lagNmis = 0, 0, 0
local inTick = false
local shots = {}
for _, t in ipairs(CFG.shots or {}) do shots[t] = true end

local function readBlock(memType, base, len)
  local t = {}
  for i = 0, len - 1 do t[i + 1] = emu.read(base + i, memType) end
  return string.char(table.unpack(t))
end

local vramSnap = nil

local function finish(code)
  csv:close()
  if dump then dump:close() end
  if CFG.profile then
    local c = emu.getAccessCounters(emu.memType.nesPrgRom, emu.counterType.execCount)
    local p = io.open(CFG.out .. ".prof", "w")
    for i = 0, #c do
      local v = c[i]
      if v and v > 0 then p:write(string.format("%05X %d\n", i, v)) end
    end
    p:close()
  end
  emu.stop(code)
end

emu.addEventCallback(function()
  tNmi = cycles()
  nmisInTick = nmisInTick + 1
end, emu.eventType.nmi)

local lastProgress = 0
emu.addMemoryCallback(function(addr, value)
  -- note: NMIShort's "INC nmiProgress" first dummy-writes the old value (1), then 2
  local prev = lastProgress
  lastProgress = value
  if value == 1 and prev == 0 then
    -- full NMI entered: new logic tick
    tick = tick + 1
    tStart = cycles()
    vblankCyc = 0
    nmisInTick = 1
    inTick = true
    if pendingRound then
      emu.write(CUR_ROUND, pendingRound, MT_CPU)
      pendingRound = nil
    end
    curInput = genInput(tick)
    if CFG.inf_lives and started and emu.read(PLAYER_LIVES, MT_CPU) < 2 then
      emu.write(PLAYER_LIVES, 3, MT_CPU)
    end
    if dump then
      vramSnap = readBlock(MT_NT, 0, 0x800) .. readBlock(MT_PAL, 0, 0x20)
    end
  elseif value == 3 and inTick then
    -- banked game logic finished
    tLogicEnd = cycles()
    logicCyc = tLogicEnd - tStart
    lagNmis = nmisInTick - 1
    if dump then
      dump:write(readBlock(MT_RAM, 0, 0x800))
      dump:write(vramSnap)
    end
  elseif value == 0 and inTick then
    inTick = false
    local audio = cycles() - tLogicEnd
    csv:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d\n", tick, frame, tStart - tNmi, logicCyc, audio,
      lagNmis, emu.read(CUR_ROUND, MT_CPU), emu.read(0x1D, MT_CPU), emu.read(0x03B0, MT_CPU)))
    if shots[tick] then
      local png = emu.takeScreenshot()
      local g = io.open(string.format("%s_t%05d.png", CFG.out, tick), "wb")
      g:write(png); g:close()
    end
    if tick + 1 >= CFG.ticks then finish(0) end
  end
end, emu.callbackType.write, NMI_PROGRESS, NMI_PROGRESS, emu.cpuType.nes, MT_CPU)

-- new game start: currentRound <- 1 (optionally warp)
emu.addMemoryCallback(function(addr, value)
  if not started and value == 1 then
    started = true
    startTick = tick
    -- the callback runs before the store commits, so apply the warp at the next tick start
    if CFG.start_round and CFG.start_round ~= 1 then pendingRound = CFG.start_round end
  end
end, emu.callbackType.write, CUR_ROUND, CUR_ROUND, emu.cpuType.nes, MT_CPU)

emu.addEventCallback(function()
  emu.setInput(curInput, 0)
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frame = frame + 1
  if frame > CFG.ticks * 4 + 3000 then
    csv:write("TIMEOUT\n")
    finish(2)
  end
end, emu.eventType.endFrame)
