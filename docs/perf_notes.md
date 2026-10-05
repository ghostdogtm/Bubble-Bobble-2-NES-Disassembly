# Performance optimization notes (US build)

Working log for `tmp/bb2_performance_optimization_plan.md`. Every optimization is listed with
its regression result and measured cycle delta.

## Phase 0: baseline, harness, evidence

### 0.1 Byte identity
Unmodified sources build byte-identical to `Bubble Bobble Part 2 (U) [!].nes`
(`cmp` clean, 2026-10-05). After this point the ROM layout changes and regression is behavioral.

### 0.2 / 0.3 Regression harness (replaces savestates + input movies)
The plan's savestates + Mesen movies do not work for this project:

* **Savestates break after relinking.** A savestate stores the PC and the stack return addresses,
  and both point into code that has moved.
* **The game runs all its logic inside the NMI handler** (`nmiBankedSub`, after `CLI`). The main
  thread is the spin `CODE_0FE07E: JMP CODE_0FE07E`. When the logic overruns a frame, the next NMI
  takes `NMIShort` (lag frame: audio only), and the logic continues. A faster build lags less, so a
  frame-based movie would desync **even though behavior is identical**.

The harness (`tools/perf/`) is keyed to **logic ticks** instead of frames:

* `harness.lua`: runs headless in Mesen 2 `--testrunner` and hooks only RAM writes to
  `nmiProgress` ($15), so it does not depend on code layout. 0→1 = tick start, 1→3 = logic done,
  3→0 = audio done. NMIShort's `INC nmiProgress` dummy-writes the old value first, so the hook
  ignores 1→1.
  * The input is a deterministic pseudo-random function of the tick number (play segments that are
    aggressive, passive or idle). Lag frames therefore never shift the input.
  * New-game start is detected by `currentRound` ← 1. The round warp is a deferred write of
    `currentRound` at the next tick start; `playerLives` is topped up in warped scenarios.
  * Per tick it records: logic cycles, vblank cycles, audio cycles, lag NMIs, round, irqEffect,
    wideRound. With `--dump`: 2 KB RAM (at logic end) + nametables + palette (at tick start).
  * With `--profile`: Mesen exec counters per PRG-ROM byte.
* `perf.py`: `build`, `run`, `regress`, `stats`, `profile`, `cover`. It uses an isolated Mesen copy
  in `tmp/mesen` (Lua IO allowed, RAM power-on = zeros), created with
  `perf.py setup --mesen-src E:\silver\retro\multisystem\Mesen_2`. The user's Mesen config is
  never touched.

**Comparison rules** (`regress`): every tick's RAM/nametable/palette must match, except:
* the stack page above the pause buffer ($010A-$01FF), which holds return addresses;
* `scratch0-9`, dead temporaries at the snapshot point (counted as warnings);
* `ram_0020/24/25`, written **only** by the raster IRQ handlers (`CODE_0FEB25`, `CODE_0FEB7A`)
  and never read by logic. Their snapshot value depends on which scanline the logic finished on;
* pointer words ($16 $19 $1B $27 $35 $3C $3E $40 $42 $44 $55 $59 $5B $60 $6E $E3 $E6 $EA $0558).
  These are compared after translating both values to `bank:label+offset` with each build's
  ld65 debug file.

**Harness validation**
* Determinism: two identical builds compare identical in all scenarios.
* Positive control: a "shift" build (one extra byte at the top of banks 5/7/9/B/F, so every
  address moves) PASSES in all 11 scenarios. Getting there found the extra pointer words
  ($6E, $0558) and the IRQ-private bytes.
* Negative control: changing one constant (`CMP #$FF` → `#$FE` in the BUBBLE_EXPIRING handler)
  is caught in `camp03` at tick 4092 (`objState+21: 02 vs 19`). The first scenario set never
  reached that code: random play pops every bubble before its ~2000-tick lifespan. That gap led to
  the `camper` style and to the `cover` command (every agent must show its edited code executes).

**Scenarios** (picked from a sweep of rounds 1-80, `tmp/sweep.txt`):

| scen | what |
|---|---|
| natural | 6000 ticks from power-on, no warp, real lives: title, intro, round 1, deaths, game over, continue |
| r01 | round 1, enemy-dense, lags a lot |
| r08, r17, r33, r50 | irqEffect 1 rounds (r17/r50: heaviest lag) |
| r20 | wide round, irqEffect 5 |
| r40 | irqEffect 3 |
| r64, r69 | heaviest non-IRQ rounds |
| r70 | special round |
| camp03 | round 3, the player camps; bubbles and trapped enemies time out |

Warped scenarios spend about 1000 ticks in the unskippable story intro. `play` stats use
ticks ≥ 1200.

