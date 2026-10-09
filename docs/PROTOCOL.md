# XP-Pen Deco 01 V3: protocol and behaviour notes

Every fact below was **measured on real hardware** with `xppen-probe`, then
cross-checked against the vendor driver's own code where noted. Anything that is
inference rather than measurement is marked. The earlier version of this file was
built from OpenTabletDriver's config alone and had several wrong values (wrong
interface, 13-bit pressure, wrong tilt divisor); those are corrected here.

Reproduce with:

```bash
.build/release/xppen-probe                    # enumerate interfaces
.build/release/xppen-probe --descriptor       # raw HID report descriptors
.build/release/xppen-probe --watch --init     # stream and decode
```

## Device identity

| Field | Value | Source |
| --- | --- | --- |
| Vendor ID | `0x28BD` (10429) | IORegistry |
| Product ID | `0x0947` (2375) | IORegistry |
| Product string | `Deco 01 V3` | IORegistry |
| Manufacturer string | `UGTABLET` | IORegistry |
| Transport | USB | IORegistry |
| Active area | 254 × 158.75 mm | XP-Pen spec / OTD config |
| Raw coordinate ceiling | X 50800, Y 31750 | measured (edge trace hit both exactly) |
| Pressure | 0 ... 16383 (14-bit) | measured (hard press reached exactly 16383) |
| Tilt | -60 ... 60 | measured, matches the vendor clamp `0xC4` / `0x3C` |

## HID interfaces

The device exposes **three** interfaces. Only one carries pen data.

| Usage page / usage | Report ID | Max in | Max out | Role |
| --- | --- | ---: | ---: | --- |
| `0x0001` / `0x0002` | 9 (mouse), 6 (keyboard) | 8 | 1 | fallback mouse + keyboard collection |
| `0x000D` / `0x0002` | 7 | 10 | 1 | standard digitizer-pen collection |
| `0xFF0A` / `0x0001` | 2 | 12 | 10 | **vendor-defined: the real pen stream** |

The vendor driver agrees: `CTablet::SwitchDeviceChannel` sends output report 2 and
registers its input callback on the interface whose `MaxOutputReportSize > 7`.

**Important:** the mouse and digitizer interfaces are also consumed by macOS
itself, which moves the cursor from them independently of any driver. A driver
must open them with `kIOHIDOptionsTypeSeizeDevice` or the pointer will drift on
its own (measured: without the seize, ~900 stray `subtype=3` mouse-moved events
appear in a 6-second capture; with it, zero).

## Handshake, verified

Send on the vendor interface, **report ID 2**, with the report ID as byte 0 of a
10-byte buffer (the IOKit convention for numbered reports):

```
02 B0 04 00 00 00 00 00 00 00
```

The device answers `02 B1 04 00 00 00 00 00 00 00 00 00`.

### The device leaves tablet mode when idle

The handshake is not a one-off. An idle tablet stops reporting on the vendor
interface entirely, and does not resume until `02 B0 04` is sent again. Measured
on an otherwise untouched device with `xppen-probe --watch`: zero reports without
`--init`, a steady stream with it.

A driver therefore has to repeat the command rather than send it once at startup,
or the pen goes dead after a few minutes and stays dead until something
re-initialises it. Note also that an idle tablet is silent by design, so a lack of
reports on its own does not indicate a fault; the two cases are only
distinguishable by re-arming and seeing whether anything comes back.

The vendor's startup sequence continues with `80 06 F1`, `02 B8 04`, `80 06 64`,
`80 06 04`, `80 06 03`, `80 06 05` (spaced 500 µs apart, 1 s after launch). These
carry configuration the tablet does not need for drawing, so we do not send them.

## Input reports: 12 bytes on the vendor interface

```
[0]      report ID, always 0x02 on the pen interface
[1]      status (see below)
[2..3]   X, low 16 bits, little-endian
[4..5]   Y, low 16 bits, little-endian
[6]      pressure, low 8 bits
[7]      pressure bits 8..13 (mask 0x3f); never exceeds 0x3f
[8]      tilt X, signed, calibrated range -60 ... 60
[9]      tilt Y, signed, calibrated range -60 ... 60
[10]     X bit 16
[11]     Y bit 16
```

```c
x        = report[10] << 16 | u16le(report + 2);
y        = report[11] << 16 | u16le(report + 4);
pressure = report[7] << 8   | report[6];      // 14 bits used
tilt_x   = (int8_t)report[8];
tilt_y   = (int8_t)report[9];
```

The vendor's code matches, including the pressure branch:
`CTablet::OnPostTabletMouseData` computes `(report[7] & 0x1f) << 8 | report[6]`
for devices whose maximum is ≤ 0x2000, but for devices whose maximum is larger it
uses the full 16-bit read. This model takes the second branch, which is why the
`& 0x1f` mask must **not** be copied.

### Status byte `report[1]`

