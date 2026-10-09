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
import CoreGraphics
import IOKit
import IOKit.hid

/// The driver core.
///
/// This is deliberately free of any UI or CLI concerns so that `xpdriverd` and
/// the menu-bar app run exactly the same code path. It owns the HID reader, the
/// pen/button state machine, the coordinate mapper, and the event injector.
public final class Driver {

    public enum Event {
        case started
        case stopped
        case tabletConnected(Bool)
        case proximity(Bool)
        case penDown(x: Int, y: Int, pressure: UInt16)
        case penUp
        case expressKey(index: Int, down: Bool)
        case penButton(index: Int, down: Bool)
        /// The driver changed the mapping itself (Switch monitor, precision mode).
        /// The host must adopt this into its own config or the UI drifts out of
        /// sync with what the driver is actually doing.
        case workspaceChanged(WorkspaceConfig)
        case message(String)
    }

    /// Called on the main thread for every interesting state change.
    public var onEvent: ((Event) -> Void)?

    /// Every decoded pen report. Used by the pen test view; leave nil when nothing
    /// is watching and it costs nothing.
    public var onPenSample: ((PenSample) -> Void)?

    /// One decoded report, alongside what the driver did with it.
    public struct PenSample {
        /// As handed to applications: pressure is zeroed while hovering if that
        /// option is on, and the tool may have been overridden to eraser.
        public let pen: PenReport
        /// Exactly what the hardware reported, before any of that. The sensor
        /// leaks while hovering, which is worth being able to see.
        public let rawPressure: UInt16
        /// Mapped screen position.
        public let point: CGPoint
        /// True when the driver considers the pen to be touching.
        public let touching: Bool
    }

    public private(set) var isRunning = false
    public private(set) var tabletConnected = false
    /// IORegistry id of the device we are reading. Changes when the tablet is
    /// re-enumerated, which is what happens across sleep/wake.
    public private(set) var deviceRegistryID: UInt64?
    /// True while a `.wheelMode` binding is held: pen movement scrolls.
    public private(set) var wheelModeActive = false
    public private(set) var precisionActive = false
    public private(set) var eraserOverride = false
    public private(set) var lastPressure: UInt16 = 0

    /// When the last input report arrived. Used to notice the tablet going quiet.
    public private(set) var lastReportAt = Date()
    private var rearmAttempts = 0

    public var config: DriverConfig

    private let injector = EventInjector()
    private var discovery: HIDDiscovery?
    private var readers: [HIDReportReader] = []
    private var mapper: AreaMapper

    // State machine
    private var inProximity = false
    private var penIsDown = false
    private var lastPenButton = [false, false]
    private var lastTabletButtons = [Bool](repeating: false, count: 8)
    private var lastPoint: CGPoint = .zero
    private var lastRaw: (x: UInt32, y: UInt32)?
    /// Previous mapped point while scrolling, so each report contributes only the
    /// movement since the last one. Measuring from a fixed anchor instead makes the
    /// scroll accelerate the further the pen travels.
    private var lastWheelPoint: CGPoint?
    /// Sub-pixel scroll carried between reports, so slow pen movement still adds up
    /// to whole pixels instead of being truncated away.
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    private var dryRun: Bool

