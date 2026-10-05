#!/usr/bin/env python3
"""Build / run / compare / profile harness for the Bubble Bobble Part 2 (US) optimization work.

Commands (run from the repo root):
  perf.py setup  --mesen-src DIR      copy Mesen 2 into tmp/mesen with Lua IO enabled, RAM zeroed
  perf.py build  NAME                 build the US ROM into tmp/builds/NAME/ (rom, map, labels, dbg)
  perf.py run    NAME [--scen S ...] [--dump] [--profile]
                                      run scenarios on build NAME -> tmp/runs/NAME/<scen>.*
  perf.py regress BASE TEST [--scen ...]
                                      run scenarios (with dumps) on both builds and compare per tick
  perf.py stats  NAME [--vs BASE]     logic-cycle statistics per scenario (and delta vs BASE)
  perf.py profile NAME [--scen S] [--top N] [--vs BASE]
                                      estimated exclusive cycles per routine from exec counters
  perf.py cover  NAME LABEL...        per-instruction exec counts (needs runs made with --profile)

The regression check compares, for every logic tick, the 2 KB of CPU RAM (snapshot when the
banked game logic finishes) plus nametable RAM and palette (snapshot at the start of the tick).
Excluded: the hardware stack ($010A-$01FF), the IRQ-handler-private bytes $20/$24/$25, and
lag-frame dependent state (nmiProgress on ticks whose lag differs; audio-engine RAM once the lag
pattern has diverged - audio triggers $E0-$E2 stay compared with bit 7 masked). RAM words that hold code pointers are compared after
translating them through the symbol tables of both builds (label + offset), so relinking does
not cause false mismatches.
"""
import argparse
import bisect
import os
import re
import shutil
import struct
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TMP = os.path.join(ROOT, "tmp")
MESEN_DIR = os.path.join(TMP, "mesen")
BUILDS = os.path.join(TMP, "builds")
RUNS = os.path.join(TMP, "runs")
HARNESS = os.path.join(ROOT, "tools", "perf", "harness.lua")

JOBS = max(1, min(8, (os.cpu_count() or 2) - 2))
RAM_SIZE = 0x800
REC_SIZE = RAM_SIZE + 0x800 + 0x20

# name: (ticks, seed, start_round, inf_lives, start_taps[, style])
SCENARIOS = {
    # picked from a sweep of rounds 1-80 (tmp/sweep.txt). The story intro after Start takes
    # ~1000 ticks and cannot be skipped, so warped scenarios get ~2000 ticks of play.
    "natural": (6000, 11, None, False, True),   # power-on, title, round 1, deaths, game over/continue
    "r01": (3000, 21, 1, True, False),          # lags often (enemy-dense)
    "r08": (3000, 22, 8, True, False),          # irqEffect 1
    "r17": (3000, 23, 17, True, False),         # irqEffect 1, heaviest lag in sweep
    "r20": (3000, 24, 20, True, False),         # wide round, irqEffect 5
    "r33": (3000, 25, 33, True, False),         # irqEffect 1, heavy
    "r40": (3000, 26, 40, True, False),         # irqEffect 3
    "r50": (3000, 27, 50, True, False),         # irqEffect 1, heavy
    "r64": (3000, 28, 64, True, False),         # heaviest non-IRQ round
    "r69": (3000, 29, 69, True, False),         # heavy
    "r70": (3000, 30, 70, True, False),         # special round (low load)
    "camp03": (6000, 31, 3, True, False, "camper"),  # bubbles/trapped enemies expire, enemies get mad
}
DEFAULT_SCENS = list(SCENARIOS)

# RAM words (lo address) that may hold code/data pointers into PRG ROM: every ($indirect) /
# ($indirect),Y / ($indirect,X) base listed in src/ram.inc (except scratch), plus updateSub.
# Validated with a "shift" build (extra byte at the top of banks 5/7/9/B/F) - see docs/perf_notes.md.
POINTER_WORDS = [0x16, 0x19, 0x1B, 0x27, 0x35, 0x3C, 0x3E, 0x40, 0x42, 0x44, 0x55, 0x59, 0x5B, 0x60,
                 0x6E, 0xE3, 0xE6, 0xEA, 0x558]