| Value | Meaning | Evidence |
| --- | --- | --- |
| `0xA0` | pen in range, no buttons | measured (hover) |
| `0xA1` | tip switch closed | measured |
| `0xA4` | barrel button (upper) | measured; `0xA5` = tip + button |
| `0xA8`/`0xA9` | eraser | vendor special-case; not yet observed here |
| `0xC0` | pen out of range | measured |
| `0xB0`-`0xBF` | command reply (e.g. `0xB1`) | measured |
| `0xF0` | express keys, mask in `report[2]` | measured |

Bit meanings: `0x01` tip, `0x02` barrel button 1, `0x04` barrel button 2,
`0x08` eraser, `0x10` part of the command/express encoding, `0x40` out of range.

The vendor excludes `report[1] >= 0xf0` and `(report[1] & 0xf0) == 0xb0` from its
pen path, so command replies must not be parsed as pen data.

### Express keys

`report[1] == 0xF0`, with a one-hot bitmask in `report[2]`:

| Key | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Bit | `0x01` | `0x02` | `0x04` | `0x08` | `0x10` | `0x20` | `0x40` | `0x80` |

`report[2] == 0` is the release. All eight were confirmed by pressing them in
order.

## Event synthesis

Reconstructed from the vendor (`setFillTabletEventFields` 0x1000158ef,
`setFillProximinityFields` 0x100015f19) and matched against `CGEventTypes.h`:

| `CGEventField` | Number | Type | Value |
| --- | ---: | --- | --- |
| `kCGMouseEventSubtype` | 7 | int | **1** (`kCGEventMouseSubtypeTabletPoint`) |
| `kCGTabletEventPointX` | 15 | double | raw tablet X |
| `kCGTabletEventPointY` | 16 | double | raw tablet Y |
| `kCGTabletEventPointZ` | 17 | double | 0 |
| `kCGTabletEventPointButtons` | 18 | int | bit 0 tip, bit 1 button 1, bit 2 button 2 |
| `kCGTabletEventPointPressure` | 19 | double | pressure / 16383 |
| `kCGTabletEventTiltX` | 20 | double | tilt X / 84.0 |
| `kCGTabletEventTiltY` | 21 | double | -tilt Y / 84.0 |
| `kCGTabletEventRotation` | 22 | double | 0 |
| `kCGTabletEventTangentialPressure` | 23 | double | 0 |
| `kCGTabletEventDeviceID` | 24 | int | product ID |

Setting field 7 to 1 is what makes applications treat the event as a tablet
point, and it is what browsers use to report `pointerType: "pen"`. Verified end to
end: a posted event reaches a session event tap as
`subtype=1 tablet=(12345,6789) pressure=0.5000 tilt=(0.250,0.000) buttons=1`.

### Pressure must also go in kCGMouseEventPressure

Writing the tablet pressure field alone is **not enough**, and this is easy to get
wrong because the raw event looks correct. Applications, and every browser, read
`NSEvent.pressure`, which AppKit takes from `kCGMouseEventPressure` (field 2), not
from `kCGTabletEventPressure` (field 19). With only the tablet field set, AppKit
reports `1.0` while the mouse button is down and `0.0` otherwise, so a web drawing
app sees full pressure the instant you touch the surface and nothing in between.

Measured with `xppen-presscheck`, sending a ramp of 0.375, 0.625, 0.875, 1.0:

| fields set | `NSEvent.pressure` received | |
| --- | --- | --- |
| tablet field only | `1.0000, 1.0000, 1.0000, 1.0000` | constant, i.e. button state |
| tablet field **and** mouse pressure field | `0.3725, 0.6235, 0.8745, 1.0000` | tracks the ramp |

So both fields are written: field 19 for consumers that read the tablet data
directly, field 2 because that is what AppKit and the browsers actually surface.
Tilt does not have this problem: `NSEvent.tilt` reads the tablet tilt fields, and
a sent tilt of 0.238 arrives as 0.238.

A mouse event carrying tablet fields must also match what the application expects
for the current button state: while the tip is down the event type has to be
`leftMouseDragged`, not `leftMouseMoved`. A move with no button held reads as
hovering and is ignored for the stroke in progress.

The vendor divides tilt by 84.0 (`DAT_10001f208` = `0x4055000000000000`). The
sensor's own range is ±60 (`DAT_10001d040` = `0xC4`, `DAT_10001d050` = `0x3C`),
so `tiltScale` is configurable and defaults to 84.0 for parity.

The vendor posts proximity through `IOHIDPostEvent` (type `0x18`) with an
NXTabletPointData struct, which has no public CoreGraphics equivalent: there is
no way to set an event's *type*. We attach the device/vendor IDs and the
TabletPoint subtype to a mouse-moved event instead.

## Vendor action IDs

Transcribed from `language.ini` in the shipped app, and the defaults from
`config.xml` (`PenBtn1 Actid="207"`, `PenBtn2 Actid="209"`).

