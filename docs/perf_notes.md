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
  * **SwapPrgBankA** (command 6, 158684 execs, would save 16 cycles each). For a command-6
    switch, an NMIShort between `STA $8000 (=6)` and `STA $8001` redirects the `$8001` write
    into the $A000 slot. With the doubled form, the second copy still maps the $8000 window
    correctly and only $A000 is wrong until the next command-7 switch. With a single copy, both
    windows are wrong, and RunBankedSub then jumps into the wrong $8000 bank. So the double copy
    does partly protect command 6, and collapsing it is not behavior-neutral under the race. No
    single-copy order is race-free for command 6, because NMIShort clobbers the selector.
  * **SetRoundIRQ** (single copy in the unsafe order `STA $8001 / STA prgBankB`, 13 execs). It
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
