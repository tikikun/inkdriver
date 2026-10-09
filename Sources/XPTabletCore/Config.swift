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

/// User configuration, loaded from a JSON file.
///
/// Search order (first existing file wins):
///   1. the path given with `--config`
///   2. `$XPPEN_DRIVER_CONFIG`
///   3. `~/Library/Application Support/xppen-driver/config.json`
///
/// All keys are optional; anything missing falls back to the defaults below.
/// Run `xpdriverd --print-config` to see the effective values.
public struct DriverConfig: Codable {
    /// Index into the active display list. 0 = main display.
    /// Superseded by `workspace.display`; kept so old configs keep working.
    public var display: Int?
    /// Fraction of the tablet surface to use, centred. 1.0 = full surface.
    public var areaScale: Double?
    /// Offset of the active sub-area, as a fraction of the tablet width/height.
    public var areaOffsetX: Double?
    public var areaOffsetY: Double?
    /// 0, 90, 180 or 270 degrees.
    public var rotation: Int?
    /// Set true to flip an axis.
    public var invertX: Bool?
    public var invertY: Bool?
    /// Raw tilt value that corresponds to full deflection when writing the
    /// CGEvent tilt field. The vendor divides by 84.0 (`DAT_10001f208`), so that
    /// is the default for parity; set 60.0 to normalise against the sensor's
    /// real +/-60 range instead.
    public var tiltScale: Double?
    /// Flip the reported tilt axes independently (the vendor's config carries
    /// `fKX`/`fKY`/`fXLC`/`fYLC` flags for the same purpose).
    public var invertTiltX: Bool?
    public var invertTiltY: Bool?
    /// Additional minimum pressure required for contact, used together with the
    /// tip switch. 0 (the default) relies on the tip switch alone.
    ///
    /// This is deliberately an **AND**, not an alternative: the tablet reports
    /// non-zero pressure while merely hovering (measured up to 877 on this unit,
    /// against a tip-down minimum of 13), so treating "pressure above a floor" as
    /// contact on its own produces phantom clicks.
    public var penDownPressureThreshold: UInt16?
    /// Report zero pressure to applications unless the pen is actually in contact.
    ///
    /// The hardware leaks the sensor reading while hovering. Passing that through
    /// would show pressure in apps when the pen is nowhere near the surface.
    public var zeroPressureOnHover: Bool?
    /// Override the raw coordinate ceiling if a sweep shows different maxima.
    public var maxX: UInt32?
    public var maxY: UInt32?
    /// Full tablet → screen mapping. When absent, the flat keys below are used.
    public var workspace: WorkspaceConfig?
    /// Whether to send the 02 B0 04 tablet-mode handshake at startup.
    public var sendHandshake: Bool?
    /// Open the fallback mouse and digitizer interfaces with exclusive access so
    /// they cannot move the cursor independently.
    public var seizeFallbackInterfaces: Bool?
    /// Multiplier applied to pen movement in wheel mode. The vendor uses a step of
    /// 5 x 0.2 = 1.0 for the default (`RelativeCoords Speed="5"`).
    public var scrollSensitivity: Double?
    /// Reverse the scroll direction while in wheel mode.
    public var scrollInvertX: Bool?
    public var scrollInvertY: Bool?

    /// Bindings for the eight express keys, as binding strings.
    public var expressKeys: [String]?
    /// Binding for the lower pen barrel button.
    public var penButton1: String?
    /// Binding for the upper pen barrel button.
    public var penButton2: String?

    public init() {}

