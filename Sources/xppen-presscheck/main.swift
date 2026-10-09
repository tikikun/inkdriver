// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 tikikun
//
// InkDriver: native macOS driver for the XP-Pen Deco 01 V3.
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version. It is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
// PARTICULAR PURPOSE. See the GNU General Public License for more details.

import AppKit
import XPTabletCore

// xppen-presscheck
//
// Answers one question: do applications actually receive pen pressure?
//
// `xppen-tapcheck` reads raw CoreGraphics event fields, which is not the same
// thing. Applications, and every browser, see an `NSEvent`: AppKit translates the
// CGEvent first, and that translation is where tablet data can quietly go missing.
// A web drawing app such as tldraw reads `PointerEvent.pressure` and
// `PointerEvent.pointerType`, both derived from the NSEvent.
//
// So this posts a controlled pressure ramp through the driver's injection path and
// reports what AppKit hands to a real view. `--mouse-pressure` additionally sets
// kCGMouseEventPressure, to show which field AppKit's `NSEvent.pressure` reads.

struct Received {
    let typeRaw: UInt
    let subtype: NSEvent.EventSubtype
    let pressure: Double
    let tilt: NSPoint
    let location: NSPoint
}

final class ProbeView: NSView {
    var onEvent: ((Received, String) -> Void)?

    private func record(_ event: NSEvent, _ callback: String) {
        onEvent?(Received(typeRaw: event.type.rawValue,
                          subtype: event.subtype,
                          pressure: Double(event.pressure),
                          tilt: NSPoint(x: Double(event.tilt.x), y: Double(event.tilt.y)),
                          location: event.locationInWindow), callback)
    }

    override func mouseMoved(with event: NSEvent) { record(event, "mouseMoved") }
    override func mouseDragged(with event: NSEvent) { record(event, "mouseDragged") }
    override func mouseDown(with event: NSEvent) { record(event, "mouseDown") }
    override func mouseUp(with event: NSEvent) { record(event, "mouseUp") }
    // These two are what Firefox's ChildView implements. If AppKit never calls
    // tabletProximity:, Firefox never learns a pen is present.
    override func tabletPoint(with event: NSEvent) { record(event, "tabletPoint:") }
    override func tabletProximity(with event: NSEvent) { record(event, "tabletProximity:") }
}

func typeName(_ raw: UInt) -> String {
    switch Int(raw) {
    case 1: return "leftMouseDown"
    case 2: return "leftMouseUp"
    case 5: return "mouseMoved"
    case 6: return "leftMouseDragged"
    case 23: return "tabletPoint"
    case 24: return "tabletProximity"
    default: return "type(\(raw))"
    }
}

// MARK: - Setup

let withMousePressure = !CommandLine.arguments.contains("--no-mouse-pressure")
// --watch: post nothing, just report everything that arrives. Used to compare
/// against another driver (for example the vendor's) with identical observation.
let watchMode = CommandLine.arguments.contains("--watch")

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.title = "xppen-presscheck"
window.level = .floating
window.acceptsMouseMovedEvents = true
if watchMode {
    // Cover everything. Another driver moves the cursor with the pen, so a small
    // window would be left behind and the events would go to whatever is under it.
    let union = NSScreen.screens.dropFirst().reduce(NSScreen.screens.first?.frame ?? .zero) { $0.union($1.frame) }
    window.setFrame(union, display: true)
    window.styleMask = [.borderless]
} else {
    window.center()
}
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

let view = ProbeView(frame: window.contentLayoutRect)
window.contentView = view
// AppKit dispatches tabletProximity: down the responder chain, so the view has to
// be in it. Without this the view never sees a proximity event even when the
// application does, which is what Firefox's ChildView relies on.
window.makeFirstResponder(view)

var received: [Received] = []
var receivedVia: [String] = []
var nativeAvailable = false
var nativeResult: Int32 = -999
// A local monitor sees the event as it enters the application, independently of
// the responder chain, so it answers "did AppKit deliver this at all".
var monitored: [Received] = []
func describeEvent(_ event: NSEvent) -> String {
    let tablet = event.subtype == .tabletPoint || event.subtype == .tabletProximity
    var line = "  \(typeName(event.type.rawValue).padding(toLength: 16, withPad: " ", startingAt: 0))"
        + " type=\(event.type.rawValue) sub=\(event.subtype.rawValue)"
        + " p=\(String(format: "%.4f", Double(event.pressure)))"
    if tablet {
        line += " | SOURCE=\(event.pointingDeviceType.rawValue)"
            + " cap=0x\(String(event.capabilityMask, radix: 16))"
            + " vid=\(event.vendorID) tid=\(event.tabletID) did=\(event.deviceID)"
            + " sysTablet=\(event.systemTabletID) ptrID=\(event.pointingDeviceID)"
            + " entering=\(event.isEnteringProximity)"
        line += "   <-- TABLET"
    }
    return line
}
NSEvent.addLocalMonitorForEvents(matching: [.tabletPoint, .tabletProximity, .mouseMoved,
                                            .leftMouseDown, .leftMouseUp, .leftMouseDragged]) { event in
    if !watchMode { print(describeEvent(event)) }
    monitored.append(Received(typeRaw: event.type.rawValue, subtype: event.subtype,
                              pressure: Double(event.pressure),
                              tilt: NSPoint(x: Double(event.tilt.x), y: Double(event.tilt.y)),
                              location: event.locationInWindow))
    return event
}
view.onEvent = { row, via in received.append(row); receivedVia.append(via) }

