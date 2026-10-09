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
import ApplicationServices
import AppKit

/// CoreGraphics event fields used to attach tablet data to synthetic events.
///
/// **These are Apple's real field numbers**, not guesses. They were recovered
/// from the vendor driver (`setFillTabletEventFields` 0x1000158ef,
/// `setFillProximinityFields` 0x100015f19) and then matched exactly against
/// `CGEventField` in `CGEventTypes.h`:
///
///     kCGMouseEventSubtype          = 7
///     kCGTabletEventPointX          = 15   (double)
///     kCGTabletEventPointY          = 16   (double)
///     kCGTabletEventPointZ          = 17   (double)
///     kCGTabletEventPointButtons    = 18   (integer, bit 0 = button 1)
///     kCGTabletEventPointPressure   = 19   (double, 0.0 ... 1.0)
///     kCGTabletEventTiltX           = 20   (double)
///     kCGTabletEventTiltY           = 21   (double)
///     kCGTabletEventRotation        = 22   (double)
///     kCGTabletEventTangentialPressure = 23 (double)
///     kCGTabletEventDeviceID        = 24   (integer)
///     kCGTabletEventVendor1...3     = 25..27
///     kCGTabletProximityEvent*      = 28..38
///
/// The vendor sets `kCGMouseEventSubtype = 1` (`kCGEventMouseSubtypeTabletPoint`)
/// on every move it posts. That is what tells AppKit and drawing applications
/// that the event carries tablet data; without it the pressure/tilt fields are
/// ignored.
public enum TabletField {
    public static let mouseSubtype: CGEventField = .mouseEventSubtype          // 7
    public static let pointX: CGEventField = .tabletEventPointX                // 15
    public static let pointY: CGEventField = .tabletEventPointY                // 16
    public static let pointZ: CGEventField = .tabletEventPointZ                // 17
    public static let pointButtons: CGEventField = .tabletEventPointButtons    // 18
    public static let pointPressure: CGEventField = .tabletEventPointPressure  // 19
    public static let tiltX: CGEventField = .tabletEventTiltX                  // 20
    public static let tiltY: CGEventField = .tabletEventTiltY                  // 21
    public static let rotation: CGEventField = .tabletEventRotation            // 22
    public static let tangentialPressure: CGEventField = .tabletEventTangentialPressure // 23
    public static let deviceID: CGEventField = .tabletEventDeviceID            // 24
    public static let vendor1: CGEventField = .tabletEventVendor1              // 25
    public static let vendor2: CGEventField = .tabletEventVendor2              // 26
    public static let vendor3: CGEventField = .tabletEventVendor3              // 27

    public static let subtypeTabletPoint: Int64 = 1        // kCGEventMouseSubtypeTabletPoint
    public static let subtypeTabletProximity: Int64 = 2    // kCGEventMouseSubtypeTabletProximity
}

public enum SystemAction: String, Equatable {
    case screenKeyboard
    case virtualBoard
}

/// Actions the driver cannot perform by itself and must hand to the host UI.
public enum ControlAction: Equatable {
    case showDriverPanel
    case switchMonitor
    case togglePrecision
}

/// A bindable action for an express key or pen button.
public enum Binding: Equatable {
    case none
    case mouse(button: CGMouseButton)
    case doubleClick(button: CGMouseButton)
    case key(keyCode: CGKeyCode, flags: CGEventFlags)
    case scroll(dx: Int32, dy: Int32)
    /// While held, pen movement is converted to scroll events instead of moving
    /// the cursor. The vendor has the same mode: `RelativeCoords Speed="5"` and
    /// the x0.2 scroll step in `CEventPort::TabletPointToScreenPoint`.
    case wheelMode
    case toggleEraser
    case system(SystemAction)
    case control(ControlAction)

