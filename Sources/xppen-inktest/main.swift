// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 tikikun
//
// InkTest: a native AppKit window for checking the pen and the eraser.
//
// This app deliberately does **not** link XPTabletCore and does not read anything
// from the driver. It is an ordinary macOS application that receives whatever the
// system injects, so what it shows is what any drawing application sees. That is the
// only way to test the eraser honestly: the browser cannot see it (the DOM's
// pointerType is only ever pen, mouse or touch), so a web page would report success
// no matter what the driver did.
//
// The signal being tested is `NSEvent.pointingDeviceType`, which is 1 for a pen and
// 3 for an eraser. Strokes drawn while it reads 3 are painted in the canvas colour,
// which is what an eraser does visually, so holding the bound button and dragging
// across existing ink visibly removes it.
//
// Build and run:  swift run xppen-inktest

import AppKit

private let panelWidth: CGFloat = 360

/// A stroke captured from the pen, in view coordinates.
private struct Stroke {
    var points: [CGPoint] = []
    var pressures: [CGFloat] = []
    var eraser = false
}

final class InkCanvasView: NSView {

    // MARK: - Ink

    private var strokes: [Stroke] = []
    private var active: Stroke?

    // MARK: - Live state, read from the events themselves

    private(set) var pointingDevice: NSEvent.PointingDeviceType = .unknown
    private(set) var lastPressure: CGFloat = 0
    private(set) var lastTiltX: CGFloat = 0
    private(set) var lastTiltY: CGFloat = 0
    private(set) var totalEvents = 0
    private(set) var penEvents = 0
    private(set) var eraserEvents = 0
    private(set) var proximityEvents = 0
    /// The tool, tracked the way a real application tracks it: from the proximity
    /// callback, which is the only event that carries the pointing device type in a
    /// form AppKit exposes. Strokes do not repeat it, so an application that only
    /// looked at strokes would never see an eraser.
    private(set) var toolFromProximity: NSEvent.PointingDeviceType = .unknown
    private(set) var lastProximity: NSEvent?
    private(set) var sawEraser = false
    private(set) var sawPen = false
    private(set) var lastCallback = "none yet"
    private(set) var lastEvent: NSEvent?
    private(set) var strokeCount = 0
    /// Where the pen last was, so eraser mode can show a ring and be visible even
    /// when it is not over any ink.
    private(set) var lastPoint: CGPoint = .zero

    var onUpdate: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    /// Flipped so view coordinates run the same way as tablet coordinates, with y
    /// increasing downwards. Nothing here depends on it, but it makes the readouts
    /// line up with the device's own numbers.
    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        for stroke in strokes { paint(stroke) }
        if let active { paint(active) }

        // An eraser cursor, so eraser mode is visible even on blank canvas. Without
        // it the only feedback is ink disappearing, and "nothing happened" and "it
        // erased nothing" look identical.
        let live = toolFromProximity == .unknown ? pointingDevice : toolFromProximity
        if live == .eraser {
            let ring = NSBezierPath(ovalIn: CGRect(x: lastPoint.x - 20, y: lastPoint.y - 20,
                                                   width: 40, height: 40))
            NSColor(white: 0.55, alpha: 0.9).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }

