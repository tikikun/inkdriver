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

/// The vendor's action catalog, transcribed from the shipped UI strings.
///
/// These IDs are the `Actid` values used in the original driver's `config.xml`
/// and its `language.ini` translation table. Keeping the same numbers means a
/// configuration exported from the vendor app can be translated directly, and it
/// gives the menu-bar UI the same vocabulary the original had.
///
/// Sources:
///   `/Applications/XPPen/XPPenTablet.app/Contents/Resources/language.ini`
///   `/Applications/XPPen/XPPenTablet.app/Contents/Resources/config.xml`
///     (`PenBtn1 Actid="207"`, `PenBtn2 Actid="209"` for Deco 01 V2 / V3 class)
public struct Action: Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let binding: Binding

    public init(id: Int, name: String, binding: Binding) {
        self.id = id
        self.name = name
        self.binding = binding
    }
}

/// macOS virtual key codes used by the shortcut actions.
enum Key {
    static let b: CGKeyCode = 11
    static let e: CGKeyCode = 14
    static let v: CGKeyCode = 9
    static let l: CGKeyCode = 37
    static let f: CGKeyCode = 3
    static let d: CGKeyCode = 2
    static let x: CGKeyCode = 7
    static let s: CGKeyCode = 1
    static let z: CGKeyCode = 6
    static let o: CGKeyCode = 31
    static let n: CGKeyCode = 45
    static let c: CGKeyCode = 8
    static let space: CGKeyCode = 49
    static let tab: CGKeyCode = 48
    static let f5: CGKeyCode = 96
    static let leftBracket: CGKeyCode = 33
    static let rightBracket: CGKeyCode = 30
    static let delete: CGKeyCode = 51
    static let minus: CGKeyCode = 27
    static let equals: CGKeyCode = 24
    static let leftShift: CGKeyCode = 56
    static let leftOption: CGKeyCode = 58
    static let rightOption: CGKeyCode = 61
    static let leftControl: CGKeyCode = 59
    static let f3: CGKeyCode = 99      // Mission Control / Exposé
    static let f4: CGKeyCode = 118     // Launchpad
    static let f11: CGKeyCode = 103    // Show Desktop
}

public enum ActionCatalog {