# scratch bytes: dead temporaries at the snapshot point; differences are reported as warnings
SCRATCH = set(range(0x00, 0x0A))
STACK = set(range(0x10A, 0x200))
# written only by the raster IRQ handlers (CODE_0FEB25 / CODE_0FEB7A) and never read by game logic;
# their value at the snapshot point depends on which scanline the logic finished on.
IRQ_VOLATILE = {0x20, 0x24, 0x25}
# Lag-frame dependent state (approved relaxation, see docs/perf_notes.md "Phase 1"):
# - nmiProgress ($15) at the snapshot is 2 instead of 1 iff a lag NMI arrived during the tick;
#   ignored on ticks where the two runs disagree about lag.
# - The audio engine advances once per *frame* (NMIShort runs AudioUpdate on lag frames), so once
#   the lag pattern differs its RAM is legitimately out of step with the logic ticks. From the
#   first tick with differing lag on, the engine-private RAM is ignored and the trigger bytes the
#   logic writes ($E0-$E2) are compared with bit 7 ("started" flag set by the engine) masked.
NMI_PROGRESS = 0x15
AUDIO_TRIGGERS = {0xE0, 0xE1, 0xE2}
AUDIO_PRIVATE = set(range(0xE3, 0xF2)) | set(range(0x790, 0x7F6))