    /// Parse a binding from a config string, an action id, or a catalogue name.
    ///
    ///   "none"
    ///   "mouse:left" / "mouse:right" / "mouse:middle" / "mouse:4"
    ///   "double:left"
    ///   "scroll:up" / "scroll:down" / "scroll:left" / "scroll:right"
    ///   "key:KEYCODE" / "key:KEYCODE+cmd,shift,alt,ctrl"
    ///   "eraser"  |  "wheel"  |  "panel"  |  "monitor"  |  "precision"
    ///   "system:screenKeyboard" / "system:virtualBoard"
    ///   "action:210"   — any vendor Actid
    ///   "Right click"  — any catalogue name
    public static func parse(_ text: String) -> Binding? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.isEmpty || lower == "none" { return Binding.none }

        // Bare keywords, no colon. These are what the UI and sample config write.
        switch lower {
        case "wheel": return .wheelMode
        case "eraser": return .toggleEraser
        case "panel": return .control(.showDriverPanel)
        case "monitor": return .control(.switchMonitor)
        case "precision": return .control(.togglePrecision)
        default: break
        }

        if let action = ActionCatalog.all.first(where: { $0.name.lowercased() == lower }) {
            return action.binding
        }

        let parts = lower.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        switch parts[0] {
        case "mouse":
            guard let button = mouseButton(parts[1]) else { return nil }
            return .mouse(button: button)
        case "double":
            guard let button = mouseButton(parts[1]) else { return nil }
            return .doubleClick(button: button)
        case "key":
            let spec = parts[1].split(separator: "+").map(String.init)
            guard let code = UInt16(spec[0]), let keyCode = CGKeyCode(exactly: code) else { return nil }
            var flags: CGEventFlags = []
            for mod in spec.dropFirst().flatMap({ $0.split(separator: ",") }) {
                switch mod {
                case "cmd", "command": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "alt", "option": flags.insert(.maskAlternate)
                case "ctrl", "control": flags.insert(.maskControl)
                default: return nil
                }
            }
            return .key(keyCode: keyCode, flags: flags)
        case "scroll":
            switch parts[1] {
            case "up": return .scroll(dx: 0, dy: 1)
            case "down": return .scroll(dx: 0, dy: -1)
            case "left": return .scroll(dx: 1, dy: 0)
            case "right": return .scroll(dx: -1, dy: 0)
            default: return nil
            }
        case "eraser":
            return .toggleEraser
        case "wheel":
            return .wheelMode
        case "panel":
            return .control(.showDriverPanel)
        case "monitor":
            return .control(.switchMonitor)
        case "precision":
            return .control(.togglePrecision)
        case "system":
            switch parts[1] {
            case "screenkeyboard": return .system(.screenKeyboard)
            case "virtualboard": return .system(.virtualBoard)
            default: return nil
            }
        case "action":
            guard let id = Int(parts[1]), let action = ActionCatalog.action(id: id) else { return nil }
            return action.binding
        default:
            return nil
        }
    }

    private static func mouseButton(_ name: String) -> CGMouseButton? {
        switch name {
        case "left": return .left
        case "right": return .right
        case "middle", "center": return .center
        default:
            if let n = UInt32(name), n < 32 { return CGMouseButton(rawValue: n) }
            return nil
        }
    }

    /// Canonical config string for this binding.
    public var configString: String {
        switch self {
        case .none: return "none"
        case .mouse(let b): return "mouse:\(Binding.buttonName(b))"
        case .doubleClick(let b): return "double:\(Binding.buttonName(b))"
        case .key(let code, let flags):
            var parts = ["key:\(code)"]
            var mods: [String] = []
            if flags.contains(.maskCommand) { mods.append("cmd") }
            if flags.contains(.maskShift) { mods.append("shift") }
            if flags.contains(.maskAlternate) { mods.append("alt") }
            if flags.contains(.maskControl) { mods.append("ctrl") }
            if !mods.isEmpty { parts.append(mods.joined(separator: ",")) }
            return parts.joined(separator: "+")
        case .scroll(let dx, let dy):
            if dy > 0 { return "scroll:up" }
            if dy < 0 { return "scroll:down" }
            if dx > 0 { return "scroll:left" }
            return "scroll:right"
        case .wheelMode: return "wheel"
        case .toggleEraser: return "eraser"
        case .system(let a): return "system:\(a.rawValue)"
        case .control(.showDriverPanel): return "panel"
        case .control(.switchMonitor): return "monitor"
        case .control(.togglePrecision): return "precision"
        }
    }

    /// Human-readable label for the UI.
    public var displayName: String {
        if self == Binding.none { return "None" }
        if let match = ActionCatalog.all.first(where: { $0.binding == self }) {
            return match.name
        }
        switch self {
        case .none: return "None"
        case .key(let code, let flags):
            var s = "Key \(code)"
            if flags.contains(.maskCommand) { s = "Cmd+" + s }
            if flags.contains(.maskShift) { s = "Shift+" + s }
            if flags.contains(.maskAlternate) { s = "Alt+" + s }
            if flags.contains(.maskControl) { s = "Ctrl+" + s }
            return s
        default: return configString
        }
    }

    private static func buttonName(_ b: CGMouseButton) -> String {
        switch b {
        case .left: return "left"
        case .right: return "right"
        case .center: return "middle"
        default: return String(b.rawValue)
        }
    }
}

