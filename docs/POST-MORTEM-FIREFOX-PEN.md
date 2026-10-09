# Post-mortem: Firefox would not see the pen

This is the long version of one bug. It cost several hours and at least a dozen
round trips through the user, it produced two conclusions that were flatly wrong and
that I stated with confidence three times, and the fix at the end is four lines. It
is written down because the failure mode is not specific to tablets, and because the
reasons I went wrong are more useful than the answer.

The answer, for anyone who wants only that: `docs/PROTOCOL.md`, section "The cause,
and the fix", and `Sources/CTabletEvent/CTabletEvent.c`.

## Symptom

Everything worked except Firefox. Cursor, pressure, tilt, both barrel buttons, all
eight express keys, per-display mapping: all correct, verified on hardware. Chromium
and every native AppKit application saw a full pen, 14-bit pressure included.

Firefox saw this:

```
pointerType: "mouse"
pressure:    {0, 0.5}
tiltX: 0    tiltY: 0
width: 1    pointerId: 0
```

And the vendor's driver, same machine, same Firefox, same page, produced:

```
{'mouse': 92, 'pen': 73}
47 distinct pressure values
tiltX 0..5
```

So the target was concrete and the gap was measurable. That is what made the
debugging possible, and also what made it so expensive: a clear control that I
misread for hours.

## What Firefox actually requires

Firefox's `widget/cocoa/nsChildView.mm`, current tree, is unchanged from the 2017
patch that introduced this (Bug 1304904):

```objc
static bool sIsTabletPointerActivated = false;

- (void)tabletProximity:(NSEvent*)theEvent {          // the only writer
  sIsTabletPointerActivated = [theEvent isEnteringProximity];
}

- (void)convertCocoaTabletPointerEvent:(NSEvent*)aPointerEvent ... {
  if (!aOutGeckoEvent || !sIsTabletPointerActivated) return;   // no proximity, no pen
  aOutGeckoEvent->mPressure = [aPointerEvent pressure];
  aOutGeckoEvent->mInputSource = dom::MouseEvent_Binding::MOZ_SOURCE_PEN;
}

case NSMouseMoved:
  if ([aMouseEvent subtype] == NSTabletPointEventSubtype) {
    [self convertCocoaTabletPointerEvent:...];         // gated
  }
```

Grep the whole file for `MOZ_SOURCE_PEN` and there is exactly one site. Pen,
pressure and tilt all hang off `tabletProximity:` having fired with
`isEnteringProximity == true`. There is no second path.

And AppKit raises `tabletProximity:` only for a **native** `NSTabletProximity`
event. Apple's documentation has said so since the beginning: a proximity event is
"always a native tablet event, never a mouse subtype", even though the older
prose also mentions `NSTabletProximityEventSubtype`. That clause is the trap, and
the rest of this document is what happens when you fall into it.

## Root cause

Two facts, and one wrong assumption joining them.

**Fact one.** `IOHIDPostEvent` expects a pointer to `NXTabletProximityData` with the
fields at offset zero of the buffer:

```
+0x00 vendorID      +0x18 capabilityMask
+0x02 tabletID      +0x1c pointerType
+0x04 pointerID     +0x1d enterProximity
+0x06 deviceID
+0x08 systemTabletID
+0x0a vendorPointerType
```

**Fact two.** In an `NXEventData`, the tablet union does not start at zero. It
follows `subx`, `suby`, `eventNum`, `click`, `pressure`, `buttonNumber`, `subType`,
`reserved2` and `reserved3`, which is 16 bytes, so it begins at **+0x10**.

The shim did the natural thing, which is the wrong thing:

```c
NXEventData data;
data.mouse.tablet.proximity.capabilityMask = 0x17c7;   // lands at +0x28, kernel reads +0x18
data.mouse.tablet.proximity.enterProximity = entering; // lands at +0x2d, kernel reads +0x1d
```