### 0.3 Baseline numbers (build `base`)
Logic cycles per tick (`perf.py stats base`). An NTSC frame is 29 780 CPU cycles; vblank work is
about 2-3k. lagNMI = lag frames over the run.

```
scen      ticks    mean    play     p95     max lagNMI
natural    6000   10743   11415   21694   38091     13
r01        3000   15343   20438   36340   48367    245
r08        3000   15652   20270   32224   44281    150
r17        3000   16731   22576   39341   51690    353
r20        3000   13421   16389   22612   31009      1
r33        3000   15639   20642   27126   33817     24
r40        3000   13210   16395   22444   33257      4
r50        3000   19619   26851   40951   55686    468
r64        3000   16982   22460   28982   37414     60
r69        3000   15216   19747   26816   30749      1
r70        3000   10544   13504   18916   25219      0
camp03     6000   14198   15884   19656   21340      0
```

Estimated exclusive cycles per routine over all gameplay scenarios. Exec counts × base opcode
cycles; the idle spin is excluded. A routine = a named label or an executed JSR target.

```
  0F:DrawObjects              31.94%     0F:AnimateObjects           1.44%
  0F:GetTile                   9.91%     0F:CODE_0FF986              1.25%
  09:BubblesTravelUpdate       8.30%     0F:CODE_0FF088              1.17%
  0F:ReadPad (NMI)             3.74%     0E:AudioUpdate (+subs)     ~3.2%
  0F:ColorBufferToVRAM (NMI)   2.90%     0F:PlayerCheckEnemyCollision 1.01%
  0F:NMISubRet (NMI)           2.34%     0F:SwapPrgBankA             0.97%
  0F:CODE_0FF852               2.11%     09:UpdateBubbles            0.92%
  0F:AnimateNonBubbles         1.76%     0F:SwapPrgBankB             0.65%
```

### 0.4 Plan assumptions vs. evidence
* **F1 is not a build artifact; it is an NMI race guard.** In the US build every $A000-window
  switch is `LDA #7 / STA $8000 / LDA bank / STA $8001 / STA prgBankB`. `NMIShort` (lag frame,
  `nmiProgress==1`, `irqEffect==0`) maps bank $0D for audio and then **restores $8001 from
  prgBankB**. If that NMI lands between `STA $8001` and `STA prgBankB`, it restores the *old* bank,
  and the second copy repairs it. Deleting the copy would re-open the race. **Correct rewrite: one
  copy in the JP order, `LDA #7 / STA $8000 / LDA bank / STA prgBankB / STA $8001`.** This is
  race-free:
  * an NMI before the `prgBankB` store restores the old bank, and then we write the new one;
  * an NMI after it restores the new bank.

  The IRQ handlers never touch $8000/$8001.
* F2 (`LDA #0 / ORA #7` → `LDA #7`) gives identical A and N/Z flags. Zero risk.
* **DrawObjects is the #1 consumer (32%)**, so plan item 5.1 meets the plan's own "profile proves
  it" condition. **UpdateBubbles is only 0.9% in total**, so the Phase 4 jump table can save at
  most a few hundred cycles on bubble-heavy ticks. Lower priority than DrawObjects / GetTile /
  BubblesTravelUpdate.
* The baseline **already lags** in dense rounds (r50: 468 lag frames per 3000 ticks). Lag count is
  the most player-visible metric and is tracked per phase.

## Phase 1: F2 (`LDA #0 / ORA #7`) + F1 (doubled $A000 switches)

**Status: committed** as two commits, F2 then F1. Both pass `regress` once the harness
handles lag-frame dependent state (see "Regression result" below).

### Sites
F2: all 40 `LDA #$00` / `ORA #$07` pairs (US branches only) became `LDA #$07`. Each pair was
adjacent with no label on the `ORA` line. No other `LDA #$00` / `ORA #imm` pairs exist. Saves
2 cycles and 2 bytes per pair. All 40 pairs sit inside the 20 doubled blocks below, so F1
supersedes F2 at every site.

F1: 21 doubled MMC3 command-7 blocks became one race-free copy:
`LDA #7 / STA $8000 / LDA bank / STA prgBankB / STA $8001`.
Before: `(LDA #0 / ORA #7 / STA $8000 / LDA bank / STA $8001 / STA prgBankB) x2`. SwapPrgBankB had
the same block without the ORA. Cycles saved per execution: immediate bank 19, absolute
(`sprPrgBank`, `terrainBank`) 21, zero page (`newPrgBank`) 20. Exec counts are summed over the
12 scenarios (`cover p1`).

