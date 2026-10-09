# Benchmarks

InkDriver against the vendor's driver, measured on the same machine, same tablet,
same Firefox, same test page, and the same instrument for both.

Short version: about 21x less CPU when idle, about 20 percent less CPU while drawing,
roughly 2.4x less memory, one process instead of four, and 1.2 MB instead of 100 MB.
Delivery of pen events is identical in both rate and interval distribution, so the
resource savings are not bought with responsiveness.

## Environment

| | |
| --- | --- |
| Machine | Mac16,10, Apple M4 |
| OS | macOS 26.6.2 (25G83) |
| Tablet | XP-Pen Deco 01 V3 |
| Browser | Firefox 157.0.1 |
| Displays | 2 |

Reproduce with `Support/bench/` (see the end of this file).

## Results

Idle means the driver is running with the pen out of range and nothing else touching
it. Drawing means continuous pen strokes in the browser.

| | InkDriver | vendor | ratio |
| --- | --- | --- | --- |
| Processes | **1** | 3 to 4 | |
| Threads | 3 | 18 | |
| CPU, idle | **0.077% of a core** (0.77 ms/s) | 1.613% (16.1 ms/s) | 21x less |
| CPU, drawing | **7.8 to 8.4% of a core** (77 to 84 ms/s) | 9.8 to 10.9% (98 to 109 ms/s) | 1.2x less |
| CPU per drawing second | **77 to 84 ms** | 98 to 109 ms | 20% less |
| Memory, idle | **84 MB** | 202 MB | 2.4x less |
| Memory, drawing | **76 MB** | 166 to 424 MB | 2 to 5x less |
| App bundle | **1.2 MB** | 100 MB | 83x smaller |
| Bundled frameworks | none | 10 Qt frameworks | |
| Non-system libraries | 0 | QtWidgets, QtGui, QtXml, QtNetwork, QtCore, OpenGL, AGL | |
| Architectures | arm64 | x86_64 + arm64 | |

Both run natively, so none of this is a Rosetta effect. The vendor's binaries are
universal and macOS picks arm64.

## Responsiveness is the same

This is the control that makes the resource comparison meaningful. Both drivers were
asked to do the same work, and the delivered event stream is indistinguishable:

| | InkDriver | vendor |
| --- | --- | --- |
| Pen events delivered | 1540 of 1596 | 1408 of 1420 |
| Delivery rate | 62 events/s | 62 events/s |
| Interval median | 16.0 ms | 16.0 ms |
| Interval p95 | 20.0 ms | 20.0 ms |
| Interval p99 | 24.0 ms | 25.0 ms |
| Distinct pressure values | 107 | 108 |

Both deliver on a 16 ms cadence, which is the 60 Hz display refresh: the browser
coalesces pointer movement to vsync, so the delivered rate says nothing about either
driver and is a fair common yardstick. Neither stream shows spikes or gaps that the
other lacks.

## Not measured

**End-to-end input latency is not measured here, and no claim is made about it.**
Measuring pen-to-pixel latency needs either a common clock on both sides of the HID
boundary or a high-speed camera, and the vendor's driver cannot be instrumented from
the outside. What the interval distribution shows is that neither driver introduces
jitter the other does not.

**CPU is measured across the whole application**, GUI included, because that is what
a user actually pays for. The vendor figure therefore includes its Qt window and its
helper processes, and the InkDriver figure includes its menu bar UI.

## Instruments, and one that was wrong

Everything here comes from two things: a process tracer and a page that reports what
the browser received.

**The tracer** reads `ps -o time=` for a fixed set of PIDs at 200 ms intervals and
unwraps `[[dd-]hh:]mm:ss.cc`. PIDs are captured once at start: letting the set change
mid-run produced an impossible negative CPU delta in an early attempt, when a helper
process came and went.

**It is validated before use.** Running it against a busy loop that pins one core
reads 99.9%. A measurement instrument that has not been checked against a known load
is a source of confident wrong numbers, and that is not hypothetical here.

**The rejected instrument.** The first version of the meter used
`proc_pid_rusage`, which looks strictly better: nanosecond CPU time, physical
footprint, wakeup counts, accumulated nanojoules. It reported 0.083 s of CPU for a
process that `ps` and a wall-clock busy loop both put at 3.53 s, a 40x
under-report on this macOS. It was believed for one measurement round because one of
its columns, energy, looked physically plausible (22 J for 3.5 s at full tilt, about
6 W, which is right for one core). One trustworthy-looking column made a wrong
struct look right. The "ours uses 1.7 ms CPU per second of drawing" figure that
appeared during that round was this bug, and it is wrong.

**The page** logs every pointer event with `pointerType`, pressure, tilt and a
timestamp, and POSTs it to a local HTTP logger. The raw log is the whole instrument:
it cannot be blind to a delivery path the way an event observer can, which mattered
repeatedly during this work (see `docs/POST-MORTEM-FIREFOX-PEN.md`).

## Reproducing

The tracer and page are small enough to keep here. For each driver in turn:

1. Start the driver under test, with the other one stopped.
2. `python3 Support/bench/cputrace.py idle.csv 15 200 "<pattern>"` with no pen input.
3. Start Firefox against the test page, then
   `python3 Support/bench/cputrace.py busy.csv 45 200 "<pattern>"` while drawing.
4. `python3 Support/bench/analyze.py <page log> busy.csv` to split the run and report
   CPU, memory and interval statistics per burst.

The page is served by a trivial HTTP server that appends each event to a log file.
Point Firefox at it with a cache-busting query, since the page changes during
development and a cached copy will silently measure the old version.

## Reading these numbers

The CPU and memory figures are single sessions on one machine, and the drawing was
done by hand. The control is the delivered event rate, which matched at 62 events/s
with identical interval medians, so both drivers were under equivalent load. The
vendor's memory varies between runs (166 MB to 424 MB observed) because Qt allocates
lazily; InkDriver sat at 76 MB in every run. Treat the CPU ratio as approximate and
the idle and memory differences as large.
