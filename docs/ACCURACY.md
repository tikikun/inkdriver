# Accuracy

Three different things get called accuracy, and they are measured differently:

1. **Transform exactness.** Is the tablet-to-screen map affine, does it cover the
   intended area exactly, and does pressure survive at full resolution? These are
   exact properties of the code, so they are checked arithmetically and need no
   hardware.
2. **Resolution.** How much of the device's precision reaches an application.
3. **Physical convention.** Does the number an app sees mean what it claims to mean,
   in degrees and in Apple's units? This needs hardware and, for one question, the
   vendor's own specification.

Run the exact checks with:

```sh
.build/release/xppen-probe --check-accuracy
```

## Transform exactness

All of these pass, over 64 combinations of mapping mode, rotation and inversion,
sampling 512 points across each axis of the tablet:

| Check | Result |
| --- | --- |
| Points escaping the display | 0.000000 px, including raw values beyond the active area |
| Coverage of the target rect | 0.000000 px error on all four sides |
| Departure from an affine map | 0.000000 px |
| Pressure levels preserved | 16384 of 16384, monotonic, exact at both ends |
| Largest pressure step | 0.000061, which is exactly the device quantum |

The coverage and affine checks are exact rather than statistical. Affineness is
tested by the definition, sending the midpoint of two raw values to the midpoint of
their images, because an earlier version of the check measured step sizes between
raw samples truncated to integers and was reporting its own truncation, 0.08 px of
apparent non uniformity, as if it were the driver's.

## Resolution

One raw unit moves the cursor 0.0504 px horizontally and 0.0454 px vertically on a
2560x1440 display, so about 20 raw units per screen pixel. The fractional part is
preserved: the mapping is done in floating point and does not snap to whole pixels,
which matters for drawing applications that accumulate sub-pixel positions.

Coordinate precision is therefore limited by the 50800 x 31750 device grid, not by
the projection. Pressure reaches applications with all 14 bits intact.

## Physical convention: tilt is overstated by 7 percent

This one is a real deviation, and it is inherited deliberately from the vendor.

Measured on hardware, with the pen pushed to its mechanical limit in both axes:

```
tiltX raw off the wire -60 ... 60
tiltY raw off the wire -60 ... 60
```

The model is rated at ±60 degrees of tilt, so the raw units are degrees. Apple's
convention is that `NSEvent.tilt` runs from -1.0 to 1.0 where 1.0 is a 90 degree
tilt, which Firefox makes explicit (`nsChildView.mm`):

```objc
aOutGeckoEvent->tiltX = lround([aPointerEvent tilt].x * 90);
```

The driver divides raw tilt by 84, copied from the vendor's constant, so a maximum
physical tilt of 60 degrees reaches an application as

```
lround(60 / 84 * 90) = 64 degrees
```

A 7 percent overstatement, and the last few degrees of travel are compressed into the
same reported angle. The correction is one config value:

```json
{ "tiltScale": 90.0 }
```

which reports true degrees, so a 60 degree tilt arrives as 60. The default stays at
84 to match the vendor's driver exactly, since application brush behaviour is
calibrated against that. The setting is exposed in the menu bar UI as well. Set it to
90 if you want physically meaningful angles and do not mind differing from the
official driver.

### A wrong conclusion, caught by measuring

The first tilt session showed the decoded values piling up at exactly 60: 317 samples
at 60 against 14 at 59. That looks precisely like a saturating clamp, and the driver
does have one at ±60, so the obvious reading was that the clamp was discarding the
outer travel. The raw pre-clamp bytes say otherwise: they also stop at exactly ±60.
The pen was simply resting against its mechanical limit, and the clamp never engages
on this model. The instrumented probe was extended to record tilt as it comes off the
wire for exactly this reason, because a clamped figure cannot report whether the
clamp is active.

## Not measured

**Absolute positional accuracy** against a physical target. That means drawing to
known coordinates on the tablet and comparing where the cursor lands, with the pen
held perpendicular and the tablet fixed. What is verified here is that the projection
is exact and lossless for a given raw coordinate, not that the device's internal grid
is physically square or that its origin matches the overlay.

**Pressure to force linearity.** The driver forwards pressure faithfully, and the
device reports it monotonically, but whether equal steps of pressure correspond to
equal steps of force is a property of the pen hardware and would need a load cell.

**Hover distance and height**, which the device does not report on the interface this
driver reads.

**End to end latency**, which needs a common clock across the HID boundary or a
high-speed camera. See `docs/BENCHMARKS.md`.
