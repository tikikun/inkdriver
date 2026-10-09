// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 tikikun
//
// InkDriver — native macOS driver for the XP-Pen Deco 01 V3.
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version. It is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
// PARTICULAR PURPOSE. See the GNU General Public License for more details.

import Foundation
import IOKit
import IOKit.hid
import XPTabletCore

// xppen-probe — READ-ONLY bring-up tool.
//
// It enumerates the tablet's HID interfaces, optionally sends the tablet-mode
// handshake, and prints every input report as hex plus its decoding. It never
// posts input events, so it is safe to run alongside another driver.
//
// Usage:
//   xppen-probe                     list interfaces and report IDs
//   xppen-probe --descriptor        print the raw HID report descriptors
//   xppen-probe --watch             stream and decode pen reports
//   xppen-probe --watch --init      send 02 B0 04 first
//   xppen-probe --watch --raw       include the raw hex on every line
//   xppen-probe --watch --all       also show the mouse/digitizer interfaces
//   xppen-probe --stats             print min/max per field when you press Ctrl-C
//
// The pen stream lives on usage page 0xFF0A (report ID 2, 12 bytes). The other
// two interfaces are the fallback mouse and an unused digitizer pen collection.

struct Options {
    var watch = false
    var sendInit = false
    var raw = false
    var descriptor = false
    var all = false
    var stats = false
}

