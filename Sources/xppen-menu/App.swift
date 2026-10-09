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

import SwiftUI
import AppKit
import XPTabletCore

// MARK: - Model

@MainActor
final class DriverModel: ObservableObject {
    static let shared = DriverModel()

    @Published var config: DriverConfig
    @Published var running = false
    @Published var connected = false
    @Published var proximity = false
    @Published var lastEvent = "Idle"
    @Published var pressure: UInt16 = 0
    @Published var accessibilityGranted = EventInjector.hasAccessibilityPermission
    /// Which tab the settings window shows.
    @Published var settingsTab: Int = 0

    /// Live pen data for the pressure test view.
    let penStream = PenStream()

    let configPath: String
    let driver: Driver

    init() {
        let path = DriverConfig.resolvePath(explicit: nil) ?? DriverConfig.defaultPath()
        // Materialise a starter config on first run so the file exists to edit.
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? DriverConfig.sample.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let loaded = DriverConfig.load(path: path)
        self.configPath = path
        self.config = loaded
        self.driver = Driver(config: loaded)
        driver.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .started: self.running = true; self.lastEvent = "Running"; inkLog("driver started")
            case .stopped:
                self.running = false
                self.connected = false
                self.lastEvent = "Stopped"
                inkLog("driver stopped")
            case .tabletConnected(let up):
                self.connected = up
                self.lastEvent = up ? "Tablet connected" : "Tablet disconnected"
                inkLog(up ? "tablet connected" : "tablet not found")
            case .proximity(let entering):
                self.proximity = entering
            case .penDown(_, _, let p):
                self.pressure = p
                self.lastEvent = "Pen down (pressure \(p))"
            case .penUp:
                self.pressure = 0
                self.lastEvent = "Pen up"
            case .expressKey(let index, let down):
                self.lastEvent = "Express key \(index + 1) \(down ? "down" : "up")"
                inkLog(self.lastEvent)
            case .penButton(let index, let down):
                self.lastEvent = "Pen button \(index + 1) \(down ? "down" : "up")"
                inkLog(self.lastEvent)
            case .workspaceChanged(let workspace):
                // The driver changed the mapping itself (Switch monitor). Adopt it,
                // otherwise the UI keeps showing the display it *used* to target.
                self.config.workspace = workspace
                self.persist()
                self.lastEvent = "Now targeting display \(workspace.display)"
                inkLog("workspace adopted from driver: display \(workspace.display)")
            case .message(let text):
                self.lastEvent = text
                inkLog(text)
            }
        }
        driver.onControlAction = { [weak self] action in
            guard let self else { return }
            if case .showDriverPanel = action { SettingsWindowController.shared.show(model: self) }
        }
        driver.onPenSample = { [weak self] sample in
            MainActor.assumeIsolated { self?.penStream.ingest(sample) }
        }
        refreshPermissions()
    }

    /// Re-read the TCC state. Grants only take effect in a fresh process, so the
    /// app reports the state and asks the user to relaunch.
    func refreshPermissions() {
        accessibilityGranted = EventInjector.hasAccessibilityPermission
        inkLog("accessibility: \(accessibilityGranted ? "granted" : "NOT granted")")
    }

    /// Ask macOS to show the Accessibility prompt. The grant only takes effect in
    /// a fresh process, so the app says so rather than pretending to work.
    func requestAccessibility() {
        let granted = EventInjector.requestAccessibilityPermission()
        accessibilityGranted = granted
        inkLog("accessibility prompt shown; currently \(granted ? "granted" : "NOT granted")")
    }

    var bundlePath: String { Bundle.main.bundlePath }

    // MARK: - Workspace helpers (shared by the menu and the settings window)

    var workspace: WorkspaceConfig { config.effectiveWorkspace }

    /// Live display list, re-read each time (a monitor may have been attached).
    var displays: [AreaMapper.DisplayBounds] { AreaMapper.DisplayBounds.activeDisplays() }

    /// Index of the targeted display, for the pickers.
    var targetIndex: Int { workspace.targetIndex(displays) }

    /// ID of the targeted display.
    var targetDisplayID: UInt32? { workspace.resolvedDisplayID(displays) }

    /// The profile in force for whichever display is currently targeted.
    var currentProfile: DisplayProfile { workspace.profile(for: displays) }

    /// Target a display by its stable ID.
    func selectDisplay(id: UInt32) {
        setWorkspace { $0.displayID = id; $0.display = nil }
    }

    /// Rewrite index-keyed settings to display IDs once, at startup, so the file
    /// on disk is already in the scalable form.
    func migrateWorkspace() {
        let displays = self.displays
        guard !displays.isEmpty else { return }
        let normalized = config.effectiveWorkspace.normalize(displays)
        guard normalized != config.effectiveWorkspace else { return }
        config.workspace = normalized
        persist()
        inkLog("workspace migrated to display IDs (\(displays.count) display(s))")
    }

    /// Called when the display configuration changes: migrate index-keyed settings
    /// to display IDs, drop stale entries, and let the driver re-read the list.
    func displaysChanged() {
        var w = config.effectiveWorkspace.normalize(displays)
        if let id = w.displayID, !displays.contains(where: { $0.displayID == id }) {
            w.displayID = displays.first?.displayID
        }
        config.workspace = w
        apply()
        driver.refreshDisplays()
        lastEvent = "Display configuration changed (\(displays.count) display(s))"
        inkLog(lastEvent)
    }

    func setWorkspace(_ change: (inout WorkspaceConfig) -> Void) {
        var w = config.effectiveWorkspace
        change(&w)
        config.workspace = w
        apply()
    }

    func setWorkspaceLive(_ change: (inout WorkspaceConfig) -> Void) {
        var w = config.effectiveWorkspace
        change(&w)
        config.workspace = w
        applyLive()
    }

    /// Edit the settings of the currently targeted display.
    func setProfile(_ change: (inout DisplayProfile) -> Void) {
        let displays = self.displays
        setWorkspace { $0.updateCurrentProfile(displays, change) }
    }

    func setProfileLive(_ change: (inout DisplayProfile) -> Void) {
        let displays = self.displays
        setWorkspaceLive { $0.updateCurrentProfile(displays, change) }
    }

    func start() { driver.start() }
    func stop() { driver.stop() }
    func toggle() { running ? stop() : start() }

    /// Tear down and re-open the tablet. Needed after the machine wakes from
    /// sleep: the device is re-enumerated, so the handle the driver holds goes
    /// stale and its input callback stops firing.
    func restart(reason: String, delay: TimeInterval = 1.5) {
        inkLog("restarting driver (\(reason))")
        driver.stop()
        running = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.driver.start()
            self.lastEvent = self.driver.tabletConnected ? "Running" : "Tablet not found"
        }
    }

    /// Periodic liveness check. If the device we opened is gone or replaced,
    /// bring the driver back up without waiting for the user to notice.
    func healthCheck() {
        guard running else { return }
        driver.maintenance()
    }

    /// Called when the system wakes.
    func handleWake() {
        restart(reason: "system woke", delay: 2.0)
    }

    /// Persist and apply the current configuration.
    func apply() {
        driver.apply(config: config)
        persist()
    }

    /// Write the config file only.
    func persist() {
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: configPath).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(config)
            try data.write(to: URL(fileURLWithPath: configPath))
        } catch {
            lastEvent = "could not save config: \(error.localizedDescription)"
        }
    }

    /// Apply without writing (for live sliders).
    func applyLive() { driver.apply(config: config) }

    // Settings-window plumbing lives in SettingsWindowController.
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// Diagnostics. Writes to stdout (which launchd may capture) *and* to
/// ~/Library/Logs/inkdriver.log so that `open`-launched runs are logged too.
/// If stdout is already that same file we skip the second write, otherwise every
/// line would appear twice.
func inkLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    print(line, terminator: "")
    fflush(stdout)

    let path = NSHomeDirectory() + "/Library/Logs/inkdriver.log"
    guard let data = line.data(using: .utf8) else { return }
    if stdoutIsSameFile(as: path) { return }

    if let handle = FileHandle(forWritingAtPath: path) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// True when file descriptor 1 already points at `path` (same device + inode).