| bank | label (base addr) | bank operand | saved cyc | execs |
|---|---|---|---|---|
| 07 | CODE_078916 ($8916) | #.BANK(DATA_04BE45) | 19 | 14294 |
| 08 | CODE_089D6A ($9D6A) | #.BANK(RoundMaps) | 19 | **0** |
| 09 | in CODE_0986AB ($86BE) | #.BANK(DATA_04BF88) | 19 | **0** |
| 09 | CODE_099CB7 ($9CB7) | #.BANK(DATA_06B8B6) | 19 | **0** |
| 09 | CODE_099EA5 ($9EA5) | #.BANK(DATA_04BF6D) | 19 | 12728 |
| 0B | CODE_0B81E3 ($81E9) | #.BANK(AnimTable) | 19 | 14275 |
| 0B | after JSR CODE_0FF088 ($8225) | #.BANK(AnimTable) | 19 | 39529 |
| 0F | AnimateObjects ($ED1E) | #.BANK(AnimTable) | 19 | 14295 |
| 0F | CODE_0FEDA3 ($EDA7), `;Unreached` | #.BANK(ImageTable1) | 19 | **0** |
| 0F | AnimateNonBubbles ($EE5C) | #.BANK(AnimTable) | 19 | 18826 |
| 0F | DrawObjects ($EEE2) | sprPrgBank | 21 | 35705 |
| 0F | GetTile ($F4DA) | #.BANK(RoundsFlowTable) | 19 | 89436 |
| 0F | GetTile/CODE_0FF50A ($F50A), `;Unreached` (irqEffect 2) | #.BANK(RoundsFlowTable) | 19 | **0** |
| 0F | GetTile terrain ($F577) | terrainBank | 21 | 270595 |
| 0F | CODE_0FF5E6 ($F5EE) | #.BANK(RoundsFlowTable) | 19 | 32439 |
| 0F | CheckWall ($F7E2) | terrainBank | 21 | 44575 |
| 0F | CheckFloor ($F81A) | terrainBank | 21 | 45004 |
| 0F | CODE_0FF852 ($F852) | terrainBank | 21 | 144696 |
| 0F | CODE_0FF8F3 ($F8F3) | terrainBank | 21 | 2172 |
| 0F | CODE_0FF986 ($F986) | #.BANK(RoundsFlowTable) | 19 | 63483 |
| 0F | SwapPrgBankB ($FF56) | newPrgBank | 20 | 103536 |

Coverage: 16 of 21 sites run in the scenarios. The 5 sites with 0 executions are justified by
analysis only: CODE_089D6A, the bank-09 sites at $86BE and $9CB7, and the two `;Unreached` blocks.
Bytes freed vs base (F2+F1): bank 7 +16, bank 8 +16, bank 9 +48, bank B +32, bank F +226
(16 per immediate block, 17 per absolute block, 12 in SwapPrgBankB).

### Race analysis
* End state without an interrupt: A = bank, N/Z from `LDA bank` (STA does not change flags),
  X/Y/C/V untouched, $8000 = 7, $8001 = bank, prgBankB = bank. This is the same as the doubled
  form. The bank operands (`sprPrgBank`, `terrainBank`, `newPrgBank`) are not written by any
  interrupt handler, so reading them once instead of twice is equivalent.
* NMIShort (lag NMI, `nmiProgress==1 && irqEffect==0`) leaves $8000 = 7 and $8001 = prgBankB.
  If it lands before `STA prgBankB`, it restores the old bank and the following `STA $8001`
  writes the new one. If it lands after, it restores the new bank. Either way the end state is
  correct, and the selector register is 7 again before the `STA $8001`.
* A full NMI (nmiProgress 0) never interrupts these blocks. After reset, NMI is enabled only
  when the main thread enters its `JMP *` spin. The reset-time SwapPrgBankB call runs with NMI
  disabled. Inside the NMI, nested NMIs always take NMIShort because nmiProgress is not 0.
* The raster IRQ handlers do not touch $8000/$8001/prgBankB.
* The single `C D 0` (code read as data) flag in the whole disassembly, on SwapPrgBankB's second
  `LDA newPrgBank` ($FF67), is not a data dependency. A Mesen read-watch on $FF3D-$FF6E over all
  12 scenarios on `base` (`tmp/p1_scripts/readwatch.py`) logs only reads where PC == the read
  address. These are the 6502's dummy reads on interrupt entry, so an interrupt landed on that
  instruction. The same watch shows interrupts landing inside both switch helpers, including
  between `STA $8001` and `STA prgBankB` ($FF60). The race windows are real.
