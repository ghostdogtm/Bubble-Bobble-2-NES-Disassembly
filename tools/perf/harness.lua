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
--   pad2         (bool, default false) drive pad 2 from a second, independent generator once the
--                game has started (idle before that); always the normal (non-camper) play style
--                (delivered with emu.setInput(inp, 0, 1): the Mesen config uses the 4-player adapter, so
--                pad 2 is subport 1 of port 0; emu.setInput(inp, 1) would not reach the game)
--   seed2        seed of the pad-2 generator (default seed + 7919)
--   pokes        (optional) list of {tick=N, addr=A, val=V}: at the start of tick N (where the
--                deferred round warp is applied) write V to CPU address A (emu.memType.nesMemory,
--                so $6000-$7FFF reaches cartridge PRG-RAM if the mapper provides it)
--   lives_addrs  (optional) list of CPU addresses topped up to 3 when < 2 if inf_lives is set
--                (default {0x0479} = playerLives)
--   coop_select  (optional) {mode = A, menu = M}: co-op scenario (R2). While the title menu runs
--                (nmiBankedSub == M, TitleScreenMenu) and the byte at A (coopMode) is not 1, pad 1 taps
--                SELECT (held 2 ticks, then 2 ticks with nothing pressed) instead of the generator's
--                input; the generator's START taps then start the game. The run fails (csv line
--                COOP_NOT_SELECTED, exit code 3) if the game starts with coopMode ~= 1 or if 4 SELECT
--                taps did not set it. Without coop_select the input stream is unchanged.
--   icon_trace   (optional, used with dump) {starts = {A, ...}, stops = {A, ...}, slot = N}: records which OAM entries
--                (OAMBuffer $0200-$02FF, 64 entries of 4 bytes) were last written while DrawObjects drew object slot N
--                (the HUD icon, OSLOT_ICON = 19). An exec of a `starts` address (the per-object draw path, where
--                scratch4 = the slot being drawn) sets the current slot from scratch4; an exec of a `stops` address
--                (DrawObjects entry, the fill of unused entries, the exits) clears it. Every OAMBuffer write marks its
--                entry as drawn by slot N or not. At each RAM snapshot the marked entries are written to <out>.icon
--                as "tick e1 e2 ..." (only ticks with at least one marked entry). perf.py regress uses it for the
--                HUD-icon OAM rule (Phase 7b-1).
--
-- CSV columns (perf.py reads columns 3 and 5, so new columns are only ever appended):
--   tick,frame,vblank_cyc,logic_cyc,audio_cyc,lag_nmis,round,irq_effect,wide,held2
--   held2 = heldP2 ($0F) at tick end: proves pad 2 input reached the game
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
local HELD_P2      = 0x0F

local MT_CPU  = emu.memType.nesMemory
local MT_RAM  = emu.memType.nesInternalRam
local MT_NT   = emu.memType.nesNametableRam
local MT_PAL  = emu.memType.nesPaletteRam

local csv = io.open(CFG.out .. ".csv", "w")
csv:write("tick,frame,vblank_cyc,logic_cyc,audio_cyc,lag_nmis,round,irq_effect,wide,held2\n")
local dump = nil
if CFG.dump then dump = io.open(CFG.out .. ".dump", "wb") end
local iconf = nil
if CFG.dump and CFG.icon_trace then iconf = io.open(CFG.out .. ".icon", "w") end

local function cycles()
  return emu.getState()["cpu.cycleCount"]
end

------------------------------------------------------------------------------------------
-- deterministic input generator (pure function of tick sequence)
------------------------------------------------------------------------------------------
local pendingRound = nil  -- deferred round warp
local started = false      -- new game has begun (currentRound written with 1)
local startTick = 0
local curInput = {}
local curInput2 = {}

-- play is split into segments with different styles so that slow game paths (bubbles that
-- expire, trapped enemies that escape, idle player) get exercised, not just constant shooting.
-- Each generator owns its RNG and state; isP1 enables the pad-1-only parts (title-screen Start
-- taps, "camper" style, start_taps).
local function makeGen(seed, isP1)
  local rng = (seed or 1) % 2147483647
  if rng == 0 then rng = 1 end
  local function rand(n) -- 0..n-1
    rng = (rng * 48271) % 2147483647
    return rng % n
  end
  local dir, dirLeft = nil, 0
  local jumpLeft = 0
  local shootWait = 0
  local mode, modeLeft = "aggressive", 0
  return function(tick)
    local inp = {}
    if not started then
      -- title / menus: tap Start every 50 ticks (pad 1 only)
      if isP1 and tick % 50 >= 20 and tick % 50 < 24 then inp.start = true end
      return inp
    end
    if isP1 and CFG.style == "camper" then
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
    if isP1 and CFG.start_taps and (tick - startTick) % 997 == 500 then inp.start = true end
    return inp
  end
end

local genInput = makeGen(CFG.seed, true)