private func stdoutIsSameFile(as path: String) -> Bool {
    var outStat = Darwin.stat()
    guard fstat(STDOUT_FILENO, &outStat) == 0 else { return false }

    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var fileStat = Darwin.stat()
    guard fstat(fd, &fileStat) == 0 else { return false }
    return outStat.st_dev == fileStat.st_dev && outStat.st_ino == fileStat.st_ino
}

// MARK: - Menu bar

struct MenuContent: View {
    @ObservedObject var model: DriverModel

    var body: some View {
        Text(model.connected ? "Deco 01 V3 — connected" : "Deco 01 V3 — not found")
        Text(model.lastEvent)
        if !model.accessibilityGranted {
            Text("⚠︎ Accessibility permission missing")
            Button("Grant Accessibility…") { model.requestAccessibility() }
        }

        Divider()

        Toggle("Driver enabled", isOn: Binding(
            get: { model.running },
            set: { $0 ? model.start() : model.stop() }))

        Divider()

        penButtonMenu(index: 0, title: "Pen button 1")
        penButtonMenu(index: 1, title: "Pen button 2")

        Menu("Express keys") {
            ForEach(0..<8, id: \.self) { index in
                expressKeyMenu(index: index)
            }
        }

        workAreaMenu

        Divider()

        Button("Pressure test…") {
            model.settingsTab = 3
            SettingsWindowController.shared.show(model: model)
        }
        Button("Settings…") {
            model.settingsTab = 0
            SettingsWindowController.shared.show(model: model)
        }
        Button("Restart driver") { model.restart(reason: "menu") }
        Button("Re-check permissions") { model.refreshPermissions() }
        Button("Reveal config in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.configPath)])
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func penButtonMenu(index: Int, title: String) -> some View {
        Menu(title) {
            bindingPicker(current: index == 0 ? model.config.penButton1 : model.config.penButton2) { text in
                if index == 0 { model.config.penButton1 = text } else { model.config.penButton2 = text }
                model.apply()
            }
        }
    }

    private func expressKeyMenu(index: Int) -> some View {
        let current = model.config.expressKeys.flatMap { index < $0.count ? $0[index] : nil }
        return Menu("Key \(index + 1)") {
            bindingPicker(current: current) { text in
                var keys = model.config.expressKeys ?? Array(repeating: "none", count: 8)
                while keys.count < 8 { keys.append("none") }
                keys[index] = text
                model.config.expressKeys = keys
                model.apply()
            }
        }
    }

    /// A menu of every catalogue action plus the special bindings.
    private func bindingPicker(current: String?, onSelect: @escaping (String) -> Void) -> some View {
        Group {
            Button("None") { onSelect("none") }
            Divider()
            Menu("Mouse & scroll") {
                ForEach(ActionCatalog.mouseAndScroll) { action in
                    Button(action.name) { onSelect(action.binding.configString) }
                }
                Button("Wheel mode (hold to scroll)") { onSelect("wheel") }
            }
            Menu("Device functions") {
                ForEach(ActionCatalog.deviceFunctions) { action in
                    Button(action.name) { onSelect(action.binding.configString) }
                }
            }
            Menu("Keyboard shortcuts") {
                ForEach(ActionCatalog.keyboardShortcuts) { action in
                    Button(action.name) { onSelect(action.binding.configString) }
                }
            }
            Divider()
            Text("Current: " + (current.flatMap { XPTabletCore.Binding.parse($0)?.displayName } ?? "None"))
        }
    }

    private var workAreaMenu: some View {
        Menu("Work area") {
            let displays = AreaMapper.DisplayBounds.activeDisplays()
            Menu("Target display") {
                ForEach(Array(displays.enumerated()), id: \.offset) { index, bounds in
                    Button("Display \(index) — \(Int(bounds.width))x\(Int(bounds.height))\(model.workspace.hasProfile(forDisplayID: bounds.displayID) ? "  •" : "")") {
                        model.selectDisplay(id: bounds.displayID)
                    }
                }
            }
            Divider()
            ForEach(MappingMode.allCases, id: \.self) { mode in
                Button(mode.label + (model.currentProfile.mode == mode ? "  ✓" : "")) {
                    model.setProfile { $0.mode = mode }
                }
            }
            Divider()
            Button("Full tablet area") { model.setProfile { $0.tabletRect = .full } }
            Button("Half area (centre)") {
                model.setProfile { $0.tabletRect = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
            }
            Button("Quarter area (centre)") {
                model.setProfile { $0.tabletRect = NormalizedRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25) }
            }
            Divider()
            Menu("Rotate") {
                ForEach([0, 90, 180, 270], id: \.self) { angle in
                    Button("\(angle)°" + (model.currentProfile.rotation == angle ? "  ✓" : "")) {
                        model.setProfile { $0.rotation = angle }
                    }
                }
            }
            Toggle("Invert X", isOn: profileFlag(\.invertX))
            Toggle("Invert Y", isOn: profileFlag(\.invertY))
        }
    }

    private func profileFlag(_ key: WritableKeyPath<DisplayProfile, Bool>) -> SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { model.currentProfile[keyPath: key] },
            set: { value in model.setProfile { $0[keyPath: key] = value } })
    }
}