Every field 16 bytes past where the kernel looks.

**The wrong assumption is what turned a bug into an afternoon.** I assumed a
malformed event fails harmlessly, so "nothing arrived" meant the API could not do the
job. It does not fail harmlessly. A bad proximity event puts the input system into a
tablet-in-proximity state, and from that point on **the posting process's `CGEvent`
posts are silently dropped**. I was measuring a wedge and reading it as a no-op, and
that is why `IOHIDPostEvent` earned a reputation in this repository for being dead.
It is not dead. It is strict.

The fix, in full:

```c
unsigned char buf[64];
memset(buf, 0, sizeof(buf));
*(unsigned short *)(buf + 0x00) = vendorID;
*(unsigned short *)(buf + 0x02) = tabletID;
*(unsigned short *)(buf + 0x04) = pointerID;
*(unsigned short *)(buf + 0x18) = capabilityMask;
buf[0x1c] = pointerType;
buf[0x1d] = entering ? 1 : 0;
IOHIDPostEvent(connect, NX_TABLETPROXIMITY, location, (NXEventData *)buf,
               kNXEventDataVersion, 0, kIOHIDSetCursorPosition);
```

## The regression, if this is ever "cleaned up"

If anyone tidies that buffer into `NXEventData` and a struct member, the pen silently
disappears from Firefox and nothing else breaks. That is exactly how it was lost the
first time, and it is why the offsets are written as raw byte arithmetic with a
comment rather than as the type-safe version that looks better.

## How far it went: the attempts, in order

Each row is a real measurement, not a theory. The right hand column is what it
actually showed, which is repeatedly not what I took it to mean.

| attempt | measured result | what it proved |
| --- | --- | --- |
| Re-announce proximity on every tip-down | 23 tip-downs, all `mouse` | not a timing or focus problem |
| Make the proximity and point events share one device id | no change | not an id mismatch |
| Mirror movement through `IOHIDPostEvent` | 72 events, all `mouse` | not the movement path |
| `IOHIDPostEvent` with `NX_TABLETPROXIMITY`, options 0 and 2 | returned `KERN_SUCCESS`, "nothing arrived" | **misread.** The event was malformed and wedged delivery |
| Online research into Firefox | found the `sIsTabletPointerActivated` gate | narrowed it to one callback |
| Copy the vendor's proximity field values exactly (`did 5`, `sysTablet 2`, `ptrID 0`, `vPtrType 2082`) | 155 events, all `mouse` | not a field value |
| Leave the Digitizer collection to macOS instead of seizing it | 70 events, all `mouse` | not a suppressed native device |
| Instrument the responder *callback*, not the event subtype | subtype 2 arrives via `mouseMoved`, never `tabletProximity:` | the CGEvent route can never work, and my earlier "proximity works" was wrong |
| Same instrument, with the **vendor** driver | `tabletProximity:` never fired there either | contradicted the confirmed vendor control, so the instrument was wrong again |
| Re-verify the vendor control | `{mouse: 2, pen: 60}` | the vendor really does work; my observer could not see how |
| Build an oracle that drives the browser directly | saw the delivery wedge for the first time | `IOHIDPostEvent` was doing something, not nothing |
| Read `IOLLEvent.h` for the real struct offsets | tablet union at `+0x10`, vendor writes `+0x00` | **root cause** |
| Port the vendor's layout into the shim | `{mouse: 8, pen: 59}`, 39 pressures, tilt | fixed |

Two of those rows are conclusions I published in this repository and then had to
retract: that the vendor's `IOHIDPostEvent` path was inert, and that no userspace
route to a native tablet event existed.

## The three measurement mistakes

These are the part worth remembering.

**1. I counted the mechanism instead of the outcome.** Early on I confirmed that
events of subtype 2, the proximity subtype, were arriving, and recorded "proximity
events: 1". That is true and completely beside the point. What matters is which
responder *callback* AppKit chooses, and it chose `mouseMoved`. I then checked the
subtype twice more rather than the thing that mattered, which is how the same wrong
statement survived three rounds of "verification".