* **Deliberately left alone:**
  * **SwapPrgBankA** (command 6, 158684 execs, would save 16 cycles each). *(Superseded in
    Phase 2+3: single copy + nmiProgress check, which also fixes the race.)* For a command-6
    switch, an NMIShort between `STA $8000 (=6)` and `STA $8001` redirects the `$8001` write
    into the $A000 slot. With the doubled form, the second copy still maps the $8000 window
    correctly and only $A000 is wrong until the next command-7 switch. With a single copy, both
    windows are wrong, and RunBankedSub then jumps into the wrong $8000 bank. So the double copy
    does partly protect command 6, and collapsing it is not behavior-neutral under the race. No
    single-copy order is race-free for command 6, because NMIShort clobbers the selector.
  * **SetRoundIRQ** *(fixed in Phase 2+3)* (single copy in the unsafe order `STA $8001 / STA prgBankB`, 13 execs). It
    has a latent race but saves no cycles, so it is out of scope. Reordering it would be a bug
    fix, not an optimization.
  * NMI handler (CHR/PRG reloads, NMIShort), IRQ handlers, ReadPad, bank 0E, and all
    `.ifdef REGION_JP` code.
* The JP build assembles and is byte-identical to the JP build of the base commit
  (md5 8d2855ea5505bf094b7a40155caa92b4).

### Regression result
The first regress run failed in 8 of 12 scenarios, each time at the first tick where `base` had
a lag NMI during the logic and the faster build did not. At that tick the only differing bytes
were:
* `nmiProgress` ($15): 2 vs 1 (2 = "a lag NMI arrived"). Only the NMI code reads it.
* Audio-engine RAM ($E0-$F1, $0790-$07F5), in irqEffect 0 rounds. NMIShort runs `AudioUpdate`
  on lag frames, so the audio advances once per *frame*. After a lag frame disappears, the audio
  stays one update behind relative to the logic ticks.

The comparator used to stop at the first mismatch, so everything after these ticks was
unverified. The shift control build in Phase 0 could not expose this, because it barely changes
cycle counts and so keeps the same lag pattern.

