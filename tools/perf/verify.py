#!/usr/bin/env python3
"""One-at-a-time verification runner: runs the checker scripts in parallel under one scheduler, with a lock, progress,
a status command, hang detection, a run cache and a clean kill of every child process.

  verify.py full  BUILD [--prev P] [--alt A] [--base BASE] [--p90ref FILE] [--jobs N] [--out DIR] [--no-cache]
                                 the checks of tmp/coop_scripts/p93/verify_all.sh (Phase 9.3), parametrised:
                                 BUILD (BUILDf = COOP_FORCE and BUILDt = COOP_SWAPTEST must exist), P = co-op compare
                                 base (default p92g), A = optional intermediate build (default none; the 9.3 run used
                                 p93a: RAM identity P -> A, ramdiff A -> BUILD, stats vs A), BASE = 1P base (base),
                                 --p90ref = an earlier p90verify output for cmpverify (skipped if not given)
  verify.py quick BUILD [...]    development subset (~5 min): 1P regress (12 scenarios), p90verify on c01 c17 c50 c64
                                 w20n bn2, hudcheck c01,c20,c50, pairchk c01 c50, menutest
  verify.py status               what the running (or last) pipeline is doing, from tmp/verify/progress.json
Results: OUT (default tmp/verify/BUILD_MODE)/final_*.txt (the names of p93's verify_all.sh), run.log (console lines),
summary.txt (PASS / FAIL / INFO per step with its result files).

How it works
  - Lock tmp/verify/verify.lock (pid + process creation time): a second pipeline refuses to start; a lock whose process
    is gone (crash, kill) is reported and replaced. It also refuses to start while any Mesen.exe runs (an orphan or a
    pipeline started some other way); --force skips that check.
  - The runner puts itself into a Windows Job Object with KILL_ON_JOB_CLOSE: every child (step scripts, Mesen) dies
    with it, also if the runner is killed. Ctrl-C / failure: all children are killed (taskkill /T) and the lock freed.
  - Steps are the checker scripts, unchanged, each started as `python verify.py _step SCRIPT ARGS` (cwd as in
    verify_all.sh). That wrapper replaces subprocess.run for Mesen.exe: the request goes to the runner (localhost
    socket), which owns all Mesen processes: at most --jobs (default 4: measured best on the 4-core machine) at once,
    longest expected run first, per-run hang timeout (3x the expected time, at least +300 s, at most the caller's
    timeout; a hang is killed and reported, the caller gets subprocess.TimeoutExpired as before). Thread pools in the
    step scripts are widened (PERF_JOBS, ThreadPoolExecutor) so that the runner sees all their runs.
  - Run cache (tmp/verify/cache): a Mesen run is identified by the hash of Mesen.exe / MesenCore.dll / settings.json,
    the ROM bytes, the Lua script with its [[path]] strings replaced by placeholders, and the other arguments. The
    files the script writes (io.open for writing, recorded by a one-line Lua prologue that leaves line numbers
    unchanged) are stored with the exit code and output; an identical run (another checker, another pipeline) gets
    copies of them instead of being emulated. Only runs with exit code 0 and a complete file list are stored; scripts
    using math.random / os.time / os.clock are never cached. --no-cache turns it off.
  - Progress: tmp/verify/progress.json (rewritten on every event) and console lines: step k/N start / end, run i/M
    inside a step (M from the previous pipeline), and a heartbeat at least every 30 s while runs are alive (running
    runs with elapsed time, done / cached counts, ETA from the previous pipeline's run times in tmp/verify/history.json).
"""
import argparse
import ctypes
import hashlib
import heapq
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import threading
import time
from ctypes import wintypes

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TMP = os.path.join(ROOT, "tmp")
VDIR = os.path.join(TMP, "verify")
LOCK = os.path.join(VDIR, "verify.lock")
PROGRESS = os.path.join(VDIR, "progress.json")
HISTORY = os.path.join(VDIR, "history.json")
CACHE = os.path.join(VDIR, "cache")
COOP = os.path.join(TMP, "coop_scripts")
MESEN_DIR = os.path.join(TMP, "mesen")
PERF = os.path.join(ROOT, "tools", "perf", "perf.py")
HEARTBEAT = 30
POOL = 16                      # thread-pool width inside the step scripts
CACHE_MAX = 6 << 30            # bytes; least recently used entries are dropped above it
NO_CACHE_LUA = re.compile(r"math\.random|os\.time|os\.clock")

# ------------------------------------------------------------------------------------------------ Windows helpers
K32 = ctypes.WinDLL("kernel32", use_last_error=True)
K32.OpenProcess.restype = wintypes.HANDLE
K32.CreateJobObjectW.restype = wintypes.HANDLE
K32.GetCurrentProcess.restype = wintypes.HANDLE
K32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
K32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
K32.CloseHandle.argtypes = [wintypes.HANDLE]
K32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
STILL_ACTIVE = 259


def proc_created(pid):
    """creation time (FILETIME as int) of a live process, else None"""
    h = K32.OpenProcess(0x1000, False, pid)          # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return None
    try:
        code = wintypes.DWORD()
        if not K32.GetExitCodeProcess(h, ctypes.byref(code)) or code.value != STILL_ACTIVE:
            return None
        c, e, k, u = (wintypes.FILETIME() for _ in range(4))
        K32.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(k), ctypes.byref(u))
        return (c.dwHighDateTime << 32) | c.dwLowDateTime
    finally:
        K32.CloseHandle(h)


def proc_alive(pid, created=None):
    c = proc_created(pid)
    return c is not None and (created is None or c == created)


def proc_cpu(handle):
    c, e, k, u = (wintypes.FILETIME() for _ in range(4))
    K32.GetProcessTimes(wintypes.HANDLE(handle), ctypes.byref(c), ctypes.byref(e), ctypes.byref(k), ctypes.byref(u))
    f = lambda t: ((t.dwHighDateTime << 32) | t.dwLowDateTime) / 1e7
    return f(u) + f(k)


class _IOC(ctypes.Structure):
    _fields_ = [(n, ctypes.c_ulonglong) for n in ("r", "w", "o", "rb", "wb", "ob")]


class _BLI(ctypes.Structure):
    _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong), ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]


class _ELI(ctypes.Structure):
    _fields_ = [("Basic", _BLI), ("Io", _IOC), ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t)]