// MARK: - Settings window

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(model: DriverModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "InkDriver"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var model: DriverModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            workArea.tabItem { Label("Work area", systemImage: "rectangle.on.rectangle") }.tag(1)
            pen.tabItem { Label("Pen", systemImage: "pencil.tip") }.tag(2)
            PenTestView(model: model, stream: model.penStream)
                .tabItem { Label("Pressure test", systemImage: "waveform.path.ecg") }.tag(3)
            expressKeys.tabItem { Label("Express keys", systemImage: "keyboard") }.tag(4)
        }
        .frame(width: 520, height: 420)
        .padding()
    }

    private var general: some View {
        Form {
            Section("Driver") {
                Toggle("Enable driver", isOn: Binding(
                    get: { model.running }, set: { $0 ? model.start() : model.stop() }))
                LabeledContent("Tablet", value: model.connected ? "connected" : "not found")
                LabeledContent("Last event", value: model.lastEvent)
            }
            Section("Device") {
                Toggle("Send 02 B0 04 handshake", isOn: Binding(
                    get: { model.config.sendHandshake ?? true },
                    set: { model.config.sendHandshake = $0; model.apply() }))
                Toggle("Take over fallback mouse/digitizer interfaces", isOn: Binding(
                    get: { model.config.seizeFallbackInterfaces ?? true },
                    set: { model.config.seizeFallbackInterfaces = $0; model.apply() }))
                LabeledContent("Config file", value: model.configPath)
                LabeledContent("Running from", value: model.bundlePath)
            }
        }
        .formStyle(.grouped)
    }

    private var workArea: some View {
        Form {
            Section("Displays") {
                DisplayLayoutView(
                    displays: model.displays,
                    selected: model.targetIndex,
                    targetRect: currentMapper.targetRect,
                    onSelect: { index in
                        let displays = model.displays
                        if displays.indices.contains(index) { model.selectDisplay(id: displays[index].displayID) }
                    })
                    .frame(height: 150)
                Text("Click a display to target it. The dashed outline is where the tablet area is mapped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Mapping — display \(model.targetIndex)") {
                Picker("Mode", selection: profileValue(\.mode)) {
                    ForEach(MappingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if model.workspace.mode == .allDisplays {
                    Text("Every active display is treated as one surface.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if model.workspace.hasProfile(for: model.displays) {
                        Label("This display has its own settings", systemImage: "checkmark.circle")
                            .font(.caption)
                        Spacer()
                        Button("Use shared defaults") {
                            let displays = model.displays
                            model.setWorkspace { w in
                                if let id = w.resolvedDisplayID(displays) { w.removeProfile(forDisplayID: id) }
                            }
                        }
                    } else {
                        Text("Using the shared defaults — change anything here to give this display its own settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if model.currentProfile.mode == .custom {
                Section("Screen area") {
                    RectEditor(rect: profileRect(\.screenRect),
                               backgroundAspect: displayAspect(selectedDisplay()),
                               onCommit: { model.apply() })
                        .frame(height: 150)
                }
            }

            Section("Tablet area") {
                RectEditor(rect: profileRect(\.tabletRect),
                           backgroundAspect: tabletAspect,
                           onCommit: { model.apply() })
                    .frame(height: 150)
                HStack {
                    Button("Full surface") { model.setProfile { $0.tabletRect = .full } }
                    Button("Centre 50%") {
                        model.setProfile { $0.tabletRect = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
                    }
                }
            }

            Section("Orientation") {
                Picker("Rotation", selection: profileValue(\.rotation)) {
                    Text("0°").tag(0); Text("90°").tag(90)
                    Text("180°").tag(180); Text("270°").tag(270)
                }
                Toggle("Invert X", isOn: profileFlag(\.invertX))
                Toggle("Invert Y", isOn: profileFlag(\.invertY))
            }

            Section("Screen switching") {
                Text("Bind a pen button or express key to “Switch monitor” to cycle these displays. Each display keeps its own mapping.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(AreaMapper.DisplayBounds.activeDisplays().enumerated()), id: \.offset) { index, bounds in
                    Toggle("Display \(index) — \(Int(bounds.width))x\(Int(bounds.height))",
                           isOn: switchDisplayToggle(bounds.displayID))
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Workspace bindings

    private var tabletAspect: Double { Device.activeWidthMM / Device.activeHeightMM }

    private var currentMapper: AreaMapper {
        AreaMapper(workspace: model.workspace,
                   displays: AreaMapper.DisplayBounds.activeDisplays())
    }

    private func selectedDisplay() -> AreaMapper.DisplayBounds {
        let displays = model.displays
        guard !displays.isEmpty else { return .main() }
        return displays[min(max(model.targetIndex, 0), displays.count - 1)]
    }

    private func displayAspect(_ display: AreaMapper.DisplayBounds) -> Double {
        display.height > 0 ? display.width / display.height : 16.0 / 9.0
    }

    private func profileValue<T: Equatable>(_ key: WritableKeyPath<DisplayProfile, T>) -> SwiftUI.Binding<T> {
        SwiftUI.Binding(
            get: { model.currentProfile[keyPath: key] },
            set: { value in model.setProfile { $0[keyPath: key] = value } })
    }

    private func profileRect(_ key: WritableKeyPath<DisplayProfile, NormalizedRect>) -> SwiftUI.Binding<NormalizedRect> {
        SwiftUI.Binding(
            get: { model.currentProfile[keyPath: key] },
            set: { value in model.setProfileLive { $0[keyPath: key] = value } })
    }

    private func profileFlag(_ key: WritableKeyPath<DisplayProfile, Bool>) -> SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { model.currentProfile[keyPath: key] },
            set: { value in model.setProfile { $0[keyPath: key] = value } })
    }

    private func switchDisplayToggle(_ id: UInt32) -> SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: {
                let list = model.workspace.switchDisplayIDs
                return list.isEmpty || list.contains(id)
            },
            set: { on in
                let all = model.displays.map(\.displayID)
                model.setWorkspace { w in
                    // An empty list means "all"; materialise it before editing.
                    var list = w.switchDisplayIDs.isEmpty ? all : w.switchDisplayIDs
                    if on { if !list.contains(id) { list.append(id) } }
                    else { list.removeAll { $0 == id } }
                    w.switchDisplayIDs = list.sorted()
                    w.switchDisplays = []
                }
            })
    }

    private var pen: some View {
        Form {
            Section("Pressure") {
                Stepper("Tip threshold: \(model.config.penDownPressureThreshold ?? 1)",
                        value: Binding(
                            get: { Int(model.config.penDownPressureThreshold ?? 1) },
                            set: { model.config.penDownPressureThreshold = UInt16(max(0, $0)); model.apply() }),
                        in: 0...200)
                Text("Pressure is 14-bit (0…16383). A threshold of 0 uses the tip switch alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tilt") {
                Labeled("Tilt scale", value: Binding(
                    get: { model.config.tiltScale ?? Device.vendorTiltDivisor },
                    set: { model.config.tiltScale = $0; model.applyLive() }), range: 30...120)
                Toggle("Invert tilt X", isOn: Binding(
                    get: { model.config.invertTiltX ?? false },
                    set: { model.config.invertTiltX = $0; model.apply() }))
                Toggle("Invert tilt Y", isOn: Binding(
                    get: { model.config.invertTiltY ?? false },
                    set: { model.config.invertTiltY = $0; model.apply() }))
            }
            Section("Buttons") {
                BindingRow(title: "Pen button 1", text: Binding(
                    get: { model.config.penButton1 ?? "mouse:right" },
                    set: { model.config.penButton1 = $0; model.apply() }))
                BindingRow(title: "Pen button 2", text: Binding(
                    get: { model.config.penButton2 ?? "wheel" },
                    set: { model.config.penButton2 = $0; model.apply() }))
                Labeled("Scroll sensitivity", value: Binding(
                    get: { model.config.scrollSensitivity ?? 1.0 },
                    set: { model.config.scrollSensitivity = $0; model.applyLive() }), range: 0.1...5.0)
                Toggle("Reverse scroll up/down", isOn: SwiftUI.Binding(
                    get: { model.config.scrollInvertY ?? false },
                    set: { model.config.scrollInvertY = $0; model.apply() }))
                Toggle("Reverse scroll left/right", isOn: SwiftUI.Binding(
                    get: { model.config.scrollInvertX ?? false },
                    set: { model.config.scrollInvertX = $0; model.apply() }))
            }
        }
        .formStyle(.grouped)
    }

    private var expressKeys: some View {
        Form {
            Section("Express keys") {
                ForEach(0..<8, id: \.self) { index in
                    BindingRow(title: "Key \(index + 1)", text: Binding(
                        get: { expressKeyValue(index) },
                        set: { setExpressKey(index, $0) }))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func expressKeyValue(_ index: Int) -> String {
        let keys = model.config.expressKeys ?? []
        return index < keys.count ? keys[index] : "none"
    }

    private func setExpressKey(_ index: Int, _ value: String) {
        var keys = model.config.expressKeys ?? Array(repeating: "none", count: 8)
        while keys.count < 8 { keys.append("none") }
        keys[index] = value
        model.config.expressKeys = keys
        model.apply()
    }
}

/// Draws every active display to scale, highlights the targeted one, and shows
/// where the tablet area lands on it — a virtual picture of the monitor layout.
struct DisplayLayoutView: View {
    let displays: [AreaMapper.DisplayBounds]
    let selected: Int
    let targetRect: CGRect?
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let union = displays.dropFirst().reduce(displays.first?.rect ?? .zero) { $0.union($1.rect) }
            let inset: CGFloat = 8
            let usableW = max(geo.size.width - inset * 2, 1)
            let usableH = max(geo.size.height - inset * 2, 1)
            let scale = min(usableW / max(union.width, 1), usableH / max(union.height, 1))
            let baseX = inset + (usableW - union.width * scale) / 2 - union.minX * scale
            let baseY = inset + (usableH - union.height * scale) / 2 - union.minY * scale

            ZStack(alignment: .topLeading) {
                ForEach(Array(displays.enumerated()), id: \.offset) { index, display in
                    let r = display.rect
                    let frame = CGRect(x: baseX + r.minX * scale, y: baseY + r.minY * scale,
                                       width: max(r.width * scale, 8), height: max(r.height * scale, 8))
                    let isSelected = index == selected

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.45),
                                          lineWidth: isSelected ? 2 : 1)
                        Text("\(index)")
                            .font(.caption2).monospacedDigit()
                            .padding(3)

                        if isSelected, let target = targetRect {
                            let t = CGRect(x: baseX + target.minX * scale, y: baseY + target.minY * scale,
                                           width: max(target.width * scale, 3), height: max(target.height * scale, 3))
                            Rectangle()
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
                                .frame(width: t.width, height: t.height)
                                .offset(x: t.minX - frame.minX, y: t.minY - frame.minY)
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .onTapGesture { onSelect(index) }
                }
            }
        }
    }
}

/// A draggable, resizable rectangle over a surface of a given aspect ratio.
/// Used to pick the active tablet area and the screen area.
struct RectEditor: View {
    @SwiftUI.Binding var rect: NormalizedRect
    var backgroundAspect: Double
    var onCommit: () -> Void

    @State private var moveStart: NormalizedRect?
    @State private var resizeStart: NormalizedRect?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let frame = CGRect(x: rect.x * size.width, y: rect.y * size.height,
                               width: rect.width * size.width, height: rect.height * size.height)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: max(frame.width, 8), height: max(frame.height, 8))
                    .offset(x: frame.minX, y: frame.minY)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let base = moveStart ?? rect
                                if moveStart == nil { moveStart = base }
                                rect = NormalizedRect(
                                    x: base.x + value.translation.width / size.width,
                                    y: base.y + value.translation.height / size.height,
                                    width: base.width, height: base.height).clamped()
                            }
                            .onEnded { _ in moveStart = nil; onCommit() }
                    )

                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    .frame(width: 13, height: 13)
                    .offset(x: frame.maxX - 6.5, y: frame.maxY - 6.5)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let base = resizeStart ?? rect
                                if resizeStart == nil { resizeStart = base }
                                rect = NormalizedRect(
                                    x: base.x, y: base.y,
                                    width: base.width + value.translation.width / size.width,
                                    height: base.height + value.translation.height / size.height).clamped()
                            }
                            .onEnded { _ in resizeStart = nil; onCommit() }
                    )
            }
        }
        .aspectRatio(backgroundAspect, contentMode: .fit)
        .padding(.vertical, 4)
    }
}

