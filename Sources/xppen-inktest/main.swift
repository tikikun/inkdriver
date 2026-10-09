// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 tikikun
//
// InkTest: a pen and eraser test window.
//
// An ordinary AppKit application that deliberately does not link the driver. It
// receives whatever the system injects, so what it shows is what any drawing
// application sees. That is the only honest way to test the eraser: a browser
// cannot see it, because the DOM's pointerType is only ever pen, mouse or touch.
//
// Build and run:
//   make inktest-run

import AppKit

private let panelWidth: CGFloat = 340

/// One stroke, in view coordinates.
private struct Stroke {
    var points: [CGPoint] = []
    var pressures: [CGFloat] = []
    var eraser = false
}

final class InkCanvasView: NSView {

    private var strokes: [Stroke] = []
    private var active: Stroke?

    /// The tool, tracked from the proximity callback. That is where AppKit exposes
    /// the pointing device type (1 pen, 3 eraser) and it is how real applications,
    /// Firefox included, decide whether they are drawing or erasing. Strokes do not
    /// repeat it, so an app that only looks at strokes never sees an eraser.
    private var tool: NSEvent.PointingDeviceType = .unknown

    private(set) var sawEraser = false

    /// The current tool as text, for the panel.
    var toolText: String {
        switch tool {
        case .eraser: return "eraser"
        case .pen: return "pen"
        default: return "unknown"
        }
    }
    private(set) var lastPoint: CGPoint = .zero

    var onUpdate: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    /// Flipped so view coordinates run the same way as tablet coordinates.
    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        for stroke in strokes { paint(stroke) }
        if let active { paint(active) }

        // An eraser cursor, so eraser mode is visible even over blank canvas.
        // Otherwise "erasing nothing" and "not working" look identical.
        if tool == .eraser {
            let ring = NSBezierPath(ovalIn: CGRect(x: lastPoint.x - 18, y: lastPoint.y - 18,
                                                  width: 36, height: 36))
            NSColor(white: 0.55, alpha: 0.9).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }

        NSColor(white: 0.85, alpha: 1).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func paint(_ stroke: Stroke) {
        guard let first = stroke.points.first else { return }
        let pressure = stroke.pressures.last ?? 0
        let width: CGFloat = stroke.eraser ? 40 : 1 + pressure * 24
        let colour: NSColor = stroke.eraser ? .white : .black

        if stroke.points.count == 1 {
            let dot = NSBezierPath(ovalIn: CGRect(x: first.x - width / 2, y: first.y - width / 2,
                                                 width: width, height: width))
            colour.setFill()
            dot.fill()
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for point in stroke.points.dropFirst() { path.line(to: point) }
        path.lineWidth = width
        colour.setStroke()
        path.stroke()
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        add(event, starting: true)
    }

    override func mouseDragged(with event: NSEvent) {
        add(event)
    }

    override func mouseUp(with event: NSEvent) {
        lastPoint = convert(event.locationInWindow, from: nil)
        finishStroke()
    }

    override func mouseMoved(with event: NSEvent) {
        lastPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func tabletProximity(with event: NSEvent) {
        tool = event.pointingDeviceType
        if tool == .eraser { sawEraser = true }
        onUpdate?()
    }

    private func add(_ event: NSEvent, starting: Bool = false) {
        lastPoint = convert(event.locationInWindow, from: nil)

        if starting || active == nil {
            // Started on the first drag as well as on a press: if a press is ever
            // missed the tip is already down, and without this the app would receive
            // drags and draw nothing for the rest of the stroke.
            let tool = self.tool == .unknown ? event.pointingDeviceType : self.tool
            active = Stroke(eraser: tool == .eraser)
        }
        guard active != nil else { return }

        active?.points.append(lastPoint)
        active?.pressures.append(CGFloat(event.pressure))
        needsDisplay = true
    }

    private func finishStroke() {
        if let finished = active, !finished.points.isEmpty {
            strokes.append(finished)
        }
        active = nil
        needsDisplay = true
        onUpdate?()
    }

    func clear() {
        strokes = []
        active = nil
        needsDisplay = true
        onUpdate?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var canvas: InkCanvasView!
    private var panel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1180, height: 820)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "InkTest: pen and eraser"
        window.center()

        let content = NSView(frame: frame)
        canvas = InkCanvasView(frame: NSRect(x: 0, y: 0, width: frame.width - panelWidth,
                                             height: frame.height))
        canvas.autoresizingMask = [.width, .height]
        content.addSubview(canvas)

        panel = NSTextField(frame: NSRect(x: frame.width - panelWidth, y: 0,
                                          width: panelWidth, height: frame.height))
        panel.autoresizingMask = [.minXMargin, .height]
        panel.isEditable = false
        panel.isSelectable = false
        panel.isBezeled = false
        panel.drawsBackground = true
        panel.backgroundColor = NSColor(white: 0.96, alpha: 1)
        panel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        panel.usesSingleLineMode = false
        panel.cell?.wraps = true
        panel.maximumNumberOfLines = 0
        content.addSubview(panel)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        canvas.onUpdate = { [weak self] in self?.refresh() }
        refresh()

        // A render tick. AppKit's invalidation was not reliably redrawing this view,
        // so a canvas receiving hundreds of events could go a whole session with a
        // single draw pass and an empty window. A canvas that is being drawn on
        // continuously does not need AppKit to decide when to redraw it.
        let tick = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.canvas.display()
        }
        RunLoop.main.add(tick, forMode: .common)

        // The view has to hold first responder or the responder chain never reaches
        // its event methods, which fails silently: the window looks right and
        // receives nothing.
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)

        let menu = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu()
        let clearItem = NSMenuItem(title: "Clear", action: #selector(clearCanvas), keyEquivalent: "k")
        clearItem.target = self
        edit.addItem(clearItem)
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func clearCanvas() { canvas.clear() }

    private func refresh() {
        let tool: String
        switch canvas.toolText {
        case "eraser": tool = "ERASER"
        case "pen": tool = "PEN"
        default: tool = "unknown, waiting for the pen"
        }

        panel.stringValue = """
        TOOL: \(tool)

        How to test
        ------------------------------
        1. Draw with the pen. Black ink appears.
        2. Hold the button bound to eraser mode and
           drag across the ink. It is removed, and a
           grey ring follows the pen.
        3. Release and draw again. Ink returns.

        Cmd+K clears the canvas.

        Pen events go to the window that is in front,
        so click this window before drawing.

        What this proves
        ------------------------------
        A drawing application decides it is erasing
        from the pointing device type, which AppKit
        exposes on proximity events: 1 is a pen, 3 is
        an eraser. This app tracks the tool exactly the
        way a real drawing application does.
        """
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
