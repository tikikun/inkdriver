#!/usr/bin/env python3
"""Precise-enough CPU/memory tracer for the driver benchmarks.

proc_pid_rusage was tried first and rejected: on this macOS it reported 0.083 s of
CPU for a process that ps and a wall-clock busy loop both showed at 3.53 s, a 40x
under-report, so it cannot be used to compare two drivers. ps is validated here
against a known load (a busy loop pins one core, ps reports ~100%) and its
centisecond resolution is far finer than needed for a measurement window of tens of
seconds.

PIDs are fixed at start. Letting the set change mid-run is what produced an
impossible negative CPU delta in an earlier attempt.

usage: cputrace.py <out.csv> <seconds> <interval_ms> <pattern...>
"""
import subprocess
import sys
import time


def pids_for(pattern):
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout
    return [int(x) for x in out.split() if x.strip().isdigit()]


def cpu_seconds(text):
    """ps -o time= gives [[dd-]hh:]mm:ss.cc, sometimes without the seconds part."""
    t = text.strip()
    if not t:
        return None
    if "-" in t:
        days, t = t.split("-", 1)
        days = int(days)
    else:
        days = 0
    parts = [float(p) for p in t.split(":")]
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return days * 86400 + secs


def sample(pids):
    if not pids:
        return None
    out = subprocess.run(["ps", "-o", "pid=,time=,rss=", "-p", ",".join(map(str, pids))],
                         capture_output=True, text=True).stdout
    cpu = 0.0
    rss = 0
    live = 0
    for line in out.splitlines():
        f = line.split()
        if len(f) < 3:
            continue
        c = cpu_seconds(f[1])
        if c is None:
            continue
        cpu += c
        rss += int(f[2])
        live += 1
    return cpu, rss, live


def main():
    out_path, seconds, interval_ms = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
    patterns = sys.argv[4:]
    pids = []
    for pat in patterns:
        pids += pids_for(pat)
    pids = sorted(set(pids))
    if not pids:
        print(f"no processes matched {patterns}", file=sys.stderr)
        return 1
    start_epoch_ms = int(time.time() * 1000)
    with open(out_path, "w") as fh:
        fh.write(f"#start_epoch_ms={start_epoch_ms}\n")
        fh.write("t_ms,epoch_ms,cpu_s,rss_kb,live\n")
        t0 = time.time()
        while True:
            elapsed = time.time() - t0
            s = sample(pids)
            if s is not None:
                fh.write("%.0f,%d,%.2f,%d,%d\n" % (elapsed * 1000, int(time.time() * 1000),
                                                   s[0], s[1], s[2]))
                fh.flush()
            if elapsed >= seconds:
                break
            time.sleep(interval_ms / 1000.0)
    print(f"traced {len(pids)} pids for {seconds:g}s at {interval_ms}ms -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
