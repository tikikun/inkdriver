# InkDriver vs the vendor driver

A factual comparison for the XP-Pen Deco 01 V3. Every number here was measured on
a real Mac with the commands shown, and every "the vendor does/does not…" claim
comes from static analysis of the shipped binaries.

**Please keep this honest.** The vendor driver is a commercial product that
supports around 120 tablet models, has per-application profiles, an updater and a
BLE stack. InkDriver drives **one** tablet. The comparison below is about footprint
and network surface, not about who wrote a better product.

---

## Size

| | XP-Pen 4.0.18 | InkDriver | |
| --- | ---: | ---: | --- |
| What you download | 54 MB installer | **272 KB** `git clone` | 200× smaller |
| Installed on disk | **~102 MB** | **867 KB** | 120× smaller |
| The driver itself | 630 KB (both architectures) | **418 KB** | |
| The GUI | 27 MB | 820 KB (the whole app) | 33× smaller |
| Bundled frameworks | 56 MB of Qt + 16 MB of plugins | **none** | |
| Bundled dylibs | `libeGalaxGesture.dylib` | **none** | |
| Background processes | 3 | **1** | |
| Source code shipped | 0 files | all 3,541 lines | |

<details>
<summary>How these were measured</summary>

```sh
stat -f%z "$HOME/Downloads/XPPenMac_4.0.18_260723.dmg"   # 56964882
du -sh /Applications/XPPen                               # 100M
du -sh "/Library/Application Support/PenDriver"          # 2.2M
du -sh /Applications/XPPen/XPPenTablet.app/Contents/Frameworks   # 56M
du -sh /Applications/XPPen/XPPenTablet.app/Contents/PlugIns      # 16M
du -sh .build/InkDriver.app                              # 867K
find Sources -name '*.swift' | xargs wc -l | tail -1     # 3541
du -sh .git                                              # 272K
```
</details>

---

## What it talks to

This is the part worth caring about, because it is binary and verifiable.

The driver imports **278 symbols** in total. Strip the Swift runtime and the
compiler support routines and you are left with **48 Apple API entry points**.
this is the entire surface through which the driver can affect your machine:

```
CoreGraphics   (14)  CGDisplayBounds  CGEventCreateKeyboardEvent  CGEventCreateMouseEvent
                     CGEventCreateScrollWheelEvent2  CGEventPost  CGEventSetDoubleValueField
                     CGEventSetFlags  CGEventSetIntegerValueField  CGEventSourceCreate
                     CGGetActiveDisplayList  CGMainDisplayID  CGRectGetHeight
                     CGRectGetWidth  CGRectUnion
IOKit HID      (12)  IOHIDDeviceGetProperty  IOHIDDeviceGetService  IOHIDDeviceOpen
                     IOHIDDeviceRegisterInputReportCallback  IOHIDDeviceScheduleWithRunLoop
                     IOHIDDeviceSetReport  IOHIDManagerCopyDevices  IOHIDManagerCreate
                     IOHIDManagerOpen  IOHIDManagerScheduleWithRunLoop
                     IOHIDManagerSetDeviceMatching  IORegistryEntryGetRegistryEntryID
CoreFoundation  (6)  CFRunLoopGetMain  CFRunLoopRun  CFRunLoopRunInMode
                     kCFAllocatorDefault  kCFRunLoopCommonModes  kCFRunLoopDefaultMode
objc runtime    (6)  objc_msgSend  objc_allocWithZone  objc_opt_self  objc_release
                     objc_retain  objc_retainAutoreleasedReturnValue
Accessibility   (3)  AXIsProcessTrusted  AXIsProcessTrustedWithOptions
                     kAXTrustedCheckOptionPrompt
libc            (7)  bzero  exit  fflush  malloc_size  memcpy  memmove  signal
```

That is everything. There is no `socket`, no `connect`, no `CFNetwork`, no
`NSURLSession`, no `SCDynamicStore`, and no hostname, serial-number or
MAC-address API anywhere in the binary.

| | XP-Pen 4.0.18 | InkDriver |
| --- | --- | --- |
| Network APIs imported | yes: `JsonServer`, `UpdateServer`, `Download` | **none** |
| Endpoints present in the code | `data.tr.x-pen.com.cn:2005/receive/data`, `driverinfo.xp-pen.com.cn/api/ping` | **none** |
| Data-collection path | present: MAC address, OS version, display layout and per-app config changes | **no such code** |
| Enabled out of the box | no. Off, gated in three places, needs a `dataconfig.ini` that is not shipped | n/a |
| Event tap installed | yes (its mask excludes key-down/key-up, so it cannot log keystrokes) | **no tap at all** |
| Update mechanism | phones home on a schedule | none; `git pull` |
| Telemetry you can audit | only by disassembling | read the source |
| Licence | proprietary | **GPL-3.0-or-later** |

To be fair to the vendor: the collection path is **off by default** and inert in
this build, and the event tap cannot read keystrokes, both verified in
`docs/` of the analysis this driver came out of. The point is not that XP-Pen is
doing something sinister. It is that the code is there, closed, and only a
disassembly can tell you what it does, while here there is nothing to disassemble.