**Harness change (approved by the owner, commit "Perf harness: tolerate lag-frame dependent
state"):**
* $15 is ignored on ticks where the two runs disagree about lag.
* From the first such tick on, the audio-engine-private RAM ($E3-$F1, $0790-$07F5) is ignored.
* The triggers the logic writes ($E0-$E2) stay compared, with bit 7 masked: the engine sets bit 7
  ("started") on its own frame-based schedule.
* Everything else stays strictly compared on every tick.

Outside bank 0E, the logic touches audio RAM in only two places: it writes `$07F5` (bank 0B) and
`SetRoundMusic` does `CMP musicTrigger`. The second only decides whether to re-send the round
music trigger, which affects audio only. The `camp03` negative control is still caught after the
change.

Result with the new comparator:
* p1a (F2): 12/12 PASS.
* p1 (F1+F2): 12/12 PASS. In 8 scenarios the lag pattern changes (first at ticks 987-5746); all
  ticks after that point are verified too.

### Measured delta (`stats p1 --vs base`, F1+F2)
```
scen      ticks    mean    play     p95     max lagNMI |  d_play d_play%   d_p95  d_lag
natural    6000   10472   11109   21222   37686     12 |    -306  -2.68%    -472     -1
r01        3000   14928   19839   35982   47346    236 |    -600  -2.93%    -358     -9
r08        3000   15203   19658   31546   43411    130 |    -612  -3.02%    -678    -20
r17        3000   16186   21788   37937   50262    323 |    -788  -3.49%   -1404    -30
r20        3000   13139   15997   22286   30646      1 |    -392  -2.39%    -326      0
r33        3000   15156   19929   26520   33147     14 |    -714  -3.46%    -606    -10
r40        3000   12763   15760   21261   32822      4 |    -634  -3.87%   -1183      0
r50        3000   18992   25946   39998   54847    408 |    -905  -3.37%    -953    -60
r64        3000   16416   21656   27704   37121     32 |    -804  -3.58%   -1278    -28
r69        3000   14687   18998   25340   28994      0 |    -749  -3.79%   -1476     -1
r70        3000   10325   13158   18541   24865      0 |    -346  -2.56%    -375      0
camp03     6000   13784   15394   18779   20334      0 |    -489  -3.08%    -877      0
TOTAL    play-mean sum delta -7340 cycles (-3.24%)
```
F2 alone (`p1a`): -1337 cycles total (-0.59%). The plan estimated 50-150 cycles/frame for
Phase 1; the measured gain is 300-900 cycles per gameplay tick, because the terrain probes
(GetTile, CheckWall/Floor, CODE_0FF852) run the doubled switch hundreds of thousands of times.
Profile runs are in `tmp/runs/p1` (`run p1 --profile`).

## Phase 2+3: race fixes and bank-switch guards

**Status: committed** as five commits: two race fixes, then three guard commits. Each one passes
`regress base <build> --reuse-base` 12/12. The final build is `p3` (= HEAD); its profile runs
are in `tmp/runs/p3`. Tools are in `tmp/p2_scripts/` (`inv.py`, `invsum.py`, `invtot.py`,
`race.py`). They use their own Mesen copy in `tmp/p2_scripts/mesen`.

### Invariant I and why guards need it
A guard `LDA bank / CMP prgBankB / BEQ skip` is only correct if, whenever logic code runs
between switch sequences, **the $A000 slot holds prgBankB** (invariant I). In the original
game, any break of I is healed by the next unconditional switch. A guard would skip that
switch and leave the wrong bank mapped. So every source that can break I must be closed
before any guard is added.

**Static inventory** of US-effective writes to $8000/$8001 and prgBankB (JP-only branches
excluded; `tmp/p2_scripts/usfilter.py`):

| writer | context | cmd | can it break I? |
|---|---|---|---|
| 21 Phase-1 sites (`LDA #7 / STA $8000 / LDA bank / STA prgBankB / STA $8001`): CODE_078916, CODE_089D6A, CODE_0986AB+19, CODE_099CB7, CODE_099EA5, CODE_0B81E3, CODE_0B8216, AnimateObjects, CODE_0FEDA3, AnimateNonBubbles, DrawObjects, GetTile (3), CODE_0FF5E6, CheckWall, CheckFloor, CODE_0FF852, CODE_0FF8F3, CODE_0FF986, SwapPrgBankB | logic | 7 | no (race-free order; selector written in the same sequence) |
| SetRoundIRQ | logic, round setup | 7 | **yes**: `STA $8001 / STA prgBankB` (race b) -> fixed |
| SwapPrgBankA (doubled) | logic (RunBankedSub, SpawnProj, ...) | 6 | **yes**: NMIShort between `STA $8000` and `STA $8001` (race a) -> fixed |
| full NMI tick start (`CODE_0FE1B6`) | NMI, nmiProgress 1 | 0-7 | no: it starts the tick with $A000 = prgBankB = nmiPrgBankB. Its unsafe cmd-7 order could only be hit by a second NMI during vblank work (one frame later) |
| post-logic `JSR SwapPrgBankB` ($0D) | NMI, nmiProgress 3 | 7 | no: NMIShort does not swap banks at nmiProgress 3 |
| NMIShort | lag NMI, nmiProgress 1 -> 2 | 7 | restores $A000 from prgBankB, at most once per tick, and leaves the selector at 7 |
| MemInit (zero-fills prgBankB) | reset, NMI off | - | no: the reset SwapPrgBankB follows |
| raster IRQ handlers, bank 0E audio | - | - | no $8000/$8001/prgBankB writes |

No logic code writes CHR commands 0-5 (in the US build only the full NMI writes them, from
the chrBankA-F shadows). No `STA $8001` relies on a selector value left by earlier code:
every logic writer sets $8000 in the same sequence. So a guard skip path, which leaves the
selector at whatever it was (6 after SwapPrgBankA), is safe.

**Runtime inventory** (`inv.py --stores`, all 12 scenarios on p1). Every executed store to
$8000-$9FFF and $53 is hooked:
* All 1,599,647 even-address writes and all odd-address writes come from the sites above.
  The totals from the write callback equal the per-site sums.
* The selector seen by each `STA $8001` is always the intended one. SwapPrgBankA's two
  $8001 writes always saw selector 6, so race (a) never happened.
* prgBankB: 987,678 of 987,690 writes come from the sites above. The other 12 are MemInit,
  once per scenario at reset.
* On `base`, 3 of the 12 store-inventory runs (natural, r17, camp03) were cut off by the
  Mesen test runner's ~100 s CPU limit (see below). The 37,756 ticks they did cover are also
  fully attributed.

### Measurement: does the race actually happen?
`inv.py` checks I (`$A000` bank vs prgBankB) at every tick end, every GetTile entry, the start
of every $A000 switch site, and every SwapPrgBankA/B entry. The mapped bank comes from a Lua
shadow of the MMC3 registers fed by a write callback. That shadow is validated against
`emu.convertAddress(0xA000)` at every tick end: 0 mismatches in 42,002 ticks. At each NMI
entry the interrupted PC is read from the stack. (The state PC in an `eventType.nmi` callback
is already the handler address $E148, so it cannot be used.)

| build | I checks | violations | bank-swapping NMIShorts during logic | ... in vulnerable windows |
|---|---|---|---|---|
| base | 1,478,833 | 0 | 319 (natural 13, r01 245, r64 60, r69 1) | 0 |
| p1   | 1,478,429 | 0 | 280 (natural 12, r01 236, r64 32) | 0 |
| p3   | 1,416,945 | 0 | 272 (natural 12, r01 229, r64 31) | 0 |

Vulnerable windows: interrupted PC = SwapPrgBankA's `LDA newPrgBank` or `STA $8001` (either
copy), or SetRoundIRQ's second store. Lag NMIs in irqEffect rounds (r08/r17/r33/r50: the
heaviest lag) do not swap banks. The swapping ones land mostly in DrawObjects (CODE_0FF022,
CODE_0FEFF5, ...). SwapPrgBankA is always entered with nmiProgress 1. **The races are real
but did not occur in any test run.**