def join_kill_job():
    """put this process into a job that kills all its members when the last handle (ours) closes"""
    job = K32.CreateJobObjectW(None, None)
    if not job:
        return None
    info = _ELI()
    info.Basic.LimitFlags = 0x2000                  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not K32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)):
        return None
    if not K32.AssignProcessToJobObject(job, K32.GetCurrentProcess()):
        return None
    return job


def kill_tree(pid):
    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)


def mesen_pids():
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Mesen.exe", "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout
    return [int(line.split('","')[1]) for line in out.splitlines() if line.startswith('"Mesen.exe"')]


def hms(sec):
    sec = int(sec)
    return f"{sec // 3600}:{sec // 60 % 60:02d}:{sec % 60:02d}" if sec >= 3600 else f"{sec // 60}:{sec % 60:02d}"


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1)
    for _ in range(20):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:            # a reader (status) has it open
            time.sleep(0.05)


def sha(data):
    return hashlib.sha256(data).hexdigest()


# ------------------------------------------------------------------------------------------------ step wrapper
def step_main(argv):
    """`verify.py _step SCRIPT ARGS`: run SCRIPT as __main__ with Mesen runs delegated to the runner"""
    import concurrent.futures
    import runpy
    port, token, step = int(os.environ["VERIFY_PORT"]), os.environ["VERIFY_TOKEN"], os.environ["VERIFY_STEP"]
    real_run = subprocess.run

    def run(cmd, *a, **kw):
        if not (isinstance(cmd, (list, tuple)) and cmd and str(cmd[0]).lower().endswith("mesen.exe")):
            return real_run(cmd, *a, **kw)
        req = dict(token=token, step=step, cmd=[str(c) for c in cmd], cwd=kw.get("cwd"), timeout=kw.get("timeout"))
        with socket.create_connection(("127.0.0.1", port)) as s:
            s.sendall(json.dumps(req).encode() + b"\n")
            buf = b""
            while not buf.endswith(b"\n"):
                d = s.recv(1 << 16)
                if not d:
                    raise SystemExit("verify runner went away")
                buf += d
        r = json.loads(buf)
        text = kw.get("text") or kw.get("universal_newlines")
        out, err = (r["stdout"], r["stderr"]) if text else (r["stdout"].encode(), r["stderr"].encode())
        if r.get("killed"):
            raise subprocess.TimeoutExpired(cmd, kw.get("timeout") or 0, output=out, stderr=err)
        cap = kw.get("capture_output") or kw.get("stdout") == subprocess.PIPE
        return subprocess.CompletedProcess(cmd, r["rc"], out if cap else None, err if cap else None)

    subprocess.run = run
    real_init = concurrent.futures.ThreadPoolExecutor.__init__

    def init(self, max_workers=None, *a, **kw):
        real_init(self, max(max_workers or 1, POOL), *a, **kw)
    concurrent.futures.ThreadPoolExecutor.__init__ = init
    script = os.path.abspath(argv[0])
    sys.argv = [argv[0]] + argv[1:]
    sys.path.insert(0, os.path.dirname(script))
    runpy.run_path(script, run_name="__main__")


# ------------------------------------------------------------------------------------------------ run cache
PROLOGUE = ('do local o, s, w = io.open, emu.stop, {}; io.open = function(p, m, ...) if type(p) == "string" and m and '
            'm:find("[wa+]") then w[p] = true end return o(p, m, ...) end; emu.stop = function(...) local f = o(%s, '
            '"w"); for p in pairs(w) do f:write(p, "\\n") end f:close() return s(...) end end ')


class Cache:
    def __init__(self, enabled):
        self.enabled = enabled
        self.lock = threading.Lock()
        self.base = ""
        if enabled:
            h = hashlib.sha256()
            for n in ("Mesen.exe", "MesenCore.dll", "settings.json"):
                h.update(open(os.path.join(MESEN_DIR, n), "rb").read())
            self.base = h.hexdigest()

    @staticmethod
    def paths(lua):
        out = []
        for m in re.finditer(r"\[\[(.*?)\]\]", lua):
            p = m.group(1)
            if (":" in p or "\\" in p or "/" in p) and p not in out:
                out.append(p)
        return out

    def key(self, cmd, lua):
        """cache key of a Mesen run, or None if it must not be cached"""
        if not self.enabled or len(cmd) < 4 or cmd[1] != "--testrunner" or NO_CACHE_LUA.search(lua):
            return None
        norm = lua
        for i, p in enumerate(self.paths(lua)):
            norm = norm.replace("[[" + p + "]]", f"[[@P{i}@]]")
        h = hashlib.sha256(self.base.encode())
        h.update(open(cmd[2], "rb").read())
        h.update(norm.encode())
        h.update(json.dumps(cmd[4:]).encode())
        return h.hexdigest()

    def dir(self, key):
        return os.path.join(CACHE, key[:2], key)

    def get(self, key, lua):
        """copy the cached outputs to this run's paths; returns the stored result or None"""
        d = self.dir(key)
        try:
            meta = json.load(open(os.path.join(d, "meta.json")))
        except (OSError, ValueError):
            return None
        ph = self.paths(lua)
        for i, (where, rel) in enumerate(meta["files"]):
            dst = rel if where == "abs" else ph[where] + rel
            os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
            shutil.copyfile(os.path.join(d, "%04d" % i), dst)
        os.utime(os.path.join(d, "meta.json"))
        return meta["result"]

    def put(self, key, lua, manifest, result):
        try:
            written = [line.rstrip("\n") for line in open(manifest)]
        except OSError:
            return
        ph = sorted(enumerate(self.paths(lua)), key=lambda x: -len(x[1]))
        files = []
        for p in written:
            if not os.path.exists(p):
                continue
            np_ = os.path.normcase(os.path.abspath(p))
            for i, pre in ph:
                npre = os.path.normcase(os.path.abspath(pre))
                if np_.startswith(npre):
                    files.append((i, p[len(pre):] if p.startswith(pre) else np_[len(npre):], p))
                    break
            else:
                files.append(("abs", p, p))
        d = self.dir(key)
        tmp = d + ".tmp%d" % threading.get_ident()
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp)
        for i, (where, rel, src) in enumerate(files):
            shutil.copyfile(src, os.path.join(tmp, "%04d" % i))
        with open(os.path.join(tmp, "meta.json"), "w") as f:
            json.dump(dict(files=[(w, r) for w, r, _ in files], result=result, time=time.time()), f)
        with self.lock:
            shutil.rmtree(d, ignore_errors=True)
            os.replace(tmp, d)

    @staticmethod
    def prune():
        ents = []
        for top in (os.listdir(CACHE) if os.path.isdir(CACHE) else []):
            for k in os.listdir(os.path.join(CACHE, top)):
                d = os.path.join(CACHE, top, k)
                try:
                    size = sum(os.path.getsize(os.path.join(d, f)) for f in os.listdir(d))
                    ents.append((os.path.getmtime(os.path.join(d, "meta.json")), size, d))
                except OSError:
                    shutil.rmtree(d, ignore_errors=True)
        total = sum(e[1] for e in ents)
        for t, size, d in sorted(ents):
            if total <= CACHE_MAX:
                break
            shutil.rmtree(d, ignore_errors=True)
            total -= size