        // A frame, so an empty canvas is still obviously a canvas.
        NSColor(white: 0.85, alpha: 1).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func paint(_ stroke: Stroke) {
        guard let first = stroke.points.first else { return }
        let pressure = stroke.pressures.last ?? 0
        // Eraser strokes are wide and painted in the canvas colour, so they remove
        // ink rather than covering it with a second colour.
        let width = stroke.eraser ? 40 : 1 + pressure * 24

        if stroke.points.count == 1 {
            let dot = NSBezierPath(ovalIn: CGRect(x: first.x - width / 2, y: first.y - width / 2,
                                                 width: width, height: width))
            (stroke.eraser ? NSColor.white : NSColor.black).setFill()
            dot.fill()
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for point in stroke.points.dropFirst() { path.line(to: point) }
        path.lineWidth = width
        (stroke.eraser ? NSColor.white : NSColor.black).setStroke()
        path.stroke()
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        beginOrContinue(event, callback: "mouseDown", starting: true)
    }

    override func mouseDragged(with event: NSEvent) {
        beginOrContinue(event, callback: "mouseDragged")
    }

    override func mouseUp(with event: NSEvent) {
        record(event, callback: "mouseUp")
        finishStroke()
    }

    override func mouseMoved(with event: NSEvent) {
        record(event, callback: "mouseMoved")
        lastPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    /// Present so the window reports whether these arrive at all. A plain AppKit
    /// application only receives them for native tablet events, which is the whole
    /// reason the driver has to post one.
    override func tabletProximity(with event: NSEvent) {
        proximityEvents += 1
        lastProximity = event
        toolFromProximity = event.pointingDeviceType
        print(String(format: "[proximity] devType=%d devID=%d vid=%d sysTablet=%d ptrID=%d entering=%@",
                     event.pointingDeviceType.rawValue, event.deviceID, event.vendorID,
                     event.systemTabletID, event.pointingDeviceID,
                     event.isEnteringProximity ? "yes" : "no"))
        fflush(stdout)
        record(event, callback: "tabletProximity")
    }

    private func beginOrContinue(_ event: NSEvent, callback: String, starting: Bool = false) {
        record(event, callback: callback)
        lastPoint = convert(event.locationInWindow, from: nil)
        if starting {
            // Prefer the tool announced by proximity, falling back to the event's own
            // pointing device type if the system did put one there.
            let tool = toolFromProximity == .unknown ? event.pointingDeviceType : toolFromProximity
            active = Stroke(eraser: tool == .eraser)
        }
        guard active != nil else { return }
        active?.points.append(convert(event.locationInWindow, from: nil))
        active?.pressures.append(CGFloat(event.pressure))
        needsDisplay = true
    }

    private func finishStroke() {
        if let finished = active, finished.points.count >= 1 {
            strokes.append(finished)
            strokeCount += 1
        }
        active = nil
        needsDisplay = true
        onUpdate?()
    }

    private func record(_ event: NSEvent, callback: String) {
        totalEvents += 1
        // Also written to stdout, so the state can be read from a log rather than
        // from a screenshot.
        print(String(format: "[event] cb=%-15@ type=%2d sub=%2d devType=%d tool=%d devID=%d pressure=%.4f",
                     callback as NSString, event.type.rawValue, event.subtype.rawValue,
                     event.pointingDeviceType.rawValue, toolFromProximity.rawValue,
                     event.deviceID, event.pressure))
        fflush(stdout)
        lastEvent = event
        lastCallback = callback
        pointingDevice = event.pointingDeviceType
        lastPressure = CGFloat(event.pressure)
        lastTiltX = CGFloat(event.tilt.x)
        lastTiltY = CGFloat(event.tilt.y)
        switch event.pointingDeviceType {
        case .eraser: eraserEvents += 1; sawEraser = true
        case .pen: penEvents += 1; sawPen = true
        default: break
        }
        if toolFromProximity == .eraser { sawEraser = true }
        if toolFromProximity == .pen { sawPen = true }
        onUpdate?()
    }

    func clear() {
        strokes = []
        active = nil
        strokeCount = 0
        needsDisplay = true
        onUpdate?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var canvas: InkCanvasView!
    private var panel: NSTextField!

    func applicationDidBecomeActive(_ notification: Notification) {
        // Some pens report the tool only while the window is focused, and clicking
        // back in should show the current state immediately.
        canvas?.onUpdate?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "InkTest: pen and eraser"
        window.center()
        // Stay above other windows. Pen events go to whichever window is focused, so
        // a test window that slips behind another application silently stops
        // receiving anything, which looks exactly like a broken driver.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)

        let content = NSView(frame: frame)
        content.autoresizingMask = [.width, .height]

        canvas = InkCanvasView(frame: NSRect(x: 0, y: 0, width: frame.width - panelWidth,
                                             height: frame.height))
        canvas.autoresizingMask = [.width, .height]
        content.addSubview(canvas)

        panel = NSTextField(frame: NSRect(x: frame.width - panelWidth, y: 0,
                                          width: panelWidth, height: frame.height))
        panel.autoresizingMask = [.minXMargin, .height]
        panel.isEditable = false
        panel.isBezeled = false
        panel.drawsBackground = true
        panel.backgroundColor = NSColor(white: 0.96, alpha: 1)
        panel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        panel.usesSingleLineMode = false
        panel.cell?.wraps = true
        panel.maximumNumberOfLines = 0
        content.addSubview(panel)

        window.contentView = content

        canvas.onUpdate = { [weak self] in self?.refresh() }
        refresh()

        // The canvas must hold first responder or the responder chain never reaches
        // its event methods, which is a silent failure: the window looks right and
        // receives nothing.
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()

        // Cmd+K clears, matching the usual clear-canvas habit.
        let clear = NSMenuItem(title: "Clear", action: #selector(clearCanvas), keyEquivalent: "k")
        clear.target = self
        let menu = NSMenu()
        let edit = NSMenuItem()
        menu.addItem(edit)
        let editMenu = NSMenu()
        editMenu.addItem(clear)
        edit.submenu = editMenu
        NSApp.mainMenu = menu
    }

    @objc private func clearCanvas() { canvas.clear() }

    private func refresh() {
        let tool: String
        switch (canvas.toolFromProximity == .unknown ? canvas.pointingDevice : canvas.toolFromProximity) {
        case .eraser: tool = "ERASER"
        case .pen: tool = "PEN"
        case .cursor: tool = "MOUSE"
        default: tool = "unknown"
        }

        let eraserVerdict: String
        if canvas.sawEraser {
            eraserVerdict = "seen: the eraser reaches this application"
        } else if canvas.sawPen {
            eraserVerdict = "NOT seen yet. Hold the bound button and draw."
        } else {
            eraserVerdict = "waiting for the pen"
        }

        var text = """
        TOOL NOW: \(tool)

        A drawing application decides it is erasing from
        the pointing device type, 1 for a pen and 3 for an
        eraser. AppKit only exposes it on proximity events,
        so this app tracks the tool the same way a real
        drawing application does, from tabletProximity:.

        Eraser is \(eraserVerdict)

        --------------------------------------------------
        how to test

        1. Draw with the pen: black ink appears.
        2. Hold the button bound to eraser mode and drag
           across the ink: it is removed.
        3. Release and draw again: ink returns.

        Cmd+K clears the canvas.

        If the counters are frozen, click this window:
        pen events go to the focused window, so drawing
        while another application is in front sends the
        strokes there instead of here.

        --------------------------------------------------
        live
        tool          \(tool)  (from proximity: \(canvas.toolFromProximity.rawValue))
        pressure      \(String(format: "%.4f", Double(canvas.lastPressure)))
        tilt          \(String(format: "%.3f", Double(canvas.lastTiltX))), \(String(format: "%.3f", Double(canvas.lastTiltY)))
        last callback \(canvas.lastCallback)

        counts
        events        \(canvas.totalEvents)
        as pen        \(canvas.penEvents)
        as eraser     \(canvas.eraserEvents)
        proximity     \(canvas.proximityEvents)
        strokes       \(canvas.strokeCount)

        --------------------------------------------------
        last proximity event
        """
        if let prox = canvas.lastProximity {
            text += """

            type          \(prox.type.rawValue)  subtype \(prox.subtype.rawValue)
            device type   \(prox.pointingDeviceType.rawValue)
            deviceID      \(prox.deviceID)
            vendorID      \(prox.vendorID)
            tabletID      \(prox.tabletID)
            entering      \(prox.isEnteringProximity)
            """
        } else {
            text += "\n            none yet"
        }

        text += """

        --------------------------------------------------
        device identity on the last event
        """
        if let event = canvas.lastEvent {
            text += """

            type          \(event.type.rawValue)  subtype \(event.subtype.rawValue)
            deviceID      \(event.deviceID)
            vendorID      \(event.vendorID)
            tabletID      \(event.tabletID)
            systemTablet  \(event.systemTabletID)
            pointerID     \(event.pointingDeviceID)
            capability    0x\(String(event.capabilityMask, radix: 16))
            entering      \(event.isEnteringProximity)
            """
        } else {
            text += "\n            no events yet"
        }

        panel.stringValue = text
    }
}

// Refuse to start a second copy.
//
// Two instances create two identical windows stacked exactly on top of each other,
// and the one that receives an event is whichever is focused, so it becomes
// impossible to tell which process the counters and the log belong to. That cost
// several rounds of "nothing happened".
let lockPath = "/tmp/xppen-inktest.lock"
if let existing = try? String(contentsOfFile: lockPath, encoding: .utf8),
   let pid = pid_t(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
   pid != getpid(), kill(pid, 0) == 0 {
    FileHandle.standardError.write("xppen-inktest is already running as pid \(pid). Use that window.\n".data(using: .utf8)!)
    exit(0)
}
try? "\(getpid())".write(toFile: lockPath, atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