**Fault injection** (`race.py BUILD r01 A|I`): just before the vulnerable instruction, do
exactly what NMIShort does via `emu.write` (nmiProgress=2, $8000=7, $8001=$0D, $8000=7,
$8001=prgBankB).
* SwapPrgBankA, 177 injections. On base and p1, 227 SwapPrgBankA returns have
  $A000 != prgBankB (the $8000 window is always right), plus 1 bad GetTile entry. On p3:
  0 and 0.
* SetRoundIRQ, 1 injection at the round-1 start. On base and p1, `LDA IRQRounds,X` reads the
  wrong bank and round 1 runs with **irqEffect 5** instead of 0. On p3: irqEffect 0, as
  normal.

### Race fixes (commits 1-2)
* **SwapPrgBankA**: one copy of the cmd-6 switch, then `LDA nmiProgress / AND #1 / BEQ
  @lagNMI / LDA newPrgBank / RTS`. NMIShort swaps banks only at nmiProgress 1 and bumps it to
  2 first, and nothing lowers it during the logic. So "still odd" (1, or 3 outside the logic)
  means no swap can have happened. Otherwise `@lagNMI` redoes the cmd-6 switch and re-asserts
  $A000 from prgBankB; NMIShort cannot swap again in that tick. AND does not touch C/V, and
  the final `LDA newPrgBank` restores A and N/Z, so the outputs are identical to the doubled
  form. Cost: 26 instead of 32 cycles (-6 per call, 158,684 calls); @lagNMI costs about +31
  extra. **Race outcome changes from "$A000 wrong until the next switch" to "correct".**
  @lagNMI ran 0 times in the scenarios: no lag NMI came before a later SwapPrgBankA call in
  the same tick. It is covered by the fault injection above.
* **SetRoundIRQ**: `STA prgBankB / STA $8001` (race-free order). 13 executions.
  **Race outcome changes from "wrong IRQ-effect table read, I broken" to "correct".**

### Guards (commits 3-5)
Redundancy = the target bank already equals prgBankB when the site runs. It is measured per
site over the 12 scenarios with `inv.py` (identical on base and p1). Costs per execution:
* immediate bank (`LDA #b / CMP / BEQ` + the old 15-cycle switch): skip -7, needed +7;
* terrainBank (abs): skip -7 (10 vs 17), needed +8 (25 vs 17). The needed path is
  `STA prgBankB / LDA #7 / STA $8000 / LDA prgBankB / STA $8001`, which is race-free and
  gives the same A and N/Z;
* caller-side `CMP prgBankB / BEQ` around `JSR SwapPrgBankB`: skip -22 (JSR, RTS and the
  helper body), needed +5.

| site (p3 addr) | redundant | execs | needed | est. cycles saved (12 scen) |
|---|---|---|---|---|
| GetTile terrain switch, irqEffect 0/5 paths (CODE_0FF56E, $F535) | 82.9% | 181,174 | 31,033 | 1,051k - 248k = **803k** |
| GetTile flow path (irqEffect 1/3/4): own copy of the tail, unguarded switch without `STA $8000` (selector still 7 from the RoundsFlowTable switch), +1 JMP | 0% (so not guarded) | 89,436 | all | 6 - 3 = 3 per call: **268k** |
| CODE_0FF852 ($F7E5) | 100% | 144,696 | 0 | **1,013k** |
| CheckFloor ($F7B8) | 100% | 45,004 | 0 | **315k** |
| CheckWall ($F78B) | 100% | 44,575 | 0 | **312k** |
| CODE_0FF8F3 ($F87B) | 100% | 2,172 | 0 | 15k |
| CODE_0FF986 ($F903), RoundsFlowTable | 85.6% | 63,483 | 9,137 | **316k** |
| CODE_0FF5E6 ($F5A1), RoundsFlowTable | 81.9% | 32,439 | 5,863 | **145k** |
| UpdateProjectiles_ReadOp ($8DC6, bank 9) `JSR SwapPrgBankB` | 83.6% | 30,155 | 4,938 | 555k - 25k = **530k** |

Plus SwapPrgBankA -6 × 158,684 = 952k. Sum of estimates: about 4.67M cycles over all 12
scenarios. The profile's busy-cycle total falls from 605.59M to 600.39M (-5.2M). The profile
counts base opcode cycles only, so each taken guard branch looks 1 cycle cheaper than it is.
All guard branches stay on their page (checked).