/// A labelled slider that applies live but only writes the file on release.
struct Labeled: View {
    let title: String
    @SwiftUI.Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, value: SwiftUI.Binding<Double>, range: ClosedRange<Double>) {
        self.title = title
        self._value = value
        self.range = range
    }

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(String(format: "%.2f", value)).monospacedDigit().frame(width: 48)
        }
    }
}

/// A row that lets the user pick an action from the vendor catalogue.
struct BindingRow: View {
    let title: String
    @SwiftUI.Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: $text) {
                Text("None").tag("none")
                Section("Mouse & scroll") {
                    ForEach(ActionCatalog.mouseAndScroll) { action in
                        Text(action.name).tag(action.binding.configString)
                    }
                    Text("Wheel mode (hold to scroll)").tag("wheel")
                }
                Section("Device functions") {
                    ForEach(ActionCatalog.deviceFunctions) { action in
                        Text(action.name).tag(action.binding.configString)
                    }
                }
                Section("Keyboard shortcuts") {
                    ForEach(ActionCatalog.keyboardShortcuts) { action in
                        Text(action.name).tag(action.binding.configString)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        // Single instance only. The login agent execs the binary directly while
        // `open` launches it through LaunchServices, so without this guard a
        // manual launch would add a second driver fighting over the tablet.
        if let bundleID = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        inkLog("launched from \(Bundle.main.bundlePath)")
        installRecoveryHooks()
        Task { @MainActor in DriverModel.shared.migrateWorkspace() }
        if !EventInjector.hasAccessibilityPermission {
            inkLog("Accessibility not granted — asking macOS to prompt")
            _ = EventInjector.requestAccessibilityPermission()
        }

        Task { @MainActor in DriverModel.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private var wakeObservers: [NSObjectProtocol] = []
    private var healthTimer: Timer?

    /// React to sleep/wake and keep an eye on the device.
    private func installRecoveryHooks() {
        let centre = NSWorkspace.shared.notificationCenter
        // A monitor was attached, removed or rearranged.
        // Posted on the default centre, not NSApplication's own.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                DriverModel.shared.displaysChanged()
            }

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let observer = centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                inkLog("system woke")
                DriverModel.shared.handleWake()
            }
            wakeObservers.append(observer)
        }

        // Every 2s: keeps the tablet in tablet mode while the pen is idle, and
        // reopens it if the device has gone away.
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            DriverModel.shared.healthCheck()
        }
        // Common modes so the check still runs while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }
}

@main
struct XPPenMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = DriverModel.shared

    var body: some Scene {
        MenuBarExtra("InkDriver", systemImage: "pencil.tip") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}