    /// Every action we can perform, keyed by the vendor's ID.
    public static let all: [Action] = [
        // --- keyboard shortcuts (vendor Actions.1 ... Actions.26) ---
        Action(id: 1, name: "B", binding: .key(keyCode: Key.b, flags: [])),
        Action(id: 2, name: "E", binding: .key(keyCode: Key.e, flags: [])),
        Action(id: 3, name: "Alt", binding: .key(keyCode: Key.leftOption, flags: [])),
        Action(id: 4, name: "Space", binding: .key(keyCode: Key.space, flags: [])),
        Action(id: 5, name: "Cmd+S", binding: .key(keyCode: Key.s, flags: [.maskCommand])),
        Action(id: 6, name: "Cmd+Z", binding: .key(keyCode: Key.z, flags: [.maskCommand])),
        Action(id: 7, name: "Cmd+Alt+Z", binding: .key(keyCode: Key.z, flags: [.maskCommand, .maskAlternate])),
        Action(id: 8, name: "Cmd+Shift+Z", binding: .key(keyCode: Key.z, flags: [.maskCommand, .maskShift])),
        Action(id: 9, name: "V", binding: .key(keyCode: Key.v, flags: [])),
        Action(id: 10, name: "L", binding: .key(keyCode: Key.l, flags: [])),
        Action(id: 11, name: "Cmd+O", binding: .key(keyCode: Key.o, flags: [.maskCommand])),
        Action(id: 12, name: "Cmd+N", binding: .key(keyCode: Key.n, flags: [.maskCommand])),
        Action(id: 13, name: "Cmd+Shift+N", binding: .key(keyCode: Key.n, flags: [.maskCommand, .maskShift])),
        Action(id: 14, name: "Cmd+E", binding: .key(keyCode: Key.e, flags: [.maskCommand])),
        Action(id: 15, name: "F", binding: .key(keyCode: Key.f, flags: [])),
        Action(id: 16, name: "D", binding: .key(keyCode: Key.d, flags: [])),
        Action(id: 17, name: "X", binding: .key(keyCode: Key.x, flags: [])),
        Action(id: 18, name: "Cmd+Delete", binding: .key(keyCode: Key.delete, flags: [.maskCommand])),
        Action(id: 19, name: "Cmd+C", binding: .key(keyCode: Key.c, flags: [.maskCommand])),
        Action(id: 20, name: "Cmd+V", binding: .key(keyCode: Key.v, flags: [.maskCommand])),
        Action(id: 21, name: "Cmd++", binding: .key(keyCode: Key.equals, flags: [.maskCommand])),
        Action(id: 22, name: "Cmd+-", binding: .key(keyCode: Key.minus, flags: [.maskCommand])),
        Action(id: 23, name: "Tab", binding: .key(keyCode: Key.tab, flags: [])),
        Action(id: 24, name: "F5", binding: .key(keyCode: Key.f5, flags: [])),
        Action(id: 25, name: "]", binding: .key(keyCode: Key.rightBracket, flags: [])),
        Action(id: 26, name: "[", binding: .key(keyCode: Key.leftBracket, flags: [])),

        // --- pen / driver functions (vendor Actions.27, 101 ... 131) ---
        Action(id: 27, name: "Eraser (hold)", binding: .eraserHold),
        Action(id: 101, name: "Show driver panel", binding: .control(.showDriverPanel)),
        Action(id: 102, name: "Switch monitor", binding: .control(.switchMonitor)),
        Action(id: 103, name: "Pen / Eraser", binding: .toggleEraser),
        Action(id: 104, name: "Precision mode", binding: .control(.togglePrecision)),
        Action(id: 112, name: "Disabled", binding: Binding.none),
        Action(id: 121, name: "Show Desktop", binding: .key(keyCode: Key.f11, flags: [])),
        Action(id: 122, name: "On-screen keyboard", binding: .system(.screenKeyboard)),
        Action(id: 127, name: "Mission Control", binding: .key(keyCode: Key.f3, flags: [])),
        Action(id: 128, name: "App Exposé", binding: .key(keyCode: Key.f3, flags: [.maskControl])),
        Action(id: 130, name: "Launchpad", binding: .key(keyCode: Key.f4, flags: [])),
        Action(id: 131, name: "Virtual board", binding: .system(.virtualBoard)),

        // --- modifiers and mouse (vendor Actions.201 ... 211) ---
        Action(id: 201, name: "Shift", binding: .key(keyCode: Key.leftShift, flags: [])),
        Action(id: 202, name: "Left Alt", binding: .key(keyCode: Key.leftOption, flags: [])),
        Action(id: 203, name: "Right Alt", binding: .key(keyCode: Key.rightOption, flags: [])),
        Action(id: 204, name: "Ctrl", binding: .key(keyCode: Key.leftControl, flags: [])),
        Action(id: 205, name: "Space", binding: .key(keyCode: Key.space, flags: [])),
        Action(id: 206, name: "Left click", binding: .mouse(button: .left)),
        Action(id: 207, name: "Right click", binding: .mouse(button: .right)),
        Action(id: 208, name: "Middle click", binding: .mouse(button: .center)),
        Action(id: 209, name: "Left double-click", binding: .doubleClick(button: .left)),
        Action(id: 210, name: "Scroll up", binding: .scroll(dx: 0, dy: 1)),
        Action(id: 211, name: "Scroll down", binding: .scroll(dx: 0, dy: -1)),
        Action(id: 212, name: "Scroll left", binding: .scroll(dx: 1, dy: 0)),
        Action(id: 213, name: "Scroll right", binding: .scroll(dx: -1, dy: 0)),
        Action(id: 214, name: "Wheel mode (hold to scroll)", binding: .wheelMode),
        Action(id: 215, name: "Eraser (press to toggle)", binding: .toggleEraser),
    ]

    public static func action(id: Int) -> Action? { all.first { $0.id == id } }

    public static func action(named name: String) -> Action? {
        all.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Actions offered in the UI, grouped for display.
    public static var keyboardShortcuts: [Action] { all.filter { $0.id <= 26 } }
    public static var deviceFunctions: [Action] { all.filter { (27...131).contains($0.id) } }
    public static var mouseAndScroll: [Action] { all.filter { $0.id >= 201 && $0.id <= 213 } }
    public static var special: [Action] { all.filter { $0.id == 214 || $0.id == 215 } }
}