| ID | Action | ID | Action |
| ---: | --- | ---: | --- |
| 1-26 | keyboard shortcuts (B, E, Alt, Space, Cmd+S, …) | 121 | Show Desktop |
| 27 | Eraser | 122 | On-screen keyboard |
| 101 | Show driver panel | 127 | Mission Control |
| 102 | Switch monitor | 128 | App Exposé |
| 103 | Pen / Eraser | 130 | Launchpad |
| 104 | Precision mode | 201-205 | Shift, Left/Right Alt, Ctrl, Space |
| 112 | Disabled | 206-209 | Left, Right, Middle, Double click |
| | | **210/211** | **Scroll up / Scroll down** |

`RelativeCoords Speed="5"` in the config plus the ×0.2 factor in
`CEventPort::TabletPointToScreenPoint` describe a wheel mode where pen movement
becomes scroll deltas. Our `wheelMode` binding implements the same idea: while
the bound key is held, pen movement scrolls and the cursor is held still.

## What each browser needs

Read from the browsers' own source, because the requirements differ and a driver
that satisfies one can fail another.

**Chromium and Edge** set the pointer type from the event *subtype* and read
pressure from `NSEvent.pressure`:

```objc
if (subtype == NSTabletPointEventSubtype || subtype == NSTabletProximityEventSubtype)
    result.pointerType = PointerType::Pen;
result.force = [event pressure];
```

Satisfied by writing the tablet subtype plus `kCGMouseEventPressure`.

**Firefox** will not report a pen until it has been told one is in range, and the
way to tell it is a mouse event with **subtype 2**
(`NSTabletProximityEventSubtype`), carrying the proximity fields. Apple's guide:
a tablet-proximity event has "a type of NSTypeProximity or a mouse subtype of
NSTabletProximityEventSubtype", and the subtype form is the one CoreGraphics can
create.

Measured: with the vendor driver, Firefox reports `pointerType: "pen"` and varying
pressure; capturing both drivers' event streams with the same observer showed the
vendor emits `subtype = 2` mouse events and a driver using only `subtype = 1` emits
none. Setting `kCGMouseEventSubtype` to 2, plus
`kCGTabletProximityEventEnterProximity` and the vendor/tablet/pointer ids, fixes it.

### What IOHIDPostEvent can and cannot do

Measured on this macOS with an observer whose view is in the responder chain:

| type | result |
| --- | --- |
| `NX_MOUSEMOVED` (5) | **delivered** (arrives as `mouseMoved`, subtype 0) |
| `NX_TABLETPROXIMITY` (24) | returns `KERN_SUCCESS`, **nothing arrives** |
| `NX_TABLETPOINTER` (23) | returns `KERN_SUCCESS`, **nothing arrives** |

So the deprecated call still works for mouse moves but no longer produces native
tablet events. A consequence worth stating: the vendor's `PostTabletProximity` and
`PostTabletPointer` are therefore inert on this macOS as well, and its tablet
support comes from its CoreGraphics events plus its IOHIDPostEvent *mouse* moves.

An earlier note here claimed this required `IOHIDPostEvent`, on the strength of a
2017 Firefox patch that gated on a `tabletProximity:` callback. That was wrong:
`Sources/CTabletEvent` is retained but **unused**, because the CGEvent subtype path
does the job and the IOHIDPostEvent route never delivered an observable event.

The older note follows. `widget/cocoa/nsChildView.mm` holds a static flag and returns early
without it:

```objc
static bool sIsTabletPointerActivated = false;

- (void)convertCocoaTabletPointerEvent:(NSEvent*)aPointerEvent ... {
  if (!aOutGeckoEvent || !sIsTabletPointerActivated) return;   // no pen, no pressure
  aOutGeckoEvent->pressure = [aPointerEvent pressure];
  aOutGeckoEvent->inputSource = MOZ_SOURCE_PEN;
  ...
}

- (void)tabletProximity:(NSEvent*)theEvent {
  sIsTabletPointerActivated = [theEvent isEnteringProximity];
}
```

Apple's event guide states that proximity events are *always* native tablet
events and never mouse subtypes, and CoreGraphics cannot set an event's type. So
this requires `IOHIDPostEvent` with `NX_TABLETPROXIMITY` (24), which is what the
vendor driver does and what `Sources/CTabletEvent` exists for. This has been
implemented but **not yet confirmed**: the call returns success, and no proximity
event has been observed arriving at an application in testing.

**Safari and WebKit** derive force from `NSEvent.pressure` and the pressure stage,
and there are long-standing reports of `PointerEvent.pressure` reading 0 on macOS
for tablet input in Safari. Treat Safari as uncertain regardless of the driver.

## What is *not* used

No vendor code and no OpenTabletDriver code. Only measured facts about the wire
format and the event fields, all reproducible with the tools in this repo.