/// Posts synthetic events. Requires the Accessibility permission; without it the
/// events are silently dropped, which is why `hasAccessibilityPermission` exists.
public final class EventInjector {

    private let source: CGEventSource?
    /// Normalises the raw tilt value. Defaults to the vendor's own divisor (84.0).
    public var tiltScale: Double = Device.vendorTiltDivisor
    public var invertTiltX = false
    public var invertTiltY = false
    /// Write the pressure into kCGMouseEventPressure as well as the tablet field.
    ///
    /// **This is what makes pressure work in applications.** AppKit's
    /// `NSEvent.pressure` comes from the mouse pressure field, not from
    /// kCGTabletEventPointPressure, and every browser reads NSEvent.pressure. With
    /// only the tablet field set, a web app sees pressure 1.0 whenever the button
    /// is down and 0 otherwise, however hard the pen is pressed. Measured both ways
    /// with `xppen-presscheck`; see docs/PROTOCOL.md.
    public var alsoSetMousePressure = true
    /// Handles actions that need the host UI (open panel, switch monitor, …).
    public var onControlAction: ((ControlAction) -> Void)?

    public init() {
        self.source = CGEventSource(stateID: .privateState)
    }

    public static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Pen

    public func move(to point: CGPoint, pen: PenReport) {
        post(type: .mouseMoved, button: .left, at: point, pen: pen)
    }

    public func penDown(at point: CGPoint, pen: PenReport) {
        let eraser = pen.eraser
        post(type: eraser ? .rightMouseDown : .leftMouseDown,
             button: eraser ? .right : .left, at: point, pen: pen)
    }

    /// A pen move with the tip down. Applications see this as a drag, which is
    /// what a drawing app uses to lay down a stroke.
    public func postDrag(to point: CGPoint, pen: PenReport) {
        let eraser = pen.eraser
        post(type: eraser ? .rightMouseDragged : .leftMouseDragged,
             button: eraser ? .right : .left, at: point, pen: pen)
    }

    public func penUp(at point: CGPoint, pen: PenReport) {
        let eraser = pen.eraser
        post(type: eraser ? .rightMouseUp : .leftMouseUp,
             button: eraser ? .right : .left, at: point, pen: pen)
    }

    private func post(type: CGEventType, button: CGMouseButton, at point: CGPoint, pen: PenReport, clickState: Int64 = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        applyTabletFields(to: event, pen: pen)
        event.post(tap: .cghidEventTap)
    }