**Not guarded (measured):** GetTile's RoundsFlowTable switch (2.7%), DrawObjects (0%),
AnimateObjects (0%), AnimateNonBubbles (0.1%), CODE_0B8216 (5.0%), CODE_0B81E3 / CODE_078916 /
CODE_099EA5 (0%), cold or unexecuted sites. **SwapPrgBankB in-helper guard: not done.** Only
24.4% of all calls are redundant (41% of logic-time calls; the post-logic $0D switch, 42,010
calls, never is), and an in-helper guard saves only 7 and costs 8. The per-caller measurement
found a single hot redundant caller (UpdateProjectiles_ReadOp above). The other callers with
more than 1000 calls are all 0% redundant: UpdateProjectiles+4, @active+16, CODE_0B9ED1 (x2),
CODE_05894D, CODE_078731, RuckusUpdate.

**Plan item 2.4 (hoisting the switch out of probe bursts): not done.** GetTile is still 8.8%
of busy cycles, but that is about 195 cycles per call of real lookup work. After the guard the
switch costs 10 cycles on the common path, so a hoist could save at most about 10 per call
(1.8M upper bound, about 0.3%). It would also need a proof for each of the 40 call sites.

**Flag/register audit.** On the skip path the guard leaves C=1, Z=1, N=0, A=bank, and
$8000 unwritten. The original left C unchanged and N/Z from `LDA bank`. Every guarded
continuation reloads A and redefines N/Z/C before any use:
* CheckWall/CheckFloor/CODE_0FF852/CODE_0FF8F3: `LDA scratch4 / CMP`;
* CODE_0FF986: `LDA ram_0046 / LSR`;
* CODE_0FF5E6: `LDA scratch0 / AND`, then `CLC/ADC`;
* GetTile: `LDA (terrainAdr),Y`, then `ASL`;
* UpdateProjectiles_ReadOp: `LDY / LDA / ASL`.

The probe routines redefine all flags after the switch, so callers see the same flags after
RTS. X/Y are untouched, and newPrgBank is still written at the caller-side guard.

**Coverage (`cover p3`, summed over 12 scenarios):**
* GetTile: guard 181,159 (needed path 31,032); flow tail 89,436 (CODE_0FF563f 45,215).
* CODE_0FF986: guard 63,483 (needed 9,137). CODE_0FF5E6: guard 32,439 (needed 5,863).
* UpdateProjectiles_ReadOp: guard 30,155 (JSR 4,938).
* SwapPrgBankA: 158,684. SetRoundIRQ: 13.
* **Never executed:** the needed paths of CheckWall/CheckFloor/CODE_0FF852/CODE_0FF8F3 (they
  always follow GetTile with terrainBank mapped) and SwapPrgBankA's @lagNMI. These are
  justified by analysis and, for @lagNMI, by the fault injection.

JP build: assembles, byte-identical to before (md5 8d2855ea5505bf094b7a40155caa92b4). Every
edit is in a US-only `.else` / `.ifndef REGION_JP` branch; new shared lines are labels only.
Free bytes: bank 9 311 -> 307, bank F 371 -> 279.

### Regression
```
p2r1 (SwapPrgBankA fix)            REGRESSION PASS (12/12)
p2a  (+ SetRoundIRQ order)         REGRESSION PASS (12/12)
p2b  (+ GetTile guard/flow split)  REGRESSION PASS (12/12)
p2c  (+ 6 probe guards)            REGRESSION PASS (12/12)
p2d = p3 (+ UpdateProjectiles_ReadOp guard)  REGRESSION PASS (12/12)
```
p3, per scenario: natural, r01, r08, r17, r33, r50, r64 and r69 pass with the lag pattern
changing at the same ticks as p1 (5746, 2306, 1216, 1760, 1736, 1276, 987, 1105). r20, r40,
r70 and camp03 are identical on every tick.

Step deltas (play-mean sum): SwapPrgBankA -402, SetRoundIRQ 0, GetTile -444, probe guards
-916, UpdateProjectiles_ReadOp -242.

### Measured delta (`stats p3 --vs p1`)
```
scen      ticks    mean    play     p95     max lagNMI |  d_play d_play%   d_p95  d_lag
natural    6000   10396   11022   21035   37584     12 |     -87  -0.78%    -187      0
r01        3000   14812   19667   35797   47140    229 |    -172  -0.87%    -185     -7
r08        3000   15069   19468   31305   43153    122 |    -190  -0.97%    -241     -8
r17        3000   16069   21612   37615   49754    315 |    -176  -0.81%    -322     -8
r20        3000   13051   15872   22191   30533      1 |    -125  -0.78%     -95      0
r33        3000   15050   19768   26414   32942     13 |    -161  -0.81%    -106     -1
r40        3000   12676   15636   21017   32710      4 |    -125  -0.79%    -244      0
r50        3000   18830   25713   39733   54523    401 |    -234  -0.90%    -265     -7
r64        3000   16201   21350   27159   37004     31 |    -306  -1.41%    -545     -1
r69        3000   14551   18804   25015   28859      0 |    -194  -1.02%    -325      0
r70        3000   10255   13043   18453   24770      0 |    -115  -0.88%     -88      0
camp03     6000   13682   15273   18564   20098      0 |    -121  -0.79%    -215      0
TOTAL    play-mean sum delta -2004 cycles (-0.91%)
```