    public static func defaultPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/xppen-driver/config.json").path
    }

    public static func resolvePath(explicit: String?) -> String? {
        if let explicit { return explicit }
        if let env = ProcessInfo.processInfo.environment["XPPEN_DRIVER_CONFIG"], !env.isEmpty { return env }
        let candidate = defaultPath()
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    public static func load(path: String?) -> DriverConfig {
        guard let path, let data = FileManager.default.contents(atPath: path) else {
            return DriverConfig()
        }
        do {
            return try JSONDecoder().decode(DriverConfig.self, from: data)
        } catch {
            FileHandle.standardError.write(
                "warning: could not parse \(path): \(error); using defaults\n".data(using: .utf8)!)
            return DriverConfig()
        }
    }

    // MARK: - Effective values

    public var effectiveRotation: Int { rotation ?? 0 }
    public var effectiveAreaScale: Double { areaScale ?? 1.0 }
    public var effectiveAreaOffsetX: Double { areaOffsetX ?? 0.0 }
    public var effectiveAreaOffsetY: Double { areaOffsetY ?? 0.0 }
    /// The mapping actually used. Migrates the pre-workspace keys
    /// (`display` / `rotation` / `invertX` / `invertY` / `areaScale` /
    /// `areaOffsetX` / `areaOffsetY`) into a `WorkspaceConfig` so existing files
    /// keep working unchanged.
    public var effectiveWorkspace: WorkspaceConfig {
        if let existing = workspace { return existing }
        // Pre-workspace keys become the fallback profile.
        let scale = areaScale ?? 1.0
        return WorkspaceConfig(
            display: display ?? 0,
            mode: .stretch,
            screenRect: .full,
            tabletRect: NormalizedRect(x: areaOffsetX ?? 0,
                                       y: areaOffsetY ?? 0,
                                       width: scale,
                                       height: scale),
            rotation: rotation ?? 0,
            invertX: invertX ?? false,
            invertY: invertY ?? false
        )
    }

    public var effectiveTiltScale: Double { tiltScale ?? Device.vendorTiltDivisor }
    public var effectivePressureThreshold: UInt16 { penDownPressureThreshold ?? 0 }
    public var effectiveZeroPressureOnHover: Bool { zeroPressureOnHover ?? true }
    public var effectiveSendHandshake: Bool { sendHandshake ?? true }
    public var effectiveSeizeFallback: Bool { seizeFallbackInterfaces ?? true }
    public var effectiveScrollSensitivity: Double { scrollSensitivity ?? 1.0 }

    /// Eight express-key bindings. Missing entries default to `.none` so nothing
    /// surprising fires during bring-up.
    public func expressKeyBindings() -> [Binding] {
        var result: [Binding] = Array(repeating: .none, count: 8)
        if let keys = expressKeys {
            for (index, text) in keys.enumerated() where index < result.count {
                if let binding = Binding.parse(text) { result[index] = binding }
            }
        }
        return result
    }

    public func penButtonBinding(_ index: Int) -> Binding {
        let text = index == 0 ? penButton1 : penButton2
        if let text { return Binding.parse(text) ?? Binding.none }
        // Defaults: lower barrel button = right click (vendor default Actid 207),
        // upper barrel button = hold-to-scroll, which is the handy default.
        return index == 0 ? .mouse(button: .right) : .wheelMode
    }

    /// A ready-to-edit default config, written by `--write-default-config`.
    public static let sample = """
    {
      "workspace": {
        "display": 0,
        "switchDisplays": [],
        "profiles": {},
        "mode": "stretch",
        "screenRect": { "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0 },
        "tabletRect": { "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0 },
        "rotation": 0,
        "invertX": false,
        "invertY": false
      },
      "tiltScale": 84.0,
      "invertTiltX": false,
      "invertTiltY": false,
      "penDownPressureThreshold": 0,
      "zeroPressureOnHover": true,
      "sendHandshake": true,
      "seizeFallbackInterfaces": true,
      "scrollSensitivity": 1.0,
      "scrollInvertX": false,
      "scrollInvertY": false,
      "penButton1": "mouse:right",
      "penButton2": "wheel",
      "expressKeys": [
        "none", "none", "none", "none",
        "none", "none", "none", "none"
      ]
    }
    """
}