    /// Post a pixel-based scroll.
    ///
    /// The location is deliberately **not** set. A scroll event carries a location,
    /// and posting one with an explicit location makes the window server move the
    /// cursor there — measured: a scroll at (100,100) warps the pointer to (100,100).
    /// Leaving it unset scrolls whatever is under the cursor, and the cursor stays
    /// where it is, which is what wheel mode needs.
    public func scroll(deltaX: Int32, deltaY: Int32) {
        guard deltaX != 0 || deltaY != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Buttons

    public func perform(_ binding: Binding, at point: CGPoint, pen: PenReport, isDown: Bool) {
        switch binding {
        case .none:
            return

        case .toggleEraser:
            return  // driver state, handled by Driver

        case .wheelMode:
            return  // driver state, handled by Driver

        case .mouse(let button):
            let type: CGEventType
            switch button {
            case .left: type = isDown ? .leftMouseDown : .leftMouseUp
            case .right: type = isDown ? .rightMouseDown : .rightMouseUp
            default: type = isDown ? .otherMouseDown : .otherMouseUp
            }
            post(type: type, button: button, at: point, pen: pen)

        case .doubleClick(let button):
            guard isDown else { return }
            let downType: CGEventType
            let upType: CGEventType
            switch button {
            case .left: downType = .leftMouseDown; upType = .leftMouseUp
            case .right: downType = .rightMouseDown; upType = .rightMouseUp
            default: downType = .otherMouseDown; upType = .otherMouseUp
            }
            post(type: downType, button: button, at: point, pen: pen, clickState: 2)
            post(type: upType, button: button, at: point, pen: pen, clickState: 2)

        case .key(let keyCode, let flags):
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)

        case .scroll(let dx, let dy):
            if isDown { scroll(deltaX: dx, deltaY: dy) }

        case .system(let action):
            if isDown { performSystem(action) }

        case .control(let action):
            if isDown { onControlAction?(action) }
        }
    }

    private func performSystem(_ action: SystemAction) {
        let path: String
        switch action {
        case .screenKeyboard: path = "/System/Library/CoreServices/Applications/Keyboard Viewer.app"
        case .virtualBoard: path = "/System/Applications/Notes.app"
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Proximity

    /// Attach the tablet device identity to a move so consumers can tell the
    /// source apart. Real proximity events cannot be created through the public
    /// CoreGraphics API (there is no way to set an event's *type*), and the vendor
    /// uses `IOHIDPostEvent` for its proximity path; what applications actually
    /// read is the subtype and the device/vendor IDs.
    public func postProximity(entering: Bool, at point: CGPoint, pen: PenReport) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(TabletField.mouseSubtype, value: TabletField.subtypeTabletPoint)
        event.setIntegerValueField(TabletField.deviceID, value: Int64(Device.productID))
        event.setIntegerValueField(TabletField.vendor1, value: Int64(Device.vendorID))
        event.setIntegerValueField(TabletField.vendor2, value: Int64(Device.productID))
        applyTabletFields(to: event, pen: pen)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Private

    private func applyTabletFields(to event: CGEvent, pen: PenReport) {
        event.setIntegerValueField(TabletField.mouseSubtype, value: TabletField.subtypeTabletPoint)

        event.setDoubleValueField(TabletField.pointX, value: Double(pen.x))
        event.setDoubleValueField(TabletField.pointY, value: Double(pen.y))
        event.setDoubleValueField(TabletField.pointZ, value: 0)
        event.setDoubleValueField(TabletField.pointPressure, value: pen.pressureNormalised)
        if alsoSetMousePressure {
            event.setDoubleValueField(.mouseEventPressure, value: pen.pressureNormalised)
        }

        let rawTiltX = invertTiltX ? -pen.tiltX : pen.tiltX
        let rawTiltY = invertTiltY ? -pen.tiltY : pen.tiltY
        event.setDoubleValueField(TabletField.tiltX, value: Double(rawTiltX) / tiltScale)
        event.setDoubleValueField(TabletField.tiltY, value: Double(-rawTiltY) / tiltScale)
        event.setDoubleValueField(TabletField.rotation, value: 0)
        event.setDoubleValueField(TabletField.tangentialPressure, value: 0)

        var buttons: Int64 = 0
        if pen.tipDown || pen.eraser { buttons |= 1 }
        if pen.penButton1 { buttons |= 2 }
        if pen.penButton2 { buttons |= 4 }
        event.setIntegerValueField(TabletField.pointButtons, value: buttons)

        event.setIntegerValueField(TabletField.deviceID, value: Int64(Device.productID))
        event.setIntegerValueField(TabletField.vendor1, value: Int64(Device.vendorID))
        event.setIntegerValueField(TabletField.vendor2, value: Int64(Device.productID))
    }
}
