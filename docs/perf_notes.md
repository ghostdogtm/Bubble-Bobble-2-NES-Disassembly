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
