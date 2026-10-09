#!/usr/bin/env python3
"""Turn a page log plus a CPU trace into the numbers in docs/BENCHMARKS.md.

The page log is the ground truth for what the browser received: every pointer event
with pointerType, pressure, tilt and an epoch timestamp. The CPU trace is
cputrace.py's output, which carries the same clock.

The run is split into bursts on gaps in the event stream, so a single session can
yield several independent samples.

usage: analyze.py <page-log> <trace.csv> [gap-ms]
"""
import collections
import json
import os
import statistics
import sys


def load_events(path):
    if not os.path.exists(path):
        return []
    rows = [json.loads(l) for l in open(path) if l.strip()]
    return sorted([r for r in rows if r.get("ms")], key=lambda r: r["ms"])


def load_trace(path):
    out = []
    for ln in open(path):
        if ln.startswith("#"):
            continue
        p = ln.split(",")
        if p[0] == "t_ms":
            continue
        out.append((int(p[1]), float(p[2]), int(p[3]), int(p[4])))  # epoch, cpu, rss, procs
    return out


def main():
    logf, tracef = sys.argv[1], sys.argv[2]
    gap = int(sys.argv[3]) if len(sys.argv) > 3 else 1200
    ev = load_events(logf)
    tr = load_trace(tracef)
    if not ev or not tr:
        print(f"no data: {len(ev)} events, {len(tr)} trace samples")
        return 1

    bursts = []
    cur = [ev[0]]
    for a, b in zip(ev, ev[1:]):
        if b["ms"] - a["ms"] >= gap:
            bursts.append(cur)
            cur = [b]
        else:
            cur.append(b)
    bursts.append(cur)

    def at(epoch_ms):
        return min(tr, key=lambda r: abs(r[0] - epoch_ms))

    print(f"{len(ev)} events, {len(bursts)} burst(s), {len(tr)} trace samples")
    print("pointerType:", dict(collections.Counter(r.get("pt") for r in ev)))
    print()
    tc = td = 0.0
    for i, b in enumerate(bursts):
        dur = (b[-1]["ms"] - b[0]["ms"]) / 1000.0
        if dur < 3:
            continue
        a, z = at(b[0]["ms"] - 600), at(b[-1]["ms"] + 600)
        cpu = z[1] - a[1]
        n = len(b)
        print(f"  burst {i+1}: {dur:5.1f}s  {n:5d} ev  {n/dur:5.1f} ev/s  "
              f"cpu {cpu*100/dur:5.2f}% of a core ({cpu/dur*1000:6.1f} ms/s)  "
              f"rss {z[2]/1024:5.1f} MB  procs {z[3]}")
        ivs = [y["ms"] - x["ms"] for x, y in zip(b, b[1:])]
        if ivs:
            s = sorted(ivs)
            print(f"              interval median {statistics.median(ivs):5.1f} ms  "
                  f"p95 {s[max(0,int(len(s)*0.95)-1)]:5.1f} ms  max {max(ivs):6.1f} ms")
        tc += cpu
        td += dur
    if td:
        print(f"  TOTAL: cpu {tc*100/td:5.2f}% of a core, {tc/td*1000:.1f} ms CPU per s of drawing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