    public init(config: DriverConfig, dryRun: Bool = false) {
        self.config = config
        self.dryRun = dryRun
        self.mapper = Driver.makeMapper(config)
        configureInjector(config)
        injector.onControlAction = { [weak self] action in
            self?.handleControlAction(action)
        }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        discovery = HIDDiscovery()
        guard let pen = discovery?.penInterface else {
            tabletConnected = false
            emit(.tabletConnected(false))
            emit(.message("no tablet found (VID 0x\(String(Device.vendorID, radix: 16)) PID 0x\(String(Device.productID, radix: 16)))"))
            return
        }

        if openHIDDevice(pen) != kIOReturnSuccess {
            emit(.message("failed to open the tablet — grant Input Monitoring to this app"))
            return
        }

        let seize = config.effectiveSeizeFallback
        if seize && !dryRun {
            for iface in discovery?.interfaces ?? [] where iface.role != .pen {
                let result = IOHIDDeviceOpen(iface.device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                emit(.message(result == kIOReturnSuccess
                    ? "seized \(iface.label) (stops macOS moving the cursor itself)"
                    : "could NOT seize \(iface.label): 0x\(String(UInt32(bitPattern: result), radix: 16))"))
            }
        }

        if config.effectiveSendHandshake {
            let result = sendOutputReport(pen, frame: Device.initFrame)
            emit(.message(result == kIOReturnSuccess
                ? "handshake sent: 02 B0 04"
                : "handshake failed: 0x\(String(UInt32(bitPattern: result), radix: 16))"))
        }

        readers = [HIDReportReader(interface: pen) { [weak self] bytes in
            self?.handle(report: bytes)
        }]

        deviceRegistryID = registryEntryID(of: pen.device)
        lastReportAt = Date()
        rearmAttempts = 0
        isRunning = true
        tabletConnected = true
        emit(.started)
        emit(.tabletConnected(true))
    }

    public func stop() {
        readers.forEach { $0.unregister() }
        readers = []
        discovery = nil
        deviceRegistryID = nil
        isRunning = false
        tabletConnected = false
        inProximity = false
        penIsDown = false
        wheelModeActive = false
        // Only .stopped: emitting .tabletConnected(false) here would print
        // "tablet not found" during an intentional restart.
        emit(.stopped)
    }

    /// True while the device we opened is still the same physical device.
    ///
    /// After a sleep/wake cycle the USB device is re-enumerated: the `IOHIDDevice`
    /// reference the driver holds becomes a stale handle and its input callback
    /// never fires again, so the pen silently stops working even though the
    /// process is healthy. Re-discovering and comparing the IORegistry entry id
    /// detects that. Must be called on the same thread as `start()`.
    public func isDeviceAlive() -> Bool {
        guard isRunning, let discovery else { return false }
        discovery.refresh()
        guard let pen = discovery.penInterface else { return false }
        guard let current = registryEntryID(of: pen.device) else { return true }
        guard let known = deviceRegistryID else { return true }
        return current == known
    }

    /// Stop and start again, re-discovering the device and re-sending the
    /// handshake. Used after wake and when the device is replaced.
    public func restart() {
        stop()
        start()
    }

    /// Replace the configuration. Rebuilds the mapper and injector settings.
    /// Re-read the display list. Called when the display configuration changes so
    /// a newly attached monitor is picked up and a removed one is dropped.
    public func refreshDisplays() {
        let displays = AreaMapper.DisplayBounds.activeDisplays()
        var workspace = config.effectiveWorkspace.normalize(displays)
        // If the targeted display vanished, fall back to the first available.
        if let id = workspace.displayID, !displays.contains(where: { $0.displayID == id }) {
            workspace.displayID = displays.first?.displayID
        }
        config.workspace = workspace
        mapper = Driver.makeMapper(config)
        emit(.workspaceChanged(workspace))
    }

    public func apply(config: DriverConfig) {
        self.config = config
        mapper = Driver.makeMapper(config)
        configureInjector(config)
    }

    private func configureInjector(_ config: DriverConfig) {
        injector.tiltScale = config.effectiveTiltScale
        injector.invertTiltX = config.invertTiltX ?? false
        injector.invertTiltY = config.invertTiltY ?? false
        injector.alsoSetMousePressure = config.effectiveSetMousePressureField
    }

    // MARK: - Mapping

    private static func makeMapper(_ config: DriverConfig) -> AreaMapper {
        let displays = AreaMapper.DisplayBounds.activeDisplays()
        return AreaMapper(
            workspace: config.effectiveWorkspace.normalize(displays),
            displays: displays,
            maxX: config.maxX ?? Device.maxX,
            maxY: config.maxY ?? Device.maxY
        )
    }

    private func makePoint(_ pen: PenReport) -> CGPoint {
        if precisionActive {
            // Precision mode: shrink the active tablet area to the middle half,
            // so the same hand movement covers less screen.
            var workspace = mapper.workspace
            workspace.updateCurrentProfile(mapper.displays) { profile in
                let full = profile.tabletRect
                profile.tabletRect = NormalizedRect(
                    x: full.x + full.width * 0.25,
                    y: full.y + full.height * 0.25,
                    width: full.width * 0.5,
                    height: full.height * 0.5
                )
            }
            let precision = AreaMapper(workspace: workspace, displays: mapper.displays,
                                       maxX: mapper.maxX, maxY: mapper.maxY)
            return precision.map(x: pen.x, y: pen.y)
        }
        return mapper.map(x: pen.x, y: pen.y)
    }

    // MARK: - Report handling

    private func emit(_ event: Event) {
        // Always hop to the main queue: the HID callback runs on the main thread
        // too, and calling back into SwiftUI synchronously from inside it can
        // re-enter the view update while a menu is tracking.
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    /// Records that the device is alive. A command reply is not input, so it must
    /// not count as evidence that the pen is working: otherwise the acknowledge
    /// from a re-arm would look like the pen had started reporting again.
    private func noteInput() {
        let gap = Date().timeIntervalSince(lastReportAt)
        if gap > 20 {
            emit(.message("input resumed after \(Int(gap))s quiet"))
        }
        lastReportAt = Date()
        rearmAttempts = 0
    }

    /// Periodic upkeep, called from the host every few seconds.
    ///
    /// The tablet drops out of tablet mode on its own after a period of no pen
    /// activity: the vendor interface simply stops reporting, and nothing arrives
    /// until the mode command is sent again. Measured directly by running
    /// `xppen-probe --watch` with and without `--init` on an idle device: zero
    /// reports without the handshake, a steady stream with it. So while the pen is
    /// idle the handshake is repeated, which is harmless, and if that stops
    /// helping the device is reopened from scratch.
    public func maintenance() {
        guard isRunning else { return }
        guard let discovery, let pen = discovery.penInterface else {
            restart()
            return
        }

        // Has the device been unplugged and re-enumerated behind our back?
        if let known = deviceRegistryID, let current = registryEntryID(of: pen.device),
           current != known {
            emit(.message("the tablet was re-enumerated, reopening"))
            restart()
            return
        }

        // Keep the tablet in tablet mode whenever it is not being used. An idle
        // tablet reports nothing at all, which is normal, so silence is not
        // evidence of a fault; but a tablet that has quietly left tablet mode will
        // never report again until it is told to. Re-arming costs one small output
        // report, so it is done routinely rather than only after a suspected fault.
        let quiet = Date().timeIntervalSince(lastReportAt)
        guard quiet > 2, config.effectiveSendHandshake else { return }
        rearmAttempts += 1
        _ = sendOutputReport(pen, frame: Device.initFrame)
    }

    private func handle(report bytes: [UInt8]) {
        // Command replies (the re-arm acknowledge, for instance) are not input.
        if bytes.count > 1, bytes[1] & 0xF0 != 0xB0 {
            noteInput()
        }
        let decoded: DecodedReport
        do { decoded = try ReportDecoder.decode(bytes) } catch { return }

        switch decoded {
        case .outOfRange:
            if penIsDown {
                penIsDown = false
                injector.penUp(at: lastPoint, pen: toolReport(eraser: eraserOverride))
                emit(.penUp)
            }
            if inProximity {
                inProximity = false
                emit(.proximity(false))
                if !dryRun {
                    injector.postProximity(entering: false, at: lastPoint, pen: toolReport(eraser: eraserOverride))
                }
            }
            lastPenButton = [false, false]
            lastRaw = nil
            if wheelModeActive {
                wheelModeActive = false
                lastWheelPoint = nil
                emit(.message("scroll mode off"))
            }

        case .aux(let aux):
            for (index, pressed) in aux.buttons.enumerated() where index < lastTabletButtons.count {
                guard pressed != lastTabletButtons[index] else { continue }
                lastTabletButtons[index] = pressed
                emit(.expressKey(index: index, down: pressed))
                applyBinding(config.expressKeyBindings()[index], isDown: pressed)
            }

        case .command:
            break

        case .unknown(let prefix):
            emit(.message("unrecognised report: " + prefix.map { String(format: "%02X", $0) }.joined(separator: " ")))

        case .pen(let rawPen):
            let rawPressure = rawPen.pressure
            var pen = applyEraserOverride(rawPen)
            // Contact is the tip switch; a non-zero threshold only raises the bar.
            // See Contact.isTouching for why pressure cannot stand alone.
            let threshold = config.effectivePressureThreshold
            let touching = Contact.isTouching(tipDown: pen.tipDown,
                                              pressure: pen.pressure,
                                              threshold: threshold)
            if config.effectiveZeroPressureOnHover && !touching {
                pen.pressure = 0
            }
            lastPressure = pen.pressure

            let point = makePoint(pen)

            if !inProximity {
                inProximity = true
                emit(.proximity(true))
                if !dryRun {
                    injector.postProximity(entering: true, at: point, pen: pen)
                }
            }

            // Handle pen buttons *before* the wheel-mode branch: otherwise the
            // release that turns wheel mode off would be swallowed by the early
            // return and the pen would stay stuck in scroll mode.
            if pen.penButton1 != lastPenButton[0] {
                lastPenButton[0] = pen.penButton1
                emit(.penButton(index: 0, down: pen.penButton1))
                applyBinding(config.penButtonBinding(0), isDown: pen.penButton1)
            }
            if pen.penButton2 != lastPenButton[1] {
                lastPenButton[1] = pen.penButton2
                emit(.penButton(index: 1, down: pen.penButton2))
                applyBinding(config.penButtonBinding(1), isDown: pen.penButton2)
            }

            // Wheel mode: scroll by exactly how far the pen moved this report, so
            // one point of pointer movement is one pixel of scroll. No
            // acceleration, no ramp — the same as a mouse wheel.
            if wheelModeActive {
                if let previous = lastWheelPoint {
                    let sens = config.effectiveScrollSensitivity
                    let signX: Double = (config.scrollInvertX ?? false) ? 1 : -1
                    let signY: Double = (config.scrollInvertY ?? false) ? 1 : -1

                    scrollRemainderX += Double(point.x - previous.x) * sens * signX
                    scrollRemainderY += Double(point.y - previous.y) * sens * signY

                    let stepX = Int32(scrollRemainderX.rounded(.towardZero))
                    let stepY = Int32(scrollRemainderY.rounded(.towardZero))
                    scrollRemainderX -= Double(stepX)
                    scrollRemainderY -= Double(stepY)

                    if !dryRun, stepX != 0 || stepY != 0 {
                        injector.scroll(deltaX: stepX, deltaY: stepY)
                    }
                }
                lastWheelPoint = point
                lastRaw = (pen.x, pen.y)
                // No move event is posted, so the cursor simply stays where it was.
                return
            }

            lastRaw = (pen.x, pen.y)
            lastPoint = point

            onPenSample?(PenSample(pen: pen, rawPressure: rawPressure,
                                   point: point, touching: touching))

            if touching && !penIsDown {
                penIsDown = true
                // Announce proximity again on every tip-down. A proximity event is
                // only useful to the application that receives it, and the one sent
                // when the pen entered range may have gone to whichever window was
                // frontmost then. Pressing the tip is a natural moment to say the
                // pen is here, and it costs one event.
                if !dryRun {
                    injector.postProximity(entering: true, at: point, pen: pen)
                }
                emit(.penDown(x: Int(point.x), y: Int(point.y), pressure: pen.pressure))
                if !dryRun { injector.penDown(at: point, pen: pen) }
            } else if !touching && penIsDown {
                penIsDown = false
                emit(.penUp)
                if !dryRun { injector.penUp(at: point, pen: pen) }
            } else if !dryRun {
                // While the tip is down this must be a drag, not a move: a plain
                // mouseMoved with no button held reads as hovering, and drawing
                // applications ignore it for the stroke in progress.
                if penIsDown { injector.postDrag(to: point, pen: pen) }
                else { injector.move(to: point, pen: pen) }
            }
        }
    }

    private func applyBinding(_ binding: Binding, isDown: Bool) {
        switch binding {
        case .wheelMode:
            if wheelModeActive != isDown {
                wheelModeActive = isDown
                // Restart the delta tracking so the jump between where the cursor
                // was and where the pen is now is never turned into scroll.
                lastWheelPoint = nil
                scrollRemainderX = 0
                scrollRemainderY = 0
                emit(.message(isDown ? "scroll mode on" : "scroll mode off"))
            }
        case .toggleEraser:
            if isDown {
                eraserOverride.toggle()
                emit(.message("eraser mode \(eraserOverride ? "on" : "off")"))
            }
        default:
            if !dryRun {
                injector.perform(binding, at: lastPoint,
                                 pen: toolReport(eraser: eraserOverride), isDown: isDown)
            }
        }
    }

    private func handleControlAction(_ action: ControlAction) {
        switch action {
        case .showDriverPanel:
            emit(.message("show driver panel"))
            onControlAction?(action)
        case .switchMonitor:
            // Cycle through the configured displays, or every active display.
            let displays = AreaMapper.DisplayBounds.activeDisplays()
            var workspace = config.effectiveWorkspace.normalize(displays)
            guard let nextID = workspace.nextDisplayID(displays) else { return }
            workspace.displayID = nextID
            config.workspace = workspace
            mapper = Driver.makeMapper(config)
            let index = displays.firstIndex { $0.displayID == nextID } ?? 0
            emit(.message("switched to display \(index)\(workspace.hasProfile(forDisplayID: nextID) ? " (own settings)" : "")"))
            // Tell the host, so its config and UI follow the driver.
            emit(.workspaceChanged(workspace))
        case .togglePrecision:
            precisionActive.toggle()
            emit(.message("precision mode \(precisionActive ? "on" : "off")"))
        }
    }

    /// Set by the host UI to handle actions that need a window (e.g. open settings).
    public var onControlAction: ((ControlAction) -> Void)?

    private func applyEraserOverride(_ pen: PenReport) -> PenReport {
        guard eraserOverride, !pen.eraser else { return pen }
        var copy = pen
        copy.eraser = true
        return copy
    }

    private func toolReport(eraser: Bool) -> PenReport {
        PenReport(x: 0, y: 0, pressure: 0, tiltX: 0, tiltY: 0,
                  tipDown: false, eraser: eraser, penButton1: false, penButton2: false,
                  inRange: false, status: 0)
    }
}