def sh(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        raise SystemExit(f"command failed: {cmd}")
    return r


# ---------------------------------------------------------------------------------------- setup
def cmd_setup(a):
    src = a.mesen_src
    os.makedirs(MESEN_DIR, exist_ok=True)
    for f in ["Mesen.exe", "MesenCore.dll", "libHarfBuzzSharp.dll", "libSkiaSharp.dll", "settings.json"]:
        shutil.copy2(os.path.join(src, f), MESEN_DIR)
    p = os.path.join(MESEN_DIR, "settings.json")
    s = open(p, encoding="utf-8").read()
    s = s.replace('"AllowIoOsAccess": false', '"AllowIoOsAccess": true')
    s = re.sub(r'"ScriptTimeout": \d+', '"ScriptTimeout": 100', s)
    s = s.replace('"RamPowerOnState": "Random"', '"RamPowerOnState": "AllZeros"')
    open(p, "w", encoding="utf-8").write(s)
    print("Mesen copied to", MESEN_DIR)


# ---------------------------------------------------------------------------------------- build
def cmd_build(a):
    d = os.path.join(BUILDS, a.name)
    os.makedirs(d, exist_ok=True)
    obj = os.path.join(d, "main.o")
    defs = ["-D", "REGION_US"] + sum([["-D", x] for x in (a.define or [])], [])
    sh(["ca65", "-g"] + defs + ["src/main.asm", "-o", obj], cwd=ROOT)
    sh(["ld65", "-C", "config_us", "-Ln", os.path.join(d, "labels.txt"), "-m", os.path.join(d, "rom.map"),
        "--dbgfile", os.path.join(d, "rom.dbg"), "-o", os.path.join(d, "rom.nes"), obj], cwd=ROOT)
    print("built", os.path.join(d, "rom.nes"))
    syms = Symbols(a.name)
    for seg, (start, size, bank) in sorted(syms.segs.items(), key=lambda x: x[1][2] if x[1][2] is not None else 99):
        if seg.startswith("PRG_BANK"):
            print(f"  {seg:18s} size=${size:04X} free={0x2000 - size if seg != 'PRG_BANK_E' else 0x1300 - size}")


# ---------------------------------------------------------------------------------------- symbols
class Symbols:
    def __init__(self, build):
        self.segs = {}
        self.byseg = {}
        segid = {}
        dbg = os.path.join(BUILDS, build, "rom.dbg")
        for line in open(dbg):
            kind, _, rest = line.rstrip("\n").partition("\t")
            f = dict(re.findall(r'(\w+)=("[^"]*"|[^,]*)', rest))
            if kind == "seg" and "ooffs" in f:
                name = f["name"].strip('"')
                bank = int(f["bank"]) if "bank" in f else None
                self.segs[name] = (int(f["start"], 16), int(f["size"], 16), bank)
                segid[f["id"]] = (name, int(f["ooffs"]))
            elif kind == "sym" and f.get("type") == "lab" and "seg" in f and "val" in f:
                self.byseg.setdefault(f["seg"], []).append((int(f["val"], 16), f["name"].strip('"')))
        # per bank: sorted (cpu_addr, name) list; plus file offset of each bank's start
        self.banks = {}   # bank -> (cpu_start, sorted list)
        self.prg = []     # (prg_offset_start, prg_offset_end, cpu_start, bank, seg)
        for sid, (name, ooffs) in segid.items():
            start, size, bank = self.segs[name]
            if bank is None:
                continue
            labs = sorted(self.byseg.get(sid, []))
            # prefer global names over cheap locals at the same address
            dedup = {}
            for v, n in labs:
                if v not in dedup or dedup[v].startswith("@"):
                    dedup[v] = n
            b = self.banks.setdefault(bank, [])
            b.extend(dedup.items())
            self.prg.append((ooffs - 16, ooffs - 16 + size, start, bank, name))
        for bank in self.banks:
            self.banks[bank].sort()
        self.prg.sort()

    def window_banks(self, addr):
        """banks whose CPU window contains addr"""
        out = []
        for lo, hi, start, bank, name in self.prg:
            if start <= addr < start + (hi - lo):
                out.append(bank)
        return out

    def resolve(self, bank, addr):
        labs = self.banks.get(bank, [])
        i = bisect.bisect_right(labs, (addr, "￿")) - 1
        if i < 0:
            return None
        v, n = labs[i]
        return (n, addr - v)

    def cands(self, addr):
        return {(b,) + self.resolve(b, addr) for b in self.window_banks(addr) if self.resolve(b, addr)}

    def prg_to_label(self, off):
        for lo, hi, start, bank, name in self.prg:
            if lo <= off < hi:
                cpu = start + off - lo
                r = self.resolve(bank, cpu)
                return bank, cpu, r
        return None, None, None


# ---------------------------------------------------------------------------------------- run
def run_scen(build, scen, dump=False, profile=False, shots=None):
    ticks, seed, rnd, inf, taps = SCENARIOS[scen][:5]
    style = SCENARIOS[scen][5] if len(SCENARIOS[scen]) > 5 else None
    rom = os.path.join(BUILDS, build, "rom.nes")
    od = os.path.join(RUNS, build)
    os.makedirs(od, exist_ok=True)
    out = os.path.join(od, scen)
    lua = lambda v: "true" if v else "false"
    cfg = (f'CFG = {{ out = [[{out}]], ticks = {ticks}, seed = {seed}, '
           f'start_round = {rnd if rnd else "nil"}, inf_lives = {lua(inf)}, start_taps = {lua(taps)}, '
           f'style = {chr(34) + style + chr(34) if style else "nil"}, dump = {lua(dump)}, profile = {lua(profile)}, shots = {{{",".join(map(str, shots or []))}}} }}\n')
    script = out + "_harness.lua"
    open(script, "w").write(cfg + open(HARNESS).read())
    r = subprocess.run([os.path.join(MESEN_DIR, "Mesen.exe"), "--testrunner", rom, script],
                       cwd=MESEN_DIR, capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        raise SystemExit(f"{build}/{scen}: Mesen exit code {r.returncode} {r.stdout} {r.stderr}")
    return out


def parallel(jobs):
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=JOBS) as ex:
        return list(ex.map(lambda j: j[0](*j[1:]), jobs))


def cmd_run(a):
    scens = a.scen or DEFAULT_SCENS
    parallel([(run_scen, a.name, s, a.dump, a.profile, a.shots) for s in scens])
    print("ran", " ".join(scens), "->", os.path.join(RUNS, a.name))


# ---------------------------------------------------------------------------------------- compare
RAMNAMES = None


def ramname(addr):
    global RAMNAMES
    if RAMNAMES is None:
        RAMNAMES = []
        cur = None
        for line in open(os.path.join(ROOT, "src", "ram.inc")):
            m = re.match(r"\s*(\w+):\s+\.res\s+\$?(\w+)\s*;=\s*\$(\w+)", line)
            if m:
                RAMNAMES.append((int(m.group(3), 16), m.group(1)))
        RAMNAMES.sort()
    i = bisect.bisect_right(RAMNAMES, (addr, "￿")) - 1
    if i < 0:
        return f"${addr:04X}"
    v, n = RAMNAMES[i]
    return n if v == addr else f"{n}+{addr - v}"


def compare_runs(base, test, scen, verbose=True):
    pa = os.path.join(RUNS, base, scen + ".dump")
    pb = os.path.join(RUNS, test, scen + ".dump")
    sa, sb = Symbols(base), Symbols(test)
    fa, fb = open(pa, "rb"), open(pb, "rb")
    ptr_bytes = {}
    for w in POINTER_WORDS:
        ptr_bytes[w] = w
        ptr_bytes[w + 1] = w
    lag_a = [r[5] > 0 for r in load_csv(base, scen)]
    lag_b = [r[5] > 0 for r in load_csv(test, scen)]
    tick = 0
    warnings = 0
    ptr_cache = {}
    audio_desync = None   # first tick where the lag pattern differed
    while True:
        ra, rb = fa.read(REC_SIZE), fb.read(REC_SIZE)
        if not ra and not rb:
            break
        if len(ra) != len(rb):
            return False, f"tick {tick}: run length differs (base {'ended' if not ra else 'longer'})"
        lag_differs = tick < len(lag_a) and tick < len(lag_b) and lag_a[tick] != lag_b[tick]
        if lag_differs and audio_desync is None:
            audio_desync = tick
        if ra != rb:
            diffs = [i for i in range(REC_SIZE) if ra[i] != rb[i]]
            hard = []
            for i in diffs:
                if i < RAM_SIZE:
                    if i in STACK or i in IRQ_VOLATILE:
                        continue
                    if i == NMI_PROGRESS and lag_differs:
                        continue
                    if audio_desync is not None:
                        if i in AUDIO_PRIVATE:
                            continue
                        if i in AUDIO_TRIGGERS and (ra[i] & 0x7F) == (rb[i] & 0x7F):
                            continue
                    if i in SCRATCH:
                        warnings += 1
                        continue
                    if i in ptr_bytes:
                        w = ptr_bytes[i]
                        va = ra[w] | ra[w + 1] << 8
                        vb = rb[w] | rb[w + 1] << 8
                        key = (va, vb)
                        if key not in ptr_cache:
                            ptr_cache[key] = bool(sa.cands(va) & sb.cands(vb))
                        if ptr_cache[key]:
                            continue
                        hard.append(f"{ramname(w)} ptr ${va:04X}{sorted(sa.cands(va))} vs ${vb:04X}{sorted(sb.cands(vb))}")
                        continue
                    hard.append(f"RAM ${i:04X} {ramname(i)}: {ra[i]:02X} vs {rb[i]:02X}")
                elif i < RAM_SIZE + 0x800:
                    hard.append(f"NT ${0x2000 + i - RAM_SIZE:04X}: {ra[i]:02X} vs {rb[i]:02X}")
                else:
                    hard.append(f"PAL ${i - RAM_SIZE - 0x800:02X}: {ra[i]:02X} vs {rb[i]:02X}")
            if hard:
                msg = f"tick {tick}: {len(hard)} mismatches\n    " + "\n    ".join(hard[:24])
                return False, msg
        tick += 1
    msg = f"{tick} ticks identical"
    if audio_desync is not None:
        msg += f" (lag pattern differs from tick {audio_desync}: audio-engine RAM excluded after it)"
    if warnings:
        msg += f" ({warnings} scratch-byte diffs ignored)"
    return True, msg


def cmd_regress(a):
    ok_all = True
    scens = a.scen or DEFAULT_SCENS
    jobs = [(run_scen, a.test, s, True) for s in scens]
    jobs += [(run_scen, a.base, s, True) for s in scens
             if not a.reuse_base or not os.path.exists(os.path.join(RUNS, a.base, s + ".dump"))]
    parallel(jobs)
    for s in scens:
        ok, msg = compare_runs(a.base, a.test, s)
        ok_all &= ok
        print(f"[{'PASS' if ok else 'FAIL'}] {s}: {msg}")
    print("REGRESSION", "PASS" if ok_all else "FAIL")
    if not ok_all:
        sys.exit(1)


# ---------------------------------------------------------------------------------------- stats
def load_csv(build, scen):
    rows = []
    for line in open(os.path.join(RUNS, build, scen + ".csv")):
        if line.startswith("tick") or line.startswith("TIMEOUT"):
            continue
        rows.append(list(map(int, line.split(","))))
    return rows


PLAY_FROM = 1200   # warped scenarios: the story intro is over by this tick


def summarize(rows):
    lc = sorted(r[3] for r in rows)
    n = len(lc)
    play = sorted(r[3] for r in rows if r[0] >= PLAY_FROM) or [0]
    return dict(n=n, mean=sum(lc) / n, play=sum(play) / len(play), p95=play[int(len(play) * 0.95)],
                max=lc[-1], lag=sum(r[5] for r in rows))


def cmd_stats(a):
    """logic cycles per tick. mean = all ticks; play/p95 = ticks >= PLAY_FROM; lagNMI = lag frames"""
    hdr = f"{'scen':8s} {'ticks':>6s} {'mean':>7s} {'play':>7s} {'p95':>7s} {'max':>7s} {'lagNMI':>6s}"
    if a.vs:
        hdr += f" | {'d_play':>7s} {'d_play%':>7s} {'d_p95':>7s} {'d_lag':>6s}"
    print(hdr)
    tp = tb = 0
    for s in a.scen or DEFAULT_SCENS:
        p = os.path.join(RUNS, a.name, s + ".csv")
        if not os.path.exists(p):
            continue
        m = summarize(load_csv(a.name, s))
        line = f"{s:8s} {m['n']:6d} {m['mean']:7.0f} {m['play']:7.0f} {m['p95']:7d} {m['max']:7d} {m['lag']:6d}"
        if a.vs and os.path.exists(os.path.join(RUNS, a.vs, s + ".csv")):
            b = summarize(load_csv(a.vs, s))
            d = m['play'] - b['play']
            tp += m['play']; tb += b['play']
            line += f" | {d:7.0f} {100 * d / b['play']:6.2f}% {m['p95'] - b['p95']:7d} {m['lag'] - b['lag']:6d}"
        print(line)
    if a.vs and tb:
        print(f"{'TOTAL':8s} play-mean sum delta {tp - tb:.0f} cycles ({100 * (tp - tb) / tb:.2f}%)")


# ---------------------------------------------------------------------------------------- profile
# 6502 base cycles and lengths per opcode (official + the few illegal ones are treated as 2/1)
_CYC = [7,6,2,8,3,3,5,5,3,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
        6,6,2,8,3,3,5,5,4,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
        6,6,2,8,3,3,5,5,3,2,2,2,3,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
        6,6,2,8,3,3,5,5,4,2,2,2,5,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
        2,6,2,6,3,3,3,3,2,2,2,2,4,4,4,4, 2,6,2,6,4,4,4,4,2,5,2,5,5,5,5,5,
        2,6,2,6,3,3,3,3,2,2,2,2,4,4,4,4, 2,5,2,5,4,4,4,4,2,4,2,4,4,4,4,4,
        2,6,2,8,3,3,5,5,2,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7,
        2,6,2,8,3,3,5,5,2,2,2,2,4,4,6,6, 2,5,2,8,4,4,6,6,2,4,2,7,4,4,7,7]
def oplen(op):
    """6502 instruction length from the aaabbbcc opcode layout"""
    bbb, cc = (op >> 2) & 7, op & 3
    if op == 0x20:
        return 3
    if op in (0x00, 0x40, 0x60):
        return 1
    if cc == 0:
        return [2 if op >= 0x80 else 1, 2, 1, 3, 2, 2, 1, 3][bbb]
    if cc == 2:
        return [2, 2, 1, 3, 1, 2, 1, 3][bbb]
    return [2, 2, 2, 3, 2, 2, 3, 3][bbb]


def load_prof(build, scens):
    cnt = {}
    for s in scens:
        p = os.path.join(RUNS, build, s + ".prof")
        if not os.path.exists(p):
            continue
        for line in open(p):
            o, c = line.split()
            cnt[int(o, 16)] = cnt.get(int(o, 16), 0) + int(c)
    return cnt


def instructions(cnt, rom):
    """yield (prg_offset, opcode, count) for executed instructions"""
    prev_end = -1
    for o in sorted(cnt):
        if o < prev_end:
            continue
        op = rom[o]
        yield o, op, cnt[o]
        prev_end = o + oplen(op)


IDLE_LABEL = "CODE_0FE07E"   # main-thread spin loop (JMP *) - idle time, not work


def profile_table(build, scens):
    """estimated exclusive cycles per routine. Routine entries = named labels that are JSR targets
    (taken from executed JSR instructions) plus all non-CODE_/DATA_/@ labels."""
    syms = Symbols(build)
    rom = open(os.path.join(BUILDS, build, "rom.nes"), "rb").read()[16:16 + 0x20000]
    cnt = load_prof(build, scens)
    insts = list(instructions(cnt, rom))
    # bank -> prg offset range
    seg_of = lambda o: next(((lo, hi, start, bank) for lo, hi, start, bank, _ in syms.prg if lo <= o < hi), None)
    entries = {}  # bank -> set of cpu addrs
    for bank, labs in syms.banks.items():
        entries[bank] = {v for v, n in labs if not n.startswith(("CODE_", "DATA_", "@", "ram_"))}
    for o, op, c in insts:
        if op == 0x20:
            tgt = rom[o + 1] | rom[o + 2] << 8
            for lo, hi, start, bank, _ in syms.prg:
                if start <= tgt < start + (hi - lo) and cnt.get(lo + tgt - start, 0) > 0:
                    entries[bank].add(tgt)
    sorted_entries = {b: sorted(v) for b, v in entries.items()}
    names = {b: dict(labs) for b, labs in syms.banks.items()}
    per = {}
    idle = 0
    total = 0
    for o, op, c in insts:
        seg = seg_of(o)
        if not seg:
            continue
        lo, hi, start, bank = seg
        cpu = start + o - lo
        cyc = _CYC[op] * c
        if names[bank].get(cpu) == IDLE_LABEL or (cpu == 0xE07E and bank == 15):
            idle += cyc
            continue
        ents = sorted_entries[bank]
        i = bisect.bisect_right(ents, cpu) - 1
        ent = ents[i] if i >= 0 else start
        name = f"{bank:02X}:{names[bank].get(ent, hex(ent))}"
        per[name] = per.get(name, 0) + cyc
        total += cyc
    return per, total, idle


def cmd_profile(a):
    scens = a.scen or ["r33"]
    per, total, idle = profile_table(a.name, scens)
    base = profile_table(a.vs, scens)[0] if a.vs else None
    print(f"estimated busy cycles over {', '.join(scens)}: {total} (idle spin {idle}, excluded)")
    for n, c in sorted(per.items(), key=lambda x: -x[1])[:a.top]:
        line = f"  {n:40s} {c:12d} {100.0 * c / total:6.2f}%"
        if base is not None:
            line += f"   delta {c - base.get(n, 0):+d}"
        print(line)


def cmd_cover(a):
    """exec counts (summed over all profiled scenarios) for every instruction of the given routines"""
    syms = Symbols(a.name)
    rom = open(os.path.join(BUILDS, a.name, "rom.nes"), "rb").read()[16:16 + 0x20000]
    cnt = {}
    for s in a.scen or DEFAULT_SCENS:
        p = os.path.join(RUNS, a.name, s + ".prof")
        if not os.path.exists(p):
            continue
        for line in open(p):
            o, c = line.split()
            cnt[int(o, 16)] = cnt.get(int(o, 16), 0) + int(c)
    for lab in a.labels:
        found = False
        for lo, hi, start, bank, segname in syms.prg:
            labs = syms.banks[bank]
            for i, (v, n) in enumerate(labs):
                if n != lab or not (start <= v < start + hi - lo):
                    continue
                found = True
                end = labs[i + 1][0] if i + 1 < len(labs) else start + hi - lo
                end = min(end, v + a.max_bytes)
                print(f"{bank:02X}:{lab} ${v:04X}-${end - 1:04X}")
                o = lo + v - start
                while o < lo + end - start:
                    op = rom[o]
                    print(f"   ${start + o - lo:04X} {op:02X} x{cnt.get(o, 0)}")
                    o += oplen(op)
        if not found:
            print("label not found:", lab)


def main():
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("setup"); s.add_argument("--mesen-src", required=True); s.set_defaults(f=cmd_setup)
    s = sp.add_parser("build"); s.add_argument("name"); s.add_argument("--define", action="append"); s.set_defaults(f=cmd_build)
    s = sp.add_parser("run"); s.add_argument("name"); s.add_argument("--scen", nargs="*")
    s.add_argument("--dump", action="store_true"); s.add_argument("--profile", action="store_true")
    s.add_argument("--shots", type=int, nargs="*"); s.set_defaults(f=cmd_run)
    s = sp.add_parser("regress"); s.add_argument("base"); s.add_argument("test"); s.add_argument("--scen", nargs="*")
    s.add_argument("--reuse-base", action="store_true"); s.set_defaults(f=cmd_regress)
    s = sp.add_parser("stats"); s.add_argument("name"); s.add_argument("--scen", nargs="*"); s.add_argument("--vs")
    s.set_defaults(f=cmd_stats)
    s = sp.add_parser("profile"); s.add_argument("name"); s.add_argument("--scen", nargs="*"); s.add_argument("--top", type=int, default=25)
    s.add_argument("--vs"); s.set_defaults(f=cmd_profile)
    s = sp.add_parser("cover"); s.add_argument("name"); s.add_argument("labels", nargs="+")
    s.add_argument("--scen", nargs="*"); s.add_argument("--max-bytes", type=lambda v: int(v, 0), default=0x400); s.set_defaults(f=cmd_cover)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