### Measured delta (`stats p3 --vs base`, Phases 1-3)
```
scen      ticks    mean    play     p95     max lagNMI |  d_play d_play%   d_p95  d_lag
natural    6000   10396   11022   21035   37584     12 |    -393  -3.44%    -659     -1
r01        3000   14812   19667   35797   47140    229 |    -771  -3.77%    -543    -16
r08        3000   15069   19468   31305   43153    122 |    -802  -3.96%    -919    -28
r17        3000   16069   21612   37615   49754    315 |    -964  -4.27%   -1726    -38
r20        3000   13051   15872   22191   30533      1 |    -517  -3.15%    -421      0
r33        3000   15050   19768   26414   32942     13 |    -874  -4.24%    -712    -11
r40        3000   12676   15636   21017   32710      4 |    -759  -4.63%   -1427      0
r50        3000   18830   25713   39733   54523    401 |   -1138  -4.24%   -1218    -67
r64        3000   16201   21350   27159   37004     31 |   -1110  -4.94%   -1823    -29
r69        3000   14551   18804   25015   28859      0 |    -943  -4.77%   -1801     -1
r70        3000   10255   13043   18453   24770      0 |    -461  -3.42%    -463      0
camp03     6000   13682   15273   18564   20098      0 |    -610  -3.84%   -1092      0
TOTAL    play-mean sum delta -9344 cycles (-4.12%)
```
Lag frames vs base: -191 over all scenarios (vs p1: -32).

### Profile (`profile p3 --scen r01 r17 r50 r64 --top 15 --vs p1`)
```
estimated busy cycles over r01, r17, r50, r64: 202730059 (p1: 204720486)
  0F:DrawObjects                               62717996  30.94%   delta +0
  09:BubblesTravelUpdate                       22036924  10.87%   delta -20
  0F:GetTile                                   17219040   8.49%   delta -345197
  0F:ReadPad                                    6957092   3.43%   delta +0
  0F:ColorBufferToVRAM                          5387403   2.66%   delta +0
  0F:NMISubRet                                  4355384   2.15%   delta +0
  0F:AnimateNonBubbles                          3432694   1.69%   delta +0
  0F:AnimateObjects                             3191717   1.57%   delta +0
  0F:CODE_0FF852                                2992820   1.48%   delta -362264
  0F:CODE_0FF986                                2827747   1.39%   delta -207614
  0F:CODE_0FF088                                2526270   1.25%   delta +0
  0F:CODE_0FF5E6                                2507191   1.24%   delta -106764
  0F:CODE_0FEADA                                2356087   1.16%   delta -11930
  0F:Begin                                      2212016   1.09%   delta +0
  09:0x8290                                     2013285   0.99%   delta +0
```
In the all-scenario profile, some bank-9 routine names change (`09:CODE_099E2A` becomes
`09:0x9e0a`). This is a naming artifact: bank 9 grew by 4 bytes, so a JSR-target entry no
longer lands on a label. It is not a cost change.

### Tooling notes
* The Mesen test runner kills a run after about **100 s of CPU time** (rc -1 or 127),
  whatever `ScriptTimeout` is set to. Plain harness runs take 20-40 s, so the harness is not
  affected, but heavy Lua instrumentation is. For that reason `inv.py` splits its checks into a
  "check" pass and a "stores" pass and avoids `emu.getState()` in hot callbacks.
* `emu.convertAddress(0xA000, emu.memType.nesMemory)` returns `{address, memType}` with
  memType = nesPrgRom and address = PRG offset (bank = address // 0x2000). Exec callbacks
  can be registered on `emu.memType.nesPrgRom` offsets, which avoids ambiguous $8000-$BFFF
  addresses. `emu.write` to $8000/$8001 reaches the MMC3 registers.

### Possible follow-up (not done)
**Selector invariant.** Logic code writes only commands 6 and 7, and NMIShort and the full
NMI leave the selector at 7. If SwapPrgBankA restored the selector to 7 (+6 cycles per call),
every $A000 switch could drop its `LDA #7 / STA $8000` (-6 per switch, about 0.95M switches).
That would be a net gain of about 4.7M cycles. It is a new global invariant (every future
$8000 writer must restore 7), so it needs the owner's approval.