# ------------------------------------------------------------------------------------------------ runner
class Runner:
    def __init__(self, a, jobs, names):
        self.a = a
        self.slots = a.jobs
        self.free = a.jobs
        self.cv = threading.Condition()
        self.pending = []
        self.seq = 0
        self.cache = Cache(not a.no_cache)
        self.inflight = {}
        self.names = names                      # build name -> placeholder (history keys are build-independent)
        self.jobs = jobs
        self.out = a.out
        self.t0 = time.time()
        self.lock = threading.RLock()
        self.running = {}                       # id -> dict(label, step, pid, start, est, limit)
        self.done_runs = []                     # (hkey, wall, cpu, cached)
        self.step_runs = {}                     # step -> [done, cached]
        self.hist = {}
        try:
            self.hist = json.load(open(HISTORY))
        except (OSError, ValueError):
            pass
        self.prev_runs = self.hist.get("runs", {})
        self.prev_steps = self.hist.get("modes", {}).get(a.mode, {}).get("steps", {})
        self.prev_set = self.hist.get("modes", {}).get(a.mode, {}).get("run_keys", [])
        self.log_f = open(os.path.join(self.out, "run.log"), "a")
        self.token = sha(os.urandom(16))
        self.stop = False
        self.events = []

    # ---- console / progress
    def log(self, msg):
        line = time.strftime("%H:%M:%S ") + f"[{hms(time.time() - self.t0)}] " + msg
        with self.lock:
            print(line, flush=True)
            self.log_f.write(line + "\n")
            self.log_f.flush()

    def hkey(self, step, script):
        b = os.path.basename(os.path.dirname(script)) + "/" + os.path.basename(script)
        for n, ph in sorted(self.names.items(), key=lambda x: -len(x[0])):
            b = b.replace(n, ph)
        return f"{step}:{b}"

    def eta(self):
        """seconds left: expected time of the previous pipeline's runs not done yet, over the slots"""
        if not self.prev_set:
            return None
        done = {k for k, *_ in self.done_runs}
        ended = {j.name for j in self.jobs if j.state in ("done", "fail")}
        now = time.time()
        left = 0.0
        for k in self.prev_set:
            if k in done or k.split(":")[0] in ended:      # done, or its step ended (did not need it this time)
                continue
            est = self.prev_runs.get(k, 20)
            r = next((r for r in self.running.values() if r["hkey"] == k), None)
            left += max(est - (now - r["start"]), 5) if r else est
        return left / self.slots

    def save_progress(self, final=None):
        now = time.time()
        with self.lock:
            st = dict(pid=os.getpid(), created=proc_created(os.getpid()), mode=self.a.mode, build=self.a.build,
                      out=self.out, start=self.t0, now=now, jobs=self.slots, finished=final,
                      runs_done=len(self.done_runs), runs_cached=sum(1 for r in self.done_runs if r[3]),
                      eta=self.eta(),
                      running=[dict(label=r["label"], step=r["step"], pid=r["pid"], elapsed=now - r["start"],
                                    est=r["est"], limit=r["limit"]) for r in self.running.values()],
                      steps=[dict(name=j.name, title=j.title, state=j.state, start=j.t_start, end=j.t_end, rc=j.rc,
                                  runs=self.step_runs.get(j.name, [0, 0]),
                                  runs_prev=self.prev_steps.get(j.name, {}).get("runs")) for j in self.jobs])
        write_json(PROGRESS, st)

    def heartbeat(self):
        last = 0
        while not self.stop:
            time.sleep(1)
            if time.time() - last < HEARTBEAT:
                continue
            last = time.time()
            self.save_progress()
            with self.lock:
                run = sorted(self.running.values(), key=lambda r: r["start"])
                act = [j for j in self.jobs if j.state == "run"]
            ndone = sum(1 for j in self.jobs if j.state in ("done", "fail"))
            e = self.eta()
            parts = [f"steps {ndone}/{len(self.jobs)} done",
                     f"runs {len(self.done_runs)} done ({sum(1 for r in self.done_runs if r[3])} cached)"]
            if e is not None:
                parts.append(f"ETA {time.strftime('%H:%M', time.localtime(time.time() + e))} (~{hms(e)} left)")
            self.log("HEARTBEAT " + ", ".join(parts))
            if act:
                self.log("  steps running: " + ", ".join(f"{j.name} {self.step_progress(j.name)}" for j in act))
            for r in run:
                self.log(f"  run {r['label']} ({r['step']}) {time.time() - r['start']:.0f} s"
                         f" (expected {r['est']:.0f} s, hang limit {r['limit']:.0f} s)")

    def step_progress(self, name):
        d, c = self.step_runs.get(name, [0, 0])
        m = self.prev_steps.get(name, {}).get("runs")
        return f"run {d}/{m if m is not None else '?'}"

    # ---- slots (longest expected run first)
    def acquire(self, est):
        with self.cv:
            self.seq += 1
            me = (-est, self.seq)
            heapq.heappush(self.pending, me)
            while not (self.free > 0 and self.pending[0] == me):
                self.cv.wait()
            heapq.heappop(self.pending)
            self.free -= 1
            self.cv.notify_all()

    def release(self):
        with self.cv:
            self.free += 1
            self.cv.notify_all()

    # ---- one Mesen run (called from a socket thread)
    def mesen(self, req, conn):
        cmd, step = req["cmd"], req["step"]
        script = cmd[3] if len(cmd) > 3 else ""
        label = os.path.basename(script)
        hk = self.hkey(step, script)
        lua = open(script, encoding="latin-1").read() if os.path.exists(script) else ""
        key = self.cache.key(cmd, lua) if lua else None
        if not key:
            return self._run(req, conn, cmd, step, script, label, hk, lua, key)
        while True:                 # one run per key at a time; an identical request waits, then hits the cache
            with self.lock:
                ev = self.inflight.get(key)
                if ev is None:
                    self.inflight[key] = threading.Event()
                    break
            ev.wait()
        try:
            r = self.cache.get(key, lua)
            if r is not None:
                self.finish_run(step, hk, label, 0, 0, True)
                return r
            return self._run(req, conn, cmd, step, script, label, hk, lua, key)
        finally:
            with self.lock:
                self.inflight.pop(key).set()

    def _run(self, req, conn, cmd, step, script, label, hk, lua, key):
        m = re.search(r"ticks = (\d+)", lua)
        est = self.prev_runs.get(hk) or (int(m.group(1)) if m else 3000) * (0.022 if "p90verify" in step
                                                                            or step in ("hud_r2", "hud_p8") else 0.008)
        limit = max(3 * est, est + 300)
        if req.get("timeout"):
            limit = min(limit, req["timeout"])
        if key:   # manifest prologue on line 1 (line numbers unchanged)
            manifest = script + ".written"
            if os.path.exists(manifest):
                os.remove(manifest)
            with open(script, "w", encoding="latin-1") as f:
                f.write(PROLOGUE % ("[[" + manifest + "]]") + lua)
        if len(cmd) > 3 and not any(c.startswith("--timeout") for c in cmd[4:]):
            # Mesen's own script timeout (~100 s wall) would cut a long run short when 4 share the CPUs (swapcheck
            # passes none); the runner's hang limit takes its place
            cmd = cmd + [f"--timeout={int(limit) + 60}"]
        self.acquire(est)
        rid = object()
        t0 = time.time()
        try:
            p = subprocess.Popen(cmd, cwd=req.get("cwd"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, errors="replace")
            with self.lock:
                self.running[rid] = dict(label=label, step=step, pid=p.pid, start=t0, est=est, limit=limit, hkey=hk)
            res = {}
            th = threading.Thread(target=lambda: res.update(zip(("stdout", "stderr"), p.communicate())), daemon=True)
            th.start()
            killed = None
            while th.is_alive():
                th.join(1)
                if not th.is_alive():
                    break
                if self.stop:
                    killed = "pipeline stopped"
                elif time.time() - t0 > limit:
                    killed = f"HANG: no end after {time.time() - t0:.0f} s (expected {est:.0f} s)"
                elif conn is not None and select.select([conn], [], [], 0)[0] and not conn.recv(1, socket.MSG_PEEK):
                    killed = "caller gone"
                if killed:
                    kill_tree(p.pid)
                    th.join(10)
                    break
            wall = time.time() - t0
            cpu = proc_cpu(int(p._handle))
        finally:
            with self.lock:
                self.running.pop(rid, None)
            self.release()
        if killed:
            self.log(f"!! {label} ({step}) killed: {killed}")
            return dict(rc=-1, stdout=res.get("stdout", ""), stderr=res.get("stderr", "") + "\n" + killed, killed=True)
        result = dict(rc=p.returncode, stdout=res.get("stdout", ""), stderr=res.get("stderr", ""))
        if key:
            with open(script, "w", encoding="latin-1") as f:     # leave the script as the checker wrote it
                f.write(lua)
            if p.returncode == 0 and os.path.exists(script + ".written"):
                try:
                    self.cache.put(key, lua, script + ".written", result)
                except OSError as e:
                    self.log(f"   (cache store failed for {label}: {e})")
        self.finish_run(step, hk, label, wall, cpu, False, p.returncode)
        return result

    def finish_run(self, step, hk, label, wall, cpu, cached, rc=0):
        with self.lock:
            self.done_runs.append((hk, wall, cpu, cached))
            sr = self.step_runs.setdefault(step, [0, 0])
            sr[0] += 1
            sr[1] += cached
            n = sr[0]
        m = self.prev_steps.get(step, {}).get("runs")
        what = "cached" if cached else f"{wall:.0f} s, cpu {cpu:.0f} s" + (f", rc {rc}" if rc else "")
        self.log(f"   {step} run {n}/{m if m is not None else '?'} {label}: {what}")

    # ---- socket server
    def serve(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(64)
        self.port = srv.getsockname()[1]

        def client(conn):
            try:
                buf = b""
                while not buf.endswith(b"\n"):
                    d = conn.recv(1 << 16)
                    if not d:
                        return
                    buf += d
                req = json.loads(buf)
                if req.get("token") != self.token:
                    return
                r = self.mesen(req, conn)
                conn.sendall(json.dumps(r).encode() + b"\n")
            except Exception as e:                  # noqa: the caller sees a closed socket
                self.log(f"!! runner error for a Mesen request: {e!r}")
            finally:
                conn.close()

        def loop():
            while True:
                c, _ = srv.accept()
                threading.Thread(target=client, args=(c,), daemon=True).start()
        threading.Thread(target=loop, daemon=True).start()

    # ---- steps
    def start_job(self, j):
        env = dict(os.environ, VERIFY_PORT=str(self.port), VERIFY_TOKEN=self.token, VERIFY_STEP=j.name,
                   PERF_JOBS=str(POOL), VERIFY_T0=str(self.t0))
        j.raw = os.path.join(self.out, "steps", j.name + ".out")
        os.makedirs(os.path.dirname(j.raw), exist_ok=True)
        j.t_start = time.time()
        j.state = "run"
        if j.func:
            th = threading.Thread(target=self.run_func, args=(j,), daemon=True)
            th.start()
            j.proc = None
            return
        argv = [sys.executable, os.path.abspath(__file__), "_step"] + j.argv
        j.fh = open(j.raw, "wb")
        j.proc = subprocess.Popen(argv, cwd=j.cwd, stdout=j.fh, stderr=subprocess.STDOUT, env=env)

    def run_func(self, j):
        try:
            txt = j.func()
            open(j.raw, "wb").write(txt.encode("latin-1"))
            j.rc = 0
        except Exception as e:                       # noqa
            open(j.raw, "wb").write(f"ERROR {e!r}\n".encode())
            j.rc = 1
        j.func_done = True

    def poll_job(self, j):
        if j.func:
            return getattr(j, "func_done", False)
        rc = j.proc.poll()
        if rc is None:
            return False
        j.fh.close()
        j.rc = rc
        return True

    def run_all(self, max_procs):
        self.serve()
        threading.Thread(target=self.heartbeat, daemon=True).start()
        n = len(self.jobs)
        self.log(f"pipeline {self.a.mode} {self.a.build}: {n} steps, {self.slots} Mesen slots, out {self.out}"
                 + ("" if self.cache.enabled else ", cache off"))
        e = self.eta()
        if e is not None:
            self.log(f"expected duration from the previous {self.a.mode} pipeline: ~{hms(e)}")
        self.save_progress()
        k = 0
        while True:
            for j in self.jobs:
                if j.state == "run" and self.poll_job(j):
                    j.t_end = time.time()
                    j.state = "done" if j.rc == 0 or j.rc_ok(j.rc) else "fail"
                    open(os.path.join(self.out, "steps", j.name + ".done"), "w").write(f"{j.rc}\n")
                    self.log(f"step {j.index}/{n} {j.name} END rc {j.rc} after {hms(j.t_end - j.t_start)}"
                             + ("" if j.state == "done" else "  <-- FAILED (exit code)"))
                    self.save_progress()
            states = {j.name: j.state for j in self.jobs}
            nrun = sum(1 for j in self.jobs if j.state == "run" and not j.func)
            for j in self.jobs:
                if j.state == "wait" and all(states[d] in ("done", "fail") for d in j.deps) and \
                        (j.func or nrun < max_procs):
                    k += 1
                    self.log(f"step {j.index}/{n} {j.name} START: {j.title}")
                    self.start_job(j)
                    states[j.name] = "run"
                    nrun += 0 if j.func else 1
            if all(j.state in ("done", "fail") for j in self.jobs):
                break
            time.sleep(0.5)

    def abort(self, why):
        self.stop = True
        self.log(f"ABORT: {why}; killing all children")
        for j in self.jobs:
            if getattr(j, "proc", None) and j.proc.poll() is None:
                kill_tree(j.proc.pid)
        with self.lock:
            pids = [r["pid"] for r in self.running.values()]
        for pid in pids:
            kill_tree(pid)


class Job:
    def __init__(self, name, title, argv=None, cwd=ROOT, deps=(), out=None, filt=None, func=None, rc_ok=None,
                 verdict=None):
        self.name, self.title, self.argv, self.cwd, self.deps = name, title, argv, cwd, list(deps)
        self.out = out                  # (final file name, order) - jobs with the same file are concatenated by order
        self.filt = filt
        self.func = func
        self.rc_ok = rc_ok or (lambda rc: False)
        self.verdict = verdict
        self.state = "wait"
        self.raw = None
        self.header = ""
        self.t_start = self.t_end = None
        self.rc = None
        self.index = 0


# ------------------------------------------------------------------------------------------------ pipeline
FULL_P90 = "c01 c05 c17 c20 c22 c50 c64 d13 d04 d25 o1 o2 o3 o4 o6 b2 b70 b70o b70p b40 o6b o7b w20n w20r w20k w20x " \
           "w20y w20b bn1 bn2 bn3 bn4".split()
COOP_C = "c01 c05 c17 c20 c22 c50 c64".split()
HUD_R2 = "d13 d04 d25 o1 o2 o3 o4 o6 b2 b70 b70o b70p b40 o6b".split()     # hudcheck.py SET_R2 / SET_P8
HUD_P8 = "w20n w20k w20x w20y w20b bn1 bn2 bn3 bn4".split()


def v_last(pattern, ok):
    """verdict: the last line matching pattern; PASS if it matches ok"""
    def f(txt):
        lines = [x for x in txt.splitlines() if re.search(pattern, x)]
        if not lines:
            return "FAIL", "no result line"
        return ("PASS" if re.search(ok, lines[-1]) else "FAIL"), lines[-1].strip()
    return f


def v_all(pattern, ok):
    def f(txt):
        lines = [x for x in txt.splitlines() if re.search(pattern, x)]
        bad = [x for x in lines if not re.search(ok, x)]
        if not lines:
            return "FAIL", "no result line"
        return ("FAIL" if bad else "PASS"), (bad[0].strip() if bad else f"{len(lines)} x " + lines[-1].strip())
    return f


def v_info(pattern=None):
    def f(txt):
        lines = [x for x in txt.splitlines() if pattern and re.search(pattern, x)]
        return "INFO", (lines[-1].strip() if lines else "")
    return f


def v_p90(txt):
    rcs = re.findall(r"^===== \S+ rc=(\S+)", txt, re.M)
    v = re.findall(r"===== VIOLATIONS (.*)", txt)
    v8 = re.findall(r"===== PHASE 8 VIOLATIONS (\d+)", txt)
    ok = rcs and all(r == "0" for r in rcs) and v and all(n == "0" for n in re.findall(r"(?<![a-z\d])\d+", v[-1])) and v8[-1:] == ["0"]
    return ("PASS" if ok else "FAIL"), f"{len(rcs)} runs, rc!=0: {sum(r != '0' for r in rcs)}, violations {v[-1] if v else '?'}," \
                                       f" phase 8 {v8[-1] if v8 else '?'}"


def md5_func(builds):
    def f():
        out = []
        for b in builds:
            p = os.path.join(TMP, "builds", b, "rom.nes")
            out.append(f"{hashlib.md5(open(p, 'rb').read()).hexdigest()} *tmp/builds/{b}/rom.nes\n")
        return "".join(out)
    return f


def pipeline(a):
    B, P, A, BASE = a.build, a.prev, a.alt, a.base
    py = lambda script, *args: [script] + list(args)
    perf = lambda *args: py(PERF, *args)
    p93 = os.path.join(COOP, "p93")
    chk = lambda n: os.path.join(a.checkers, n)
    J = []
    if a.mode == "quick":
        J.append(Job("regress1p", f"1P regress {BASE} -> {B} (12 scenarios)", perf("regress", BASE, B, "--reuse-base"),
                     out=("final_regress.txt", 0), verdict=v_last(r"^REGRESSION", "PASS")))
        J.append(Job("p90verify", f"p90verify {B} (6 co-op runs)",
                     py("p90/p90verify.py", B, "--tag", "vfyq", "c01", "c17", "c50", "c64", "w20n", "bn2"), cwd=COOP,
                     out=("final_p90verify.txt", 0), verdict=v_p90))
        J.append(Job("hud_coop", "hudcheck c01,c20,c50", py("p90/hudcheck.py", B, "--scen", "c01,c20,c50", "--tag", a.hudtag),
                     cwd=COOP, out=("final_hudcheck.txt", 0), filt=r"^ {8}lag", verdict=v_last(r"^HUDCHECK", "PASS")))
        J.append(Job("pairchk", "pairchk c01 c50", py(chk("pairchk.py"), B, "c01", "c50"), cwd=a.checkers,
                     out=("final_pairchk.txt", 0), verdict=v_info(r"^TOTAL")))
        J.append(Job("menutest", "menutest", py("r2/menutest.py", B, B + "f"), cwd=COOP, out=("final_menutest.txt", 0),
                     verdict=v_last(r"^MENU TESTS", r"MENU TESTS PASS")))
        return J
    builds = [B, B + "f", B + "t"] + ([A] if A else [])
    J.append(Job("md5", "ROM md5", func=md5_func(builds), out=("final_md5.txt", 0), verdict=v_info()))
    # long runs first (the runner starts steps in this order when slots allow; LPT works on their runs)
    # p90verify takes the runs of hudcheck's r2 / p8 sets (hudcheck's Lua there = p90verify's Lua + the HUD add-on;
    # same build and scenario): --reuse waits for each of them and checks ROM md5, exit code 0 and the Lua; its own
    # runs (the other scenarios) go on meanwhile; if a hudcheck run is missing when both sets are done, it runs it
    reuse = [s for s in FULL_P90 if s in HUD_R2 + HUD_P8]
    done = ",".join(os.path.join(a.out, "steps", f"hud_{s}.done") for s in ("r2", "p8"))
    J.append(Job("p90verify", f"p90verify {B} ({len(FULL_P90)} scenarios, {len(reuse)} from hudcheck's runs)",
                 py("p90/p90verify.py", B, "--tag", a.p90tag, "--reuse", a.hudtag, "--reuse-scen", ",".join(reuse),
                    "--reuse-done", done, *FULL_P90), cwd=COOP, out=("final_p90verify.txt", 0), verdict=v_p90))
    if a.p90ref:
        J.append(Job("cmpverify", f"cmpverify {a.p90ref} vs this run",
                     py(chk("cmpverify.py"), a.p90ref, os.path.join(a.out, "steps", "p90verify.out")), deps=["p90verify"],
                     out=("final_p90verify_cmp.txt", 0), verdict=v_info(r"differences")))
    for s in ("r2", "p8", "coop", "1p"):           # started heaviest first; the file keeps verify_all.sh's order
        J.append(Job("hud_" + s, f"hudcheck set {s}", py("p90/hudcheck.py", B, "--scen", s, "--tag", a.hudtag), cwd=COOP,
                     out=("final_hudcheck.txt", ("coop", "p8", "r2", "1p").index(s)), filt=r"^ {8}lag",
                     verdict=v_last(r"^HUDCHECK", "PASS")))
        J[-1].header = f"== set {s}\n"
    trac = [(B, "coop", "both", "c50 t50a t50b"), (B, "coop", "p2only", "c50 t50a t50b"),
            (B, "coop", "p1only", "c50 t50a t50b"), (B, "coop", "p2high", "c50 t50a"), (B, "coop", "p1high", "c50 t50a"),
            (B, "p1", "both", "r50"), (P, "p1", "both", "c50 t50a t50b"), (P, "p1", "p2only", "c50 t50a")]
    for i, (b, rule, mode, sc) in enumerate(trac):
        J.append(Job(f"tractor{i + 1}", f"tractor {b} {rule} {mode} {sc}", py(chk("tractor.py"), b, rule, mode, *sc.split()),
                     cwd=a.checkers, out=("final_tractor.txt", i), verdict=v_last(r"^RESULT", "PASS")))
    J.append(Job("regress1p", f"1P regress {BASE} -> {B} (12 scenarios)", perf("regress", BASE, B, "--reuse-base"),
                 out=("final_regress.txt", 0), verdict=v_last(r"^REGRESSION", "PASS")))
    J.append(Job("stats1p", f"stats 1P vs {P}", perf("stats", B, "--vs", P), deps=["regress1p"],
                 out=("final_stats_1p.txt", 0), verdict=v_info(r"TOTAL")))
    if A:
        J.append(Job("ramid", f"co-op RAM identity {P} -> {A}", perf("regress", P, A, "--reuse-base", "--scen", *COOP_C),
                     out=("final_ramidentity_a.txt", 0), verdict=v_last(r"^REGRESSION", "PASS"), rc_ok=lambda rc: rc == 1))
    J.append(Job("runcoop", f"run {B} co-op (dump, profile)", perf("run", B, "--dump", "--profile", "--scen", *COOP_C),
                 out=("run_coop.log", 0), verdict=v_last(r"^ran ", "")))
    if A:
        J.append(Job("ramdiff", f"ramdiff {A} -> {B}", py(chk("ramdiff.py"), A, B, *COOP_C), deps=["ramid", "runcoop"],
                     out=("final_ramdiff_b.txt", 0), verdict=v_last(r"^RAMDIFF", "ONLY OAM ORDER")))
    J.append(Job("statscoop1", f"stats co-op {B} vs {P}", perf("stats", B, "--vs", P, "--scen", *COOP_C), deps=["runcoop"],
                 out=("final_stats_coop.txt", 0), verdict=v_info(r"TOTAL")))
    if A:
        J.append(Job("statscoop2", f"stats co-op {B} vs {A}", perf("stats", B, "--vs", A, "--scen", *COOP_C),
                     deps=["runcoop", "ramid"], out=(f"final_stats_coop_vs_{A}.txt", 0), verdict=v_info(r"TOTAL")))
        J.append(Job("statscoop3", f"stats co-op {A} vs {P}", perf("stats", A, "--vs", P, "--scen", *COOP_C), deps=["ramid"],
                     out=(f"final_stats_coop_a_vs_{P}.txt", 0), verdict=v_info(r"TOTAL")))
    J.append(Job("profile", f"profile {B} co-op", perf("profile", B, "--scen", *COOP_C, "--top", "400"), deps=["runcoop"],
                 out=("final_profile_coop.txt", 0), verdict=v_info(r"estimated busy")))
    J.append(Job("windowchk", "windowchk", py(chk("windowchk.py"), B, *COOP_C, "c40", "c70", "cnat", "cgo"), cwd=a.checkers,
                 out=("final_windowchk.txt", 0), verdict=v_info()))
    J.append(Job("pairchk", "pairchk set", py(chk("pairchk.py"), B, "set"), cwd=a.checkers, out=("final_pairchk.txt", 0),
                 verdict=v_info(r"^TOTAL")))
    J.append(Job("pairchk_c", "pairchk --charge fsset", py(chk("pairchk.py"), B, "--charge", "fsset"), cwd=a.checkers,
                 out=("final_pairchk.txt", 1), verdict=v_info(r"^TOTAL")))
    J.append(Job("flick_prev", f"flick {P}", py(chk("flick.py"), P, "--tag", "fl_" + P, "set"), cwd=a.checkers,
                 out=(f"final_flick_{P}.txt", 0), verdict=v_info()))
    J.append(Job("flick", f"flick {B}", py(chk("flick.py"), B, "--tag", "fl_" + B, "set"), cwd=a.checkers,
                 out=(f"final_flick_{B}.txt", 0), verdict=v_info()))
    J.append(Job("swapcheck", f"swapcheck {B}t r01 --inject", py(chk("swapcheck.py"), B + "t", "r01", "--inject"),
                 out=("final_swapcheck.txt", 0), verdict=v_all(r"swaps_checked", r"failures=0 ")))
    J.append(Job("swapcheck2", f"swapcheck {B}t natural", py(chk("swapcheck.py"), B + "t", "natural"),
                 out=("final_swapcheck.txt", 1), verdict=v_all(r"swaps_checked", r"failures=0 ")))
    J.append(Job("menutest", "menutest", py("r2/menutest.py", B, B + "f"), cwd=COOP, out=("final_menutest.txt", 0),
                 verdict=v_last(r"^MENU TESTS", r"MENU TESTS PASS")))
    J.append(Job("pixcmp", f"pixcmp {BASE} vs {B}", py("p7b2/pixcmp.py", B, "--scen", "natural,r20"), cwd=COOP,
                 out=("final_pixcmp_base.txt", 0), verdict=v_info(r"^PIXCMP")))
    J.append(Job("pixcmp_prev", f"pixcmp {P} vs {B}", py("p7b2/pixcmp.py", B, "--scen", "natural,r20", "--base", P),
                 cwd=COOP, deps=["pixcmp"], out=(f"final_pixcmp_{P}.txt", 0), verdict=v_info(r"^PIXCMP")))
    return J


def assemble(r, jobs):
    """final files from the step outputs (in order), summary.txt"""
    files = {}
    for j in jobs:          # the bytes the scripts wrote (latin-1 round trip); lines filtered like grep -v
        if not j.out:
            continue
        raw = open(j.raw, "rb").read().decode("latin-1") if j.raw and os.path.exists(j.raw) else ""
        if j.filt:
            # like verify_all.sh's `| grep -v`: Git Bash's grep also wrote LF line ends
            raw = "".join(x.rstrip("\r\n") + "\n" for x in raw.splitlines(True) if not re.search(j.filt, x))
        files.setdefault(j.out[0], []).append((j.out[1], j.header + raw))
    for name, parts in files.items():
        with open(os.path.join(r.out, name), "wb") as f:
            f.write("".join(t for _, t in sorted(parts, key=lambda x: x[0])).encode("latin-1"))
    lines = [f"verify {r.a.mode} {r.a.build}  ({time.strftime('%Y-%m-%d %H:%M:%S')}, wall {hms(time.time() - r.t0)},"
             f" {len(r.done_runs)} Mesen runs, {sum(1 for x in r.done_runs if x[3])} from the cache)"]
    worst = "PASS"
    for j in jobs:
        raw = open(j.raw, "rb").read().decode("latin-1") if j.raw and os.path.exists(j.raw) else ""
        v, why = j.verdict(raw) if j.verdict else ("INFO", "")
        if j.state == "fail":
            v, why = "FAIL", f"exit code {j.rc}; " + why
        if v == "FAIL":
            worst = "FAIL"
        dur = hms(j.t_end - j.t_start) if j.t_end else "-"
        lines.append(f"  {v:4s} {j.name:12s} {dur:>7s}  {j.out[0] if j.out else '':34s} {why[:150]}")
    lines.append(f"RESULT {worst} (INFO = no verdict line, see the file; known expected differences are not judged here)")
    txt = "\n".join(lines) + "\n"
    open(os.path.join(r.out, "summary.txt"), "w").write(txt)
    return txt, worst


def save_history(r, jobs, ok):
    h = r.hist
    runs = h.setdefault("runs", {})
    for k, wall, cpu, cached in r.done_runs:
        if not cached:
            runs[k] = round(wall, 1)
    if ok:
        mode = h.setdefault("modes", {}).setdefault(r.a.mode, {})
        mode["run_keys"] = [k for k, *_ in r.done_runs]
        mode["steps"] = {j.name: dict(runs=r.step_runs.get(j.name, [0, 0])[0],
                                      wall=round((j.t_end or 0) - (j.t_start or 0), 1)) for j in jobs}
        mode["wall"] = round(time.time() - r.t0, 1)
    write_json(HISTORY, h)


# ------------------------------------------------------------------------------------------------ lock / status
def acquire_lock(force):
    os.makedirs(VDIR, exist_ok=True)
    me = dict(pid=os.getpid(), created=proc_created(os.getpid()), cmd=" ".join(sys.argv), start=time.time())
    while True:
        try:
            fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            try:
                other = json.load(open(LOCK))
            except (OSError, ValueError):
                if time.time() - os.path.getmtime(LOCK) < 10:
                    time.sleep(1)
                    continue
                other = None
            if other and proc_alive(other["pid"], other.get("created")):
                raise SystemExit(f"REFUSED: another pipeline is running (pid {other['pid']}, started "
                                 f"{time.strftime('%H:%M:%S', time.localtime(other['start']))}: {other['cmd']}).\n"
                                 f"See: python tools/perf/verify.py status")
            print(f"stale lock removed ({'pid %d is gone' % other['pid'] if other else 'unreadable'})")
            os.remove(LOCK)
            continue
        os.write(fd, json.dumps(me).encode())
        os.close(fd)
        break
    pids = mesen_pids()
    if pids and not force:
        os.remove(LOCK)
        raise SystemExit(f"REFUSED: Mesen.exe is running (pids {pids}): an orphan or a pipeline started without this "
                         f"runner. Stop it (taskkill /PID <pid> /T /F) or pass --force.")


def release_lock():
    try:
        if json.load(open(LOCK))["pid"] == os.getpid():
            os.remove(LOCK)
    except (OSError, ValueError, KeyError):
        pass


def cmd_status(a):
    if not os.path.exists(PROGRESS):
        print("no pipeline has run yet (no tmp/verify/progress.json)")
        return
    st = json.load(open(PROGRESS))
    alive = proc_alive(st["pid"], st.get("created"))
    now = time.time()
    if st.get("finished"):
        state = f"FINISHED ({st['finished']})"
    elif alive:
        state = "RUNNING"
    else:
        state = "STALE: its runner process is gone (crashed or killed); the lock is freed by the next start"
    print(f"pipeline {st['mode']} {st['build']} pid {st['pid']}: {state}")
    print(f"  started {time.strftime('%H:%M:%S', time.localtime(st['start']))}, elapsed {hms((now if alive else st['now']) - st['start'])}"
          f", progress written {now - st['now']:.0f} s ago, out {st['out']}")
    steps = st["steps"]
    done = sum(1 for s in steps if s["state"] in ("done", "fail"))
    print(f"  steps {done}/{len(steps)} done, Mesen runs {st['runs_done']} done ({st['runs_cached']} cached)"
          + (f", ETA {time.strftime('%H:%M', time.localtime(st['now'] + st['eta']))}" if st.get("eta") and not st.get("finished") else ""))
    for i, s in enumerate(steps):
        if s["state"] == "wait":
            continue
        t = (s["end"] or (now if alive else st["now"])) - s["start"]
        m = s.get("runs_prev")
        print(f"   {i + 1:2d} {s['name']:12s} {s['state']:4s} {hms(t):>7s}  run {s['runs'][0]}/{m if m is not None else '?'}"
              + (f"  rc {s['rc']}" if s["rc"] not in (None, 0) else ""))
    wait = [s["name"] for s in steps if s["state"] == "wait"]
    if wait:
        print("   waiting: " + " ".join(wait))
    for r in st["running"]:
        print(f"   Mesen pid {r['pid']}: {r['label']} ({r['step']}) {r['elapsed'] + (now - st['now'] if alive else 0):.0f} s"
              f" (expected {r['est']:.0f}, hang limit {r['limit']:.0f})")


# ------------------------------------------------------------------------------------------------ main
def cmd_pipeline(a):
    a.out = os.path.abspath(a.out or os.path.join(VDIR, f"{a.build}_{a.mode}"))
    for b in [a.build, a.build + "f"] + ([a.build + "t", a.prev, a.base] + ([a.alt] if a.alt else []) if a.mode == "full" else [a.base]):
        if not os.path.exists(os.path.join(TMP, "builds", b, "rom.nes")):
            raise SystemExit(f"build {b} missing (python tools/perf/perf.py build {b})")
    acquire_lock(a.force)
    try:
        job = join_kill_job()
        os.makedirs(os.path.join(a.out, "steps"), exist_ok=True)
        for f in os.listdir(os.path.join(a.out, "steps")):     # step-end markers of an earlier run
            if f.endswith(".done"):
                os.remove(os.path.join(a.out, "steps", f))
        jobs = pipeline(a)
    except BaseException:
        release_lock()
        raise
    for i, j in enumerate(jobs):
        j.index = i + 1
    names = {a.build + "f": "{B}f", a.build + "t": "{B}t", a.build: "{B}", a.prev: "{P}", a.base: "{BASE}"}
    if a.alt:
        names[a.alt] = "{A}"
    r = Runner(a, jobs, names)
    if job is None:
        r.log("note: could not create the kill-on-close job object; children are killed explicitly only")
    ok = False
    worst = "FAIL"
    try:
        r.run_all(a.max_steps)
        txt, worst = assemble(r, jobs)
        ok = True
        r.stop = True
        r.log("pipeline finished, wall " + hms(time.time() - r.t0) + "\n" + txt)
        save_history(r, jobs, all(j.state == "done" for j in jobs))
        r.save_progress(final=worst)
    except KeyboardInterrupt:
        r.abort("Ctrl-C")
        r.save_progress(final="aborted (Ctrl-C)")
    except BaseException as e:
        r.abort(f"runner error {e!r}")
        r.save_progress(final=f"aborted ({e!r})")
        raise
    finally:
        r.stop = True
        if not ok:
            try:
                assemble(r, jobs)
            except Exception:                       # noqa
                pass
        left = mesen_pids()
        if left:
            r.log(f"killing leftover Mesen processes {left}")
            for pid in left:
                kill_tree(pid)
        release_lock()
        try:
            Cache.prune()
        except OSError:
            pass
    return 0 if ok and worst == "PASS" else 1


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "_step":
        return step_main(sys.argv[2:])
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="mode", required=True)
    for m in ("full", "quick"):
        s = sp.add_parser(m)
        s.add_argument("build")
        s.add_argument("--prev", default="p92g", help="co-op compare base (flick, tractor, stats, pixcmp)")
        s.add_argument("--alt", default=None, help="intermediate build (RAM identity / ramdiff / stats); none by default")
        s.add_argument("--base", default="base", help="1P base build")
        s.add_argument("--p90ref", default=None, help="earlier p90verify output for cmpverify")
        s.add_argument("--checkers", default=os.path.join(COOP, "p93"), help="dir of ramdiff/swapcheck/windowchk/pairchk/"
                                                                            "flick/tractor/cmpverify.py")
        s.add_argument("--p90tag", default="vfy", help="p90verify run tag (run files in p90/runs/TAG)")
        s.add_argument("--hudtag", default="hud93", help="hudcheck tag (1P base runs are reused from p90/runs/TAG)")
        s.add_argument("--jobs", type=int, default=4, help="Mesen processes at once (4 = measured best on 4 cores)")
        s.add_argument("--max-steps", type=int, default=10, help="step scripts at once")
        s.add_argument("--out")
        s.add_argument("--no-cache", action="store_true")
        s.add_argument("--force", action="store_true", help="start even if Mesen.exe processes are running")
    sp.add_parser("status")
    a = p.parse_args()
    if a.mode == "status":
        return cmd_status(a)
    if a.p90ref:
        a.p90ref = os.path.abspath(a.p90ref)
    a.checkers = os.path.abspath(a.checkers)
    return cmd_pipeline(a)


if __name__ == "__main__":
    sys.exit(main())