**2. My instrument could not see the control.** I watched the vendor driver with a
`NSView` that recorded callback names, saw no `tabletProximity:`, and concluded the
vendor did not produce one either. The observer only sees events routed to *my*
process. The vendor's proximity event goes to the application under the cursor, which
was Firefox, not my window. When your instrument cannot observe a control you know
works, the instrument is broken, and I treated it as evidence about the control
instead.

**3. I never questioned the assumption underneath the API.** "Returns
`KERN_SUCCESS` and nothing arrives" reads like a dead API. It also reads like a
malformed event, and the second reading never crossed my mind. Success means the
call was accepted, not that the payload was understood.

There is a fourth, smaller one worth naming: the test that established
"`IOHIDPostEvent` does nothing" filtered incoming events by location, and a proximity
event is not necessarily inside the view. I removed the filter only much later, and
the conclusion survived that change by luck, which is not the same as being right.

## What broke the deadlock

Two things, both of which should have been step one.

**Reading the vendor's disassembly, byte by byte.** Your suggestion. I had
`PostTabletProximity` and `PostTabletPointMove` recovered all along and had read them
for *what they called*, not for *where they wrote*. The moment I compared
`this[0x3d]` and `*(u32*)(this+0x38)` against the real struct offsets in
`IOLLEvent.h`, the 16 byte shift was visible in one line.

**An oracle with no observer, no pen and no user.** It posts a proximity event, then
posts its own synthetic tablet-point events over the browser window, then reads what
the page reported:

```c
IOHIDPostEvent(connect, NX_TABLETPROXIMITY, loc, probe, 2, 0, kIOHIDSetCursorPosition);
for (i...) { /* synthetic CGEvent, subtype 1, known pressures */ }
// then ask /tmp/penserver.py what pointerType it saw
```

That removes every blind spot that produced the wrong conclusions: no responder
chain to interpret, no routing to guess at, no human to ask. It answered in seconds a
question I had spent hours assembling indirect evidence for. Building it early would
have saved most of the session.

## Timeline cost, honestly

Roughly two thirds of the debugging was spent on the two hypotheses that were false,
and a large share of that was spent asking for pen strokes that could not have
distinguished anything. Several user round trips produced evidence I then
misinterpreted, which is worse than producing none, because it bought confidence.
The fix itself took about fifteen minutes once the offset was on screen.

## Rules I would take to the next one

1. Measure the outcome the user cares about (`pointerType`, pressure values), never
   the mechanism that is supposed to cause it.
2. If a control passes and your instrument says it should not, fix the instrument
   before you touch the product.
3. `KERN_SUCCESS` means accepted, not understood. When a call returns success and
   produces nothing, ask what state you just put the system in.
4. Prefer an oracle that talks directly to the consumer over any instrument that has
   to interpret an event stream.
5. When a recovered function and a header disagree, the header is the specification
   and the disassembly is the truth. Read both, at the byte level.
6. Retract fast and loudly. Two of the wrong turns here were carried by a previous
   confident statement that nobody rechecked, including me.

## Verification

Same harness, same page, same machine, before and after, against the vendor:

| | before | after | vendor |
| --- | --- | --- | --- |
| `pointerType` | mouse, always | `{mouse: 8, pen: 59}` | `{mouse: 92, pen: 73}` |
| distinct pressure | 2 (`0, 0.5`) | 39 | 47 |
| tilt | 0 | tiltX 0..10, tiltY -11..0 | tiltX 0..5 |

Reproduction harness for anyone revisiting this: a small HTTP logger that receives
pointer events posted by the page, and Firefox launched against a throwaway profile
(`--new-instance --profile /tmp/ffpen-profile`). The plain text log is the whole
instrument, and it is far more reliable than anything that has to interpret AppKit.