<details>
<summary>Verify it yourself</summary>

```sh
# 278 imported symbols in total:
otool -Iv .build/release/xpdriverd | grep '^0x' | awk '{print $NF}' | sed 's/^_//' | sort -u | wc -l

# The 48 Apple API entry points (drop Swift runtime and compiler helpers):
otool -Iv .build/release/xpdriverd | grep '^0x' | awk '{print $NF}' | sed 's/^_//' \
  | grep -vE '^\$|^swift_|^_swift|^__|^_Block|^_NSConcrete|^LOCAL' | sort -u

# Prove there is no network or host-identity API:
otool -Iv .build/release/xpdriverd | grep -icE 'socket|connect|CFNetwork|NSURLSession|SCDynamicStore|gethostuuid|IOPlatformSerialNumber'   # 0

# Prove no event tap is created:
otool -Iv .build/release/xpdriverd | grep -c CGEventTapCreate   # 0

# Only Apple frameworks are linked, and no third-party dylib:
otool -L .build/release/xpdriverd
```
</details>

---

## Diagnostics

| | XP-Pen | InkDriver |
| --- | --- | --- |
| Always-on diagnostic process | `PenTabletInfo.app`, plus `XTouchDriver.app` | none |
| GUI ships a "Diagnosis Tool" | yes (`Diagnosis`, `CollectDataChecked`, `diagnosis_*`) | no |
| What this repo ships instead | none | `xppen-probe`: a read-only tool you run by hand, which prints to your terminal and exits |

---

## Features

| | XP-Pen 4.0.18 | InkDriver |
| --- | :---: | :---: |
| Pen position, pressure, tilt | ✅ | ✅ |
| Both barrel buttons | ✅ | ✅ |
| 8 express keys, rebindable | ✅ | ✅ |
| Keyboard-shortcut actions | ✅ | ✅ |
| Wheel / scroll mode | ✅ | ✅ |
| Active-area mapping | ✅ | ✅ |
| Keep-proportions ("screen ratio") mode | ✅ | ✅ |
| Custom screen area | ✅ | ✅ |
| Rotation, invert axes | ✅ | ✅ |
| Multiple monitors, per-display settings | ✅ | ✅ |
| Switch display from a bound key | ✅ | ✅ |
| Visual monitor-layout editor | ✅ | ✅ |
| Headless CLI driver | ✅ | ✅ |
| Menu-bar app with settings | ✅ | ✅ |
| JSON config | ❌ (proprietary XML) | ✅ |
| Busy indicator / battery readout | ✅ | ❌ |
| Per-application profiles | ✅ | ❌ |
| Screen calibration | ✅ | ❌ |
| Touch ring / Express wheel | ✅ (other models) | ❌ (not on this tablet) |
| Touch gestures | ✅ (`XTouchDriver`) | ❌ (not on this tablet) |
| Wireless / BLE | ✅ (other models) | ❌ (this tablet is wired) |
| Supports ~120 tablet models | ✅ | ❌ (this one) |
| Self-updating | ✅ | ❌ (by design) |
| Source available | ❌ | ✅ (GPL-3.0-or-later) |
| Auditable without a disassembler | ❌ | ✅ |

### What the vendor does that we don't

Being straight about the gaps:

- **Per-application profiles.** The vendor's `config.xml` has per-app sections, so
  a shortcut can differ in Photoshop and Krita. InkDriver has no such thing yet.
- **Battery and LED readout.** The vendor has `GetTabletBattary` and
  `SetControlTabletLight`. Not implemented here.
- **Screen calibration** (`SendScreenCalibrate`).
- **Model coverage.** One tablet versus a catalogue.
- **A GUI that records keys by clicking.** You can edit bindings here, but
  recording an arbitrary shortcut is a text field, not a click-and-press dialog.

### What we do that the vendor doesn't

- **~4,400 lines of readable Swift** instead of a 27 MB Qt binary.
- **No network code at all**. Not "disabled", absent.
- **Sub-megabyte install**, and nothing left behind after `make uninstall-agent`.
- **Your config is a JSON file** you can version, copy between machines and diff.
- **Wheel mode that is 1:1.** Hold a key, move the pen, and it scrolls exactly as
  far as your hand moved, with the sub-pixel remainder carried so slow
  movement still accumulates.
- **Honest defaults:** express keys do nothing until you assign them.

---

## Where the numbers came from

| Claim | Evidence |
| --- | --- |
| Report layout, pressure is 14-bit, tilt ±60, express-key bitmask | measured with `xppen-probe`, cross-checked against the vendor's `CTablet::OnPostTabletMouseData`. See [PROTOCOL.md](docs/PROTOCOL.md) |
| Event injection is correct | verified end to end in a plain AppKit application: drawing with the pen produces ink at `subtype=1` with real pressure |
| Mapping maths | `xppen-probe --check-workspace` prints all four corners for every mode, plus rotations and display-ID migration |
| Config parser | `xppen-probe --check-bindings` |
| Vendor endpoints and gating | static analysis of the shipped binaries; quoted in the summary above |
| Vendor sizes | the commands in the collapsed blocks |