// Cocoa screen coordinates put the origin at the bottom-left of the primary
// display; CoreGraphics puts it at the top-left. Warping and posting in the wrong
// one sends the events somewhere else entirely and measures nothing.
func cgPoint(fromCocoa point: NSPoint) -> CGPoint {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: point.x, y: primaryHeight - point.y)
}

let centreCocoa = NSPoint(x: window.frame.midX, y: window.frame.midY)
let centreOnScreen = cgPoint(fromCocoa: centreCocoa)
CGWarpMouseCursorPosition(centreOnScreen)

print("xppen-presscheck")
print("  view: \(Int(view.bounds.width))x\(Int(view.bounds.height))")
print("  centre, cocoa (\(Int(centreCocoa.x)), \(Int(centreCocoa.y)))"
      + " -> coregraphics (\(Int(centreOnScreen.x)), \(Int(centreOnScreen.y)))")
print("  kCGMouseEventPressure also set: \(withMousePressure ? "yes" : "no")")
print()

if watchMode {
    print("watching, posting nothing. Draw with the pen. Ctrl-C to stop.\n")
    NSEvent.addLocalMonitorForEvents(matching: [.tabletPoint, .tabletProximity, .mouseMoved,
                                                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                                .rightMouseDragged, .otherMouseDragged]) { event in
        let tablet = event.subtype == .tabletPoint || event.subtype == .tabletProximity
        var line = "  \(typeName(event.type.rawValue).padding(toLength: 16, withPad: " ", startingAt: 0))"
            + " type=\(event.type.rawValue) sub=\(event.subtype.rawValue)"
            + " p=\(String(format: "%.4f", Double(event.pressure)))"
            + " tilt=(\(String(format: "%.3f", Double(event.tilt.x))),\(String(format: "%.3f", Double(event.tilt.y))))"
        if tablet {
            // Everything AppKit exposes about the pointing device. One of these is
            // what Firefox is reading and we are not setting.
            line += " | SOURCE=\(event.pointingDeviceType.rawValue)"
                + " cap=0x\(String(event.capabilityMask, radix: 16))"
                + " vid=\(event.vendorID) tid=\(event.tabletID) did=\(event.deviceID)"
                + " sysTablet=\(event.systemTabletID) ptrID=\(event.pointingDeviceID)"
                + " vPtrType=\(event.vendorPointingDeviceType)"
                + " entering=\(event.isEnteringProximity)"
                + " serial=\(event.pointingDeviceSerialNumber)"
                + " absX=\(event.absoluteX) absY=\(event.absoluteY) absZ=\(event.absoluteZ)"
                + " rot=\(String(format: "%.2f", event.rotation))"
                + " tang=\(String(format: "%.2f", event.tangentialPressure))"
            line += "   <-- TABLET"
        }
        print(line)
        return event
    }
    app.run()
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    let injector = EventInjector()
    injector.tiltScale = Device.vendorTiltDivisor
    injector.alsoSetMousePressure = withMousePressure

    // Screen coordinates, because the cursor is parked over this window.
    let base = CGPoint(x: centreOnScreen.x - 80, y: centreOnScreen.y)

    func pen(_ pressure: UInt16, tip: Bool, tiltX: Int8 = 20, tiltY: Int8 = -10) -> PenReport {
        PenReport(x: 20000, y: 15000, pressure: pressure, tiltX: tiltX, tiltY: tiltY,
                  tipDown: tip, eraser: false, penButton1: false, penButton2: false,
                  inRange: true, status: tip ? 0xA1 : 0xA0)
    }

    // A timed sequence, spaced out so the run loop delivers each one rather than
    // coalescing them the way it does for a real mouse.
    var script: [(Double, () -> Void)] = []
    // A native tablet proximity event, the thing Firefox gates on.
    // Post proximity BOTH ways and see which, if either, arrives as a native
    // tablet event (type 24) rather than a mouse event with a tablet subtype.
    // Route A: CGEvent with subtype 2.
    script.append((0.00, { injector.postProximity(entering: true, at: base, pen: pen(0, tip: false)) }))
    // Route B: IOHIDPostEvent with NX_TABLETPROXIMITY, which is the only way to
    // make a *native* tablet event. Earlier this looked like it did nothing, but
    // that test filtered events to those inside the view.
    let native = TabletEventPoster()
    nativeAvailable = native.isAvailable
    script.append((0.25, { nativeResult = native.postProximity(entering: true, at: base) }))
    script.append((0.06, { injector.move(to: base, pen: pen(0, tip: false)) }))
    script.append((0.12, { injector.penDown(at: base, pen: pen(ramp[0], tip: true)) }))
    for (index, pressure) in ramp.dropFirst().enumerated() {
        let point = CGPoint(x: base.x + Double(index + 1) * 20, y: base.y)
        script.append((0.12 + Double(index + 1) * 0.12, {
            injector.postDrag(to: point, pen: pen(pressure, tip: true))
        }))
    }
    script.append((0.75, {
        injector.penUp(at: CGPoint(x: base.x + 100, y: base.y), pen: pen(0, tip: false))
    }))

    for (delay, action) in script {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
}

// Expected pressures, so the received values can be compared against them.
let ramp: [UInt16] = [2048, 6144, 10240, 14336, 16383]

DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
    // Only our own events: they are the ones inside the view.
    let ours = received

    print("--- events delivered to the view ---")
    let pairs = Set(zip(received, receivedVia).map { row, via in
        "\(typeName(row.typeRaw))/sub\(row.subtype.rawValue)/via \(via)"
    })
    print("  native IOHIDPostEvent: connection \(nativeAvailable ? "opened" : "FAILED"), returned \(nativeResult)")
    print("  responder callbacks used: " + pairs.sorted().joined(separator: ", "))
    for row in ours {
        let tablet = row.subtype == .tabletPoint ? "  tabletPoint" : ""
        print("  \(typeName(row.typeRaw).padding(toLength: 16, withPad: " ", startingAt: 0))"
              + " subtype=\(String(row.subtype.rawValue).padding(toLength: 3, withPad: " ", startingAt: 0))"
              + " pressure=\(String(format: "%.4f", row.pressure))"
              + " tilt=(\(Int(row.tilt.x)),\(Int(row.tilt.y)))\(tablet)")
    }
    print()

    let drags = ours.filter { $0.typeRaw == 6 }
    let tablet = ours.filter { $0.subtype == .tabletPoint }
    print("  expected pressures:    " + ramp.map { String(format: "%.3f", Double($0) / Double(Device.maxPressure)) }.joined(separator: ", "))
    let viewPairs = Set(ours.map { "\(typeName($0.typeRaw))/subtype\($0.subtype.rawValue)" })
    print("  view received:         " + viewPairs.sorted().joined(separator: ", "))
    let monPairs = Set(monitored.map { "\(typeName($0.typeRaw))/subtype\($0.subtype.rawValue)" })
    print("  monitor received:      " + monPairs.sorted().joined(separator: ", "))
    for row in ours where row.typeRaw == 24 {
        print("    NATIVE tabletProximity arrived at the view (type 24)")
    }
    let proximity = ours.filter { $0.typeRaw == 24 || $0.subtype == .tabletProximity }
    let monitoredProximity = monitored.filter { $0.typeRaw == 24 || $0.subtype == .tabletProximity }
    print("  proximity via monitor: \(monitoredProximity.count)   (app-level, ignores the responder chain)")
    for row in monitored where row.typeRaw == 24 || row.subtype == .tabletProximity {
        print("    monitored: type=\(typeName(row.typeRaw)) subtype=\(row.subtype.rawValue) entering?")
    }
    print("  tablet proximity evts: \(proximity.count)   (Firefox needs at least one)")
    print("  mouseDragged events:   \(drags.count)")
    print("  marked tabletPoint:    \(tablet.count)")
    if let peak = drags.map(\.pressure).max() {
        print(String(format: "  peak pressure on drag: %.4f", peak))
    } else {
        print("  peak pressure on drag: no drag events received")
    }
    if let peakTilt = drags.map(\.tilt.x).max() {
        print(String(format: "  peak tilt on drag:     %.3f   (sent %.3f)", peakTilt, 20.0 / Device.vendorTiltDivisor))
    }

    print()
    // A constant 1.0 while the button is down is AppKit's default for a mouse, not
    // pressure. The test is whether the received values follow the ramp we sent.
    let expected = ramp.dropFirst().map { Double($0) / Double(Device.maxPressure) }
    let got = drags.map(\.pressure)
    let distinct = Set(got.map { Int(($0 * 100).rounded()) }).count

    if got.isEmpty {
        print("  RESULT: inconclusive, no drag events reached the view.")
    } else if distinct <= 1 {
        print(String(format: "  RESULT: pressure is CONSTANT at %.4f while the button is down.", got[0]))
        print("  AppKit is reporting button state, not pen pressure, so applications and")
        print("  browsers see no pressure at all. kCGMouseEventPressure is the field that")
        print("  NSEvent.pressure reads; setting only the tablet field is not enough.")
    } else {
        var worst = 0.0
        for (index, value) in got.enumerated() where index < expected.count {
            worst = max(worst, abs(value - expected[index]))
        }
        print(String(format: "  RESULT: pressure varies and tracks the ramp (worst error %.4f).", worst))
        print("  Applications receive pen pressure. In a browser this is")
        print("  PointerEvent.pressure, with pointerType \"pen\" on the tablet events.")
    }
    exit(0)
}

app.run()