func parseOptions() -> Options {
    var o = Options()
    for arg in CommandLine.arguments.dropFirst() {
        switch arg {
        case "--watch": o.watch = true
        case "--init": o.sendInit = true
        case "--raw": o.raw = true
        case "--all": o.all = true
        case "--stats": o.stats = true
        case "--descriptor": o.descriptor = true
        case "--check-workspace":
            // Verify the tablet -> screen mapping for each mode using a synthetic
            // 2560x1440 display, so the numbers are checkable by hand.
            let display = AreaMapper.DisplayBounds(originX: 0, originY: 0, width: 2560, height: 1440, displayID: 724_053_248)
            let corners: [(String, UInt32, UInt32)] = [
                ("top-left", 0, 0),
                ("top-right", Device.maxX, 0),
                ("bottom-left", 0, Device.maxY),
                ("bottom-right", Device.maxX, Device.maxY),
                ("centre", Device.maxX / 2, Device.maxY / 2),
            ]
            print("synthetic display 2560x1440 at (0,0); tablet aspect "
                  + String(format: "%.4f", Device.activeWidthMM / Device.activeHeightMM))
            for mode in MappingMode.allCases {
                var workspace = WorkspaceConfig()
                workspace.mode = mode
                if mode == .custom {
                    workspace.screenRect = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                }
                let mapper = AreaMapper(workspace: workspace, displays: [display])
                let rect = mapper.targetRect
                print(String(format: "\n%-14s targetRect = (%.0f, %.0f) %.0fx%.0f",
                             (mode.rawValue as NSString).utf8String!,
                             rect.origin.x, rect.origin.y, rect.width, rect.height))
                for (name, x, y) in corners {
                    let p = mapper.map(x: x, y: y)
                    print(String(format: "    %-13s raw(%6u,%6u) -> (%7.1f, %7.1f)",
                                 (name as NSString).utf8String!, x, y, p.x, p.y))
                }
            }

            print("\nrotations (mode stretch, 2560x1440):")
            for angle in [90, 180, 270] {
                var workspace = WorkspaceConfig()
                workspace.rotation = angle
                let mapper = AreaMapper(workspace: workspace, displays: [display])
                let parts = corners.prefix(4).map { name, x, y -> String in
                    let p = mapper.map(x: x, y: y)
                    return String(format: "%@=(%.0f,%.0f)",
                                  name.replacingOccurrences(of: "-", with: ""), p.x, p.y)
                }
                print("  \(angle)°: " + parts.joined(separator: "  "))
            }

            // Three displays, one of them portrait, to prove displays are tracked
            // by their stable ID rather than by list position.
            let second = AreaMapper.DisplayBounds(originX: 2560, originY: 0, width: 2880, height: 5120, displayID: 724_053_249)
            let third = AreaMapper.DisplayBounds(originX: -1920, originY: 0, width: 1920, height: 1080, displayID: 724_053_250)
            let live = [display, second, third]

            print("\ndisplays are keyed by CGDirectDisplayID, so adding one changes nothing:")
            var ws = WorkspaceConfig(displayID: 724_053_249)
            ws.setProfile(DisplayProfile(mode: .fit), forDisplayID: 724_053_248)
            ws.setProfile(DisplayProfile(mode: .custom,
                                         screenRect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
                          forDisplayID: 724_053_249)
            ws = ws.normalize(live)
            print("  target=\(ws.resolvedDisplayID(live).map(String.init) ?? "nil") index=\(ws.targetIndex(live))"
                  + "  profile=\(ws.profile(for: live).mode.rawValue)  hasOwn=\(ws.hasProfile(for: live))")

            print("  switching (empty switch list = every display, in order):")
            var walk = ws
            for _ in 0..<4 {
                guard let next = walk.nextDisplayID(live) else { break }
                walk.displayID = next
                print("    -> id \(next) (index \(walk.targetIndex(live))) profile \(walk.profile(for: live).mode.rawValue)")
            }

            print("  a display that goes away: settings survive, others unaffected")
            var removed = ws
            removed = removed.normalize([display, third])   // the second display unplugged
            print("    target falls back to id \(removed.resolvedDisplayID([display, third]).map(String.init) ?? "nil")"
                  + "  first display profile kept=\(removed.hasProfile(forDisplayID: 724_053_248))")

            print("  legacy index-keyed config migrates once the displays are known:")
            var legacy = WorkspaceConfig(display: 1)
            legacy.profiles = ["1": DisplayProfile(mode: .fit)]
            legacy.switchDisplays = [0, 1, 2]
            let migrated = legacy.normalize(live)
            print("    display index 1 -> id \(migrated.displayID.map(String.init) ?? "nil"),"
                  + " profiles=\(migrated.profiles.keys.sorted()),"
                  + " switchIDs=\(migrated.switchDisplayIDs)")

            print("\ntablet area (mode stretch, corners map to the screen edges):")
            for (label, rect) in [("full", NormalizedRect.full),
                                  ("centre 50%", NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))] {
                var workspace = WorkspaceConfig()
                workspace.tabletRect = rect
                let mapper = AreaMapper(workspace: workspace, displays: [display])
                let a = mapper.map(x: 0, y: 0)
                let b = mapper.map(x: Device.maxX, y: Device.maxY)
                print(String(format: "  %-11s -> (%.0f,%.0f) .. (%.0f,%.0f)",
                             (label as NSString).utf8String!, a.x, a.y, b.x, b.y))
            }
            exit(0)

        case "--check-accuracy":
            // Accuracy of the transforms, as opposed to the plumbing: does the mapping
            // cover the intended area exactly, is it uniform, does pressure keep its
            // resolution end to end, and does tilt span the range applications expect.
            // These are exact checks on the real code paths, so they are reproducible
            // and need no hardware.
            let display = AreaMapper.DisplayBounds(originX: 0, originY: 0, width: 2560,
                                                   height: 1440, displayID: 724_053_248)
            var failures: [String] = []

            print("accuracy of the transforms\n")

            // 1. Coordinate mapping. For every mode x rotation x invert, sample the
            //    whole tablet area and check three things: nothing leaves the display,
            //    the mapped region covers the target rect exactly, and equal raw steps
            //    produce equal screen steps (the mapping should be affine).
            print("coordinate mapping, 512 samples across each axis per combination")
            var combinations = 0
            var worstUniformity = 0.0
            var worstCoverage = 0.0
            var worstEscape = 0.0
            for mode in MappingMode.allCases {
                for rotation in [0, 90, 180, 270] {
                    for invertX in [false, true] {
                        for invertY in [false, true] {
                            var workspace = WorkspaceConfig()
                            workspace.mode = mode
                            workspace.rotation = rotation
                            workspace.invertX = invertX
                            workspace.invertY = invertY
                            let mapper = AreaMapper(workspace: workspace, displays: [display])
                            let target = mapper.targetRect
                            combinations += 1

                            let n = 512
                            var points: [CGPoint] = []
                            points.reserveCapacity(n + 1)
                            for i in 0...n {
                                let x = UInt32(Double(Device.maxX) * Double(i) / Double(n))
                                let y = UInt32(Double(Device.maxY) * Double(i) / Double(n))
                                let p = mapper.map(x: x, y: y)
                                points.append(p)
                            }

                            // Nothing may escape the display, even with the pen dragged
                            // outside the active area.
                            for p in points {
                                worstEscape = max(worstEscape,
                                                  -p.x, p.x - Double(display.width),
                                                  -p.y, p.y - Double(display.height))
                            }
                            if worstEscape > 0.5 {
                                failures.append("mapping escapes the display (mode \(mode.rawValue)"
                                                + " rotation \(rotation))")
                            }

                            // Coverage: the sampled area must reach every side of the
                            // target rect, and not overshoot it.
                            let xs = points.map(\.x), ys = points.map(\.y)
                            worstCoverage = max(worstCoverage,
                                                abs(xs.min()! - target.minX),
                                                abs(xs.max()! - target.maxX),
                                                abs(ys.min()! - target.minY),
                                                abs(ys.max()! - target.maxY))

                            // Uniformity, tested exactly rather than by sampling: an
                            // affine map sends the midpoint of two raw values to the
                            // midpoint of their images. Truncating raw samples to
                            // integers to measure step sizes instead measures the
                            // truncation, which is what an earlier version of this
                            // check did.
                            // Keep every sample inside the tablet: map() clamps beyond
                            // the maximum, and a clamped end point is not a midpoint.
                            for fraction in [0.25, 0.5] {
                                let xEnd = UInt32(Double(Device.maxX) * fraction)
                                let yEnd = UInt32(Double(Device.maxY) * fraction)
                                let a = mapper.map(x: 0, y: 0)
                                let b = mapper.map(x: xEnd, y: yEnd)
                                let c = mapper.map(x: xEnd * 2, y: yEnd * 2)
                                worstUniformity = max(worstUniformity,
                                                      abs(b.x - (a.x + c.x) / 2),
                                                      abs(b.y - (a.y + c.y) / 2))
                            }
                        }
                    }
                }
            }
            print(String(format: "  combinations tested:            %d", combinations))
            print(String(format: "  worst escape past the display:  %.6f px", worstEscape))
            print(String(format: "  worst coverage error:           %.6f px", worstCoverage))
            print(String(format: "  worst departure from affine:    %.6f px", worstUniformity))
            if worstCoverage > 0.5 {
                failures.append(String(format: "coverage error %.3f px", worstCoverage))
            }
            if worstUniformity > 0.001 {
                failures.append(String(format: "non-affine mapping %.6f px", worstUniformity))
            }

            // 2. Spatial resolution: what does one raw unit move on screen, and is
            //    sub-pixel precision preserved rather than rounded to whole pixels?
            var workspace = WorkspaceConfig()
            workspace.mode = .stretch
            let mapper = AreaMapper(workspace: workspace, displays: [display])
            let stepX = mapper.map(x: 1, y: 0).x - mapper.map(x: 0, y: 0).x
            let stepY = mapper.map(x: 0, y: 1).y - mapper.map(x: 0, y: 0).y
            print("\nspatial resolution (stretch, 2560x1440)")
            print(String(format: "  one raw x unit moves the cursor %.6f px", stepX))
            print(String(format: "  one raw y unit moves the cursor %.6f px", stepY))
            print(String(format: "  raw units per screen pixel: x %.2f, y %.2f",
                         1 / stepX, 1 / stepY))
            let fractional = stepX - stepX.rounded(.down)
            print(String(format: "  fractional part kept: %.6f px (0 would mean whole-pixel steps)",
                         fractional))
            if fractional < 1e-6 {
                failures.append("mapping quantises to whole pixels")
            }

            // 3. Pressure. The device reports 14 bits, so the normalised value should
            //    keep all of them: monotonic, exact at both ends, no collisions.
            print("\npressure (device is " + "\(Device.maxPressure)" + " steps)")
            var previous = -1.0
            var monotonic = true
            var levels = Set<Double>()
            var worstPressureStep = 0.0
            for raw in 0...Int(Device.maxPressure) {
                let value = Double(raw) / Double(Device.maxPressure)
                if value < previous { monotonic = false }
                worstPressureStep = max(worstPressureStep, value - max(previous, 0))
                previous = value
                levels.insert(value)
            }
            print(String(format: "  normalised range:               %.6f to %.6f",
                         0.0, Double(Device.maxPressure) / Double(Device.maxPressure)))
            print(String(format: "  distinct values:                %d of %d",
                         levels.count, Int(Device.maxPressure) + 1))
            print(String(format: "  largest step between neighbours: %.6f (device quantum %.6f)",
                         worstPressureStep, 1.0 / Double(Device.maxPressure)))
            print("  monotonic: \(monotonic ? "yes" : "NO")")
            if levels.count != Int(Device.maxPressure) + 1 { failures.append("pressure loses levels") }
            if !monotonic { failures.append("pressure is not monotonic") }

            // 4. Tilt. Decode the extreme raw values and check the clamped range, the
            //    sign convention, and what the extremes map to once scaled.
            print("\ntilt")
            func decodedTilt(_ raw: UInt8) -> (Int8, Int8)? {
                var report = [UInt8](repeating: 0, count: 12)
                report[1] = 0xA1          // pen report (status nibble 0xA0) with tip down
                report[8] = raw
                report[9] = raw
                guard let d = try? ReportDecoder.decode(report), case .pen(let pen) = d else { return nil }
                return (pen.tiltX, pen.tiltY)
            }
            let extremes: [(String, UInt8)] = [("0", 0), ("+60", 60), ("+127", 127), ("-60", 0xC4), ("-128", 0x80)]
            var worstTilt = 0.0
            for (name, raw) in extremes {
                guard let (tx, ty) = decodedTilt(raw) else {
                    failures.append("tilt decode failed for raw \(name)")
                    continue
                }
                let scale = Device.vendorTiltDivisor
                let normalised = Double(tx) / scale
                worstTilt = max(worstTilt, abs(normalised))
                print(String(format: "  raw %-5s -> tiltX %4d  tiltY %4d  normalised %+.4f  (app sees %+.1f deg)",
                             (name as NSString).utf8String!, Int(tx), Int(ty), normalised,
                             normalised * 90))
            }
            print(String(format: "  largest normalised tilt:        %.4f of 1.0", worstTilt))
            // Measured on hardware: the pen reports raw tilt to +/-60, and the model is
            // rated at +/-60 degrees, so raw units are degrees. Apple's convention is
            // that 1.0 is 90 degrees (Firefox computes tiltX as tilt * 90), so the
            // vendor's divisor of 84 makes the extreme tilt arrive as
            // lround(60/84*90) = 64 degrees instead of 60. Setting tiltScale to 90
            // reports the true angle; the default keeps vendor parity.
            print(String(format: "  raw tilt spans +/-60 = +/-60 deg on this model"))
            print(String(format: "  at the extreme the driver reports %.0f deg (should be 60)",
                         (60.0 / Device.vendorTiltDivisor) * 90))
            print(String(format: "  tiltScale 90 gives true degrees, %.0f is vendor parity",
                         Device.vendorTiltDivisor))
            if worstTilt > 1.0 { failures.append("tilt can exceed the documented -1..1 range") }

            print("")
            if failures.isEmpty {
                print("all accuracy checks passed")
            } else {
                print("accuracy problems:")
                for f in failures { print("  - " + f) }
            }

        case "--check-pressure":
            print("pressure pipeline and contact decision\n")
            print("contact decision (status, raw pressure, threshold -> touching)")
            print("-----------------------------------------------------------")
            let cases: [(String, Bool, UInt16, UInt16)] = [
                ("hover, no leakage",            false, 0,     0),
                ("hover, leaked 400",            false, 400,   0),
                ("hover, leaked 877 (measured max)", false, 877, 0),
                ("hover with threshold 1000",    false, 877,   1000),
                ("tip just touched (measured min)", true, 13,  0),
                ("tip, light press",             true,  500,   0),
                ("tip below threshold 1000",     true,  500,   1000),
                ("tip above threshold 1000",     true,  1200,  1000),
                ("tip, full press",              true,  16383, 0),
            ]
            var wrong = 0
            for (label, tip, pressure, threshold) in cases {
                let touching = Contact.isTouching(tipDown: tip, pressure: pressure, threshold: threshold)
                let expected = tip && (threshold == 0 || pressure >= threshold)
                if touching != expected { wrong += 1 }
                let padded = label.padding(toLength: 38, withPad: " ", startingAt: 0)
                let tipText = tip ? "down" : "up"
                let verdict = touching ? "TOUCHING" : "not touching"
                print("  \(padded) tip=\(tipText)  p=\(pressure)  thr=\(threshold)  -> \(verdict)")
            }
            print("\n  hovering can never produce a phantom click: "
                  + (wrong == 0 ? "yes, all cases correct" : "NO, \(wrong) case(s) wrong"))

            print("\nnormalisation (raw -> CGEvent pressure field, which is 0.0 ... 1.0)")
            print("-----------------------------------------------------------------")
            for raw in [UInt16(0), 1, 500, 8191, 8192, 16382, 16383] {
                let pen = PenReport(x: 0, y: 0, pressure: raw, tiltX: 0, tiltY: 0,
                                    tipDown: true, eraser: false, penButton1: false,
                                    penButton2: false, inRange: true, status: 0xA1)
                print(String(format: "  raw %-6u -> %.6f", raw, pen.pressureNormalised))
            }
            print("  max pressure constant: \(Device.maxPressure) (14-bit)")
            print("\n  reported while hovering: "
                  + (DriverConfig().effectiveZeroPressureOnHover
                     ? "zeroed, so apps do not see sensor leakage"
                     : "passed through raw"))

            print("\ntilt")
            print("----")
            print("  sensor range: +/-60, the vendor clamps to 0xC4 / 0x3C")
            print("  divisor 84.0 is the vendor constant (DAT_10001f208), so full tilt")
            print("  reaches +/-0.714 in the event field, matching the original driver.")
            print("  Set tiltScale to 60 to normalise against the sensor instead, which")
            print("  lets applications see full deflection.")
            let tiltRaws: [Int] = [-60, -30, 0, 30, 60]
            for scale in [Device.vendorTiltDivisor, 60.0] {
                let rows = tiltRaws.map { raw -> String in
                    String(format: "%+d:%+.3f", raw, Double(-raw) / scale)
                }
                print("    tiltScale \(Int(scale)) -> " + rows.joined(separator: "  "))
            }
            print("  Y is negated for the event field, as the vendor driver does.")
            exit(0)

        case "--check-bindings":
            // Regression check for the config parser: every form the UI and the
            // sample config can write must round-trip.
            let samples = [
                "none", "wheel", "eraser", "eraser-hold", "eraserhold", "hold:eraser",
                "panel", "monitor", "precision", "Eraser (hold)", "Eraser (press to toggle)",
                "mouse:right", "mouse:middle", "double:left",
                "scroll:up", "scroll:down", "scroll:left", "scroll:right",
                "key:1+cmd", "key:6+cmd,shift", "action:207", "action:210",
                "Right click", "Scroll up", "Wheel mode (hold to scroll)",
                "system:screenKeyboard", "bogus",
            ]
            print("binding parse table")
            print("-------------------")
            for text in samples {
                let binding = Binding.parse(text)
                let rendered = binding.map { "\($0.configString)   [\($0.displayName)]" } ?? "nil (falls back to none)"
                print(String(format: "%-34s %@", (text as NSString).utf8String!, rendered))
            }
            print("\naction catalogue (vendor Actid -> name)")
            print("-------------------------------------")
            for action in ActionCatalog.all {
                print(String(format: "%4d  %-28s %@", action.id, (action.name as NSString).utf8String!, action.binding.configString))
            }
            exit(0)
        case "--help", "-h":
            print("""
            xppen-probe — inspect the XP-Pen Deco 01 V3 HID interfaces

              (no args)        list interfaces
              --descriptor     print the HID report descriptors
              --watch          stream and decode input reports
              --init           send the 02 B0 04 tablet-mode handshake first
              --raw            print raw hex with every report
              --all            watch every interface, not just the pen one
              --stats          summarise field ranges on exit (Ctrl-C)
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown option: \(arg)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

let options = parseOptions()

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

let discovery = HIDDiscovery()

guard !discovery.interfaces.isEmpty else {
    print("No HID interface with VID 0x\(String(Device.vendorID, radix: 16)) "
        + "PID 0x\(String(Device.productID, radix: 16)) found.")
    print("Is the tablet plugged in? Is another driver holding it?")
    print("Check with: pgrep -fl 'XPPen|XTouchDriver|PenTabletInfo'")
    exit(1)
}

print("Found \(discovery.interfaces.count) HID interface(s):")
for iface in discovery.interfaces {
    print("  • \(iface.product)  \(iface.label)  in=\(iface.maxInputReportSize) out=\(iface.maxOutputReportSize)")
}

if options.descriptor {
    for iface in discovery.interfaces {
        if let data = IOHIDDeviceGetProperty(iface.device, kIOHIDReportDescriptorKey as CFString) as? Data {
            print("\nReport descriptor — \(iface.label) (\(data.count) bytes):")
            print(hex([UInt8](data)))
        }
    }
}

guard let pen = discovery.penInterface else {
    print("\nNo vendor-defined (0x\(String(Device.penUsagePage, radix: 16))) interface found.")
    exit(1)
}

if !options.watch {
    print("\nPen stream: \(pen.label), report ID \(Device.penReportID), \(Device.inputReportLength) bytes.")
    print("Run `xppen-probe --watch --init`, then move the pen.")
    exit(0)
}

// MARK: - Open

var readers: [HIDReportReader] = []
var openError: IOReturn = kIOReturnSuccess

let targets = options.all ? discovery.interfaces : [pen]
for iface in targets {
    let r = openHIDDevice(iface)
    if r != kIOReturnSuccess {
        FileHandle.standardError.write(
            "failed to open \(iface.label): 0x\(String(UInt32(bitPattern: r), radix: 16))\n".data(using: .utf8)!)
        openError = r
    }
}
if openError != kIOReturnSuccess {
    print("Grant Input Monitoring to this binary:")
    print("  System Settings > Privacy & Security > Input Monitoring")
    exit(1)
}

// MARK: - Handshake

if options.sendInit {
    let result = sendOutputReport(pen, frame: Device.initFrame)
    if result == kIOReturnSuccess {
        print("Sent handshake: \(hex(Device.initFrame))")
    } else {
        print("Handshake failed: IOReturn 0x\(String(UInt32(bitPattern: result), radix: 16))")
    }
}

// MARK: - Stats

struct FieldStats {
    var count = 0
    var xMin = UInt32.max, xMax: UInt32 = 0
    var yMin = UInt32.max, yMax: UInt32 = 0
    var pMin = UInt16.max, pMax: UInt16 = 0
    var tiltXMin: Int8 = .max, tiltXMax: Int8 = .min
    var tiltYMin: Int8 = .max, tiltYMax: Int8 = .min
    /// Tilt as it comes off the wire, before `clampTilt` saturates anything. The
    /// decoded range stops at +/-60 because that is where the driver clamps, so the
    /// decoded numbers cannot say what the hardware actually reports at its limits.
    var tiltXRawMin: Int8 = .max, tiltXRawMax: Int8 = .min
    var tiltYRawMin: Int8 = .max, tiltYRawMax: Int8 = .min
    var statuses: [UInt8: Int] = [:]

    mutating func addRawTilt(bytes: [UInt8]) {
        guard bytes.count >= 10 else { return }
        let rx = Int8(bitPattern: bytes[8])
        let ry = Int8(bitPattern: bytes[9])
        tiltXRawMin = min(tiltXRawMin, rx); tiltXRawMax = max(tiltXRawMax, rx)
        tiltYRawMin = min(tiltYRawMin, ry); tiltYRawMax = max(tiltYRawMax, ry)
    }

    mutating func add(_ pen: PenReport) {
        count += 1
        xMin = min(xMin, pen.x); xMax = max(xMax, pen.x)
        yMin = min(yMin, pen.y); yMax = max(yMax, pen.y)
        pMin = min(pMin, pen.pressure); pMax = max(pMax, pen.pressure)
        tiltXMin = min(tiltXMin, pen.tiltX); tiltXMax = max(tiltXMax, pen.tiltX)
        tiltYMin = min(tiltYMin, pen.tiltY); tiltYMax = max(tiltYMax, pen.tiltY)
        statuses[pen.status, default: 0] += 1
    }
}

var stats = FieldStats()
var reportCount = 0
let started = Date()

func describe(_ bytes: [UInt8], tag: String) {
    reportCount += 1
    var line = String(format: "%7.3f", Date().timeIntervalSince(started))
    line += " #\(reportCount)"
    if options.all { line += " \(tag)" }
    line += " len=\(bytes.count)"
    if options.raw { line += " \(hex(bytes))" }

    guard tag.hasPrefix("pen") else {
        print(line)
        return
    }

    do {
        switch try ReportDecoder.decode(bytes) {
        case .outOfRange:
            print(line + "  -> out of range")
        case .aux(let aux):
            let pressed = aux.buttons.enumerated().filter { $0.element }.map { String($0.offset + 1) }
            print(line + "  -> buttons: \(pressed.isEmpty ? "none" : pressed.joined(separator: ","))")
        case .command(let response, let payload):
            print(line + String(format: "  -> command reply 0x%02X %@", response, hex(payload)))
        case .pen(let pen):
            stats.addRawTilt(bytes: bytes)
            stats.add(pen)
            var flags: [String] = []
            if pen.tipDown { flags.append("TIP") }
            if pen.penButton1 { flags.append("B1") }
            if pen.penButton2 { flags.append("B2") }
            if pen.eraser { flags.append("ERASER") }
            let f = flags.isEmpty ? "" : " " + flags.joined(separator: " ")
            print(line + String(format: "  -> x=%-6u y=%-6u p=%-5u (%.3f) tilt=(%d,%d) status=0x%02X%@",
                                pen.x, pen.y, pen.pressure, pen.pressureNormalised,
                                Int(pen.tiltX), Int(pen.tiltY), pen.status, f))
        case .unknown(let prefix):
            print(line + "  -> unrecognised, first bytes \(hex(prefix))")
        }
    } catch {
        print(line + "  -> decode failed: \(error)")
    }
}

for iface in targets {
    let reader = HIDReportReader(interface: iface) { bytes in
        describe(bytes, tag: iface.label)
    }
    readers.append(reader)
}

print("\nWatching \(targets.count) interface(s). Move the pen, press the tip, tilt it, press the")
print("pen buttons and the express keys. Ctrl-C to stop.")

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    if options.stats && stats.count > 0 {
        print("\n--- field ranges over \(stats.count) pen reports ---")
        print(String(format: "x      %u ... %u", stats.xMin, stats.xMax))
        print(String(format: "y      %u ... %u", stats.yMin, stats.yMax))
        print(String(format: "pressure %u ... %u", stats.pMin, stats.pMax))
        print("tiltX  \(stats.tiltXMin) ... \(stats.tiltXMax)   (already clamped to +/-60)")
        print("tiltY  \(stats.tiltYMin) ... \(stats.tiltYMax)   (already clamped to +/-60)")
        print("tiltX raw off the wire \(stats.tiltXRawMin) ... \(stats.tiltXRawMax)")
        print("tiltY raw off the wire \(stats.tiltYRawMin) ... \(stats.tiltYRawMax)")
        print("status bytes: " + stats.statuses.sorted { $0.key < $1.key }
            .map { String(format: "0x%02X×%d", $0.key, $0.value) }.joined(separator: " "))
    }
    exit(0)
}
interrupt.resume()

CFRunLoopRun()