-- co-op scenarios: choose the co-op line of the title menu with SELECT (see coop_select above)
local selHold, selGap, selTaps, coopFail = 0, 0, 0, nil
local function coopSelect(inp)
  local cs = CFG.coop_select
  if not cs or started then return inp end
  if selHold > 0 then selHold = selHold - 1; return { select = true } end
  if selGap > 0 then selGap = selGap - 1; return {} end
  if emu.read(0x16, MT_CPU) + emu.read(0x17, MT_CPU) * 256 == cs.menu and emu.read(cs.mode, MT_CPU) ~= 1 then
    selTaps = selTaps + 1
    if selTaps > 4 then coopFail = "SELECT did not set coopMode" end
    selHold, selGap = 1, 2
    return { select = true }
  end
  return inp
end
local genInput2 = CFG.pad2 and makeGen(CFG.seed2 or ((CFG.seed or 1) + 7919), false) or nil

local pokes = {}
for _, pk in ipairs(CFG.pokes or {}) do
  pokes[pk.tick] = pokes[pk.tick] or {}
  table.insert(pokes[pk.tick], pk)
end
local livesAddrs = CFG.lives_addrs or { PLAYER_LIVES }

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
  if iconf then iconf:close() end
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

-- HUD-icon OAM trace (CFG.icon_trace, see the header)
local iconOwner = {}
if iconf then
  local it = CFG.icon_trace
  local curSlot = nil
  for _, a in ipairs(it.starts) do
    emu.addMemoryCallback(function() curSlot = emu.read(0x04, MT_CPU) end,
      emu.callbackType.exec, a, a, emu.cpuType.nes, MT_CPU)
  end
  for _, a in ipairs(it.stops) do
    emu.addMemoryCallback(function() curSlot = nil end, emu.callbackType.exec, a, a, emu.cpuType.nes, MT_CPU)
  end
  emu.addMemoryCallback(function(addr, value)
    iconOwner[(addr - 0x200) >> 2] = (curSlot == it.slot)
  end, emu.callbackType.write, 0x200, 0x2FF, emu.cpuType.nes, MT_CPU)
end

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
    if pokes[tick] then
      for _, pk in ipairs(pokes[tick]) do emu.write(pk.addr, pk.val, MT_CPU) end
    end
    curInput = coopSelect(genInput(tick))
    if genInput2 then curInput2 = genInput2(tick) end
    if CFG.inf_lives and started then
      for _, a in ipairs(livesAddrs) do
        if emu.read(a, MT_CPU) < 2 then emu.write(a, 3, MT_CPU) end
      end
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
    if iconf then
      local t = {}
      for e = 0, 63 do if iconOwner[e] then t[#t + 1] = e end end
      if #t > 0 then iconf:write(tick .. " " .. table.concat(t, " ") .. "\n") end
    end
  elseif value == 0 and inTick then
    inTick = false
    local audio = cycles() - tLogicEnd
    csv:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", tick, frame, tStart - tNmi, logicCyc, audio,
      lagNmis, emu.read(CUR_ROUND, MT_CPU), emu.read(0x1D, MT_CPU), emu.read(0x03B0, MT_CPU),
      emu.read(HELD_P2, MT_CPU)))
    if shots[tick] then
      local png = emu.takeScreenshot()
      local g = io.open(string.format("%s_t%05d.png", CFG.out, tick), "wb")
      g:write(png); g:close()
    end
    if coopFail then
      csv:write("COOP_NOT_SELECTED " .. coopFail .. "\n")
      finish(3)
    end
    if tick + 1 >= CFG.ticks then finish(0) end
  end
end, emu.callbackType.write, NMI_PROGRESS, NMI_PROGRESS, emu.cpuType.nes, MT_CPU)

-- new game start: currentRound <- 1 (optionally warp)
emu.addMemoryCallback(function(addr, value)
  if not started and value == 1 then
    started = true
    startTick = tick
    if CFG.coop_select and emu.read(CFG.coop_select.mode, MT_CPU) ~= 1 then
      coopFail = "game started with coopMode " .. emu.read(CFG.coop_select.mode, MT_CPU)
    end
    -- the callback runs before the store commits, so apply the warp at the next tick start
    if CFG.start_round and CFG.start_round ~= 1 then pendingRound = CFG.start_round end
  end
end, emu.callbackType.write, CUR_ROUND, CUR_ROUND, emu.cpuType.nes, MT_CPU)

emu.addEventCallback(function()
  emu.setInput(curInput, 0)
  -- the Mesen config here uses the 4-player adapter on the expansion port: pads are subports of
  -- port 0 (pad 2 = port 0, subport 1; a plain emu.setInput(inp, 1) does not reach the game)
  if genInput2 then emu.setInput(curInput2, 0, 1) end
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frame = frame + 1
  if frame > CFG.ticks * 4 + 3000 then
    csv:write("TIMEOUT\n")
    finish(2)
  end
end, emu.eventType.endFrame)
