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

/// USB identity of the XP-Pen Deco 01 V3.
///
/// Confirmed on real hardware (`system_profiler` / IORegistry, 2026):
///   VendorID 0x28BD (10429), ProductID 0x0947 (2375), Product "Deco 01 V3",
///   manufacturer "UGTABLET", transport USB.
///
/// The device exposes **three** HID interfaces, and only one of them carries pen
/// data. This was read directly from the report descriptors with
/// `xppen-probe --descriptor`:
///
///   | Usage page / usage | Report ID | Max in | Max out | Role |
///   | --- | --- | ---: | ---: | --- |
///   | `0x0001` / `0x0002` | 9 | 8  | 1  | Generic-desktop mouse (fallback) |
///   | `0x000D` / `0x0002` | 7 | 10 | 1  | Digitizer pen (unused by the vendor) |
///   | `0xFF0A` / `0x0001` | 2 | 12 | 10 | **Vendor-defined: the real pen stream** |
///
/// The vendor driver's own `CTablet::SwitchDeviceChannel` confirms this: it sends
/// output report 2 and registers its input callback on the interface with
/// `MaxOutputReportSize > 7`.
public enum Device {
    public static let vendorID: Int = 0x28BD   // 10429
    public static let productID: Int = 0x0947  // 2375

    /// Usage page of the vendor-defined interface that carries pen/tablet traffic.
    public static let penUsagePage: Int = 0xFF0A
    public static let penUsage: Int = 0x0001
    public static let penReportID: CFIndex = 2

    /// Input report length on the pen interface, *including* the report-ID byte.
    /// `MaxInputReportSize` property = 12; descriptor declares 11 payload bytes.
    public static let inputReportLength: Int = 12

    /// `MaxOutputReportSize` property = 10; descriptor declares 9 payload bytes.
    /// Output reports are sent with report ID 2 and a 10-byte buffer whose first
    /// byte is the report ID (the IOKit convention for numbered reports).
    public static let outputReportLength: Int = 10

    /// Command that switches the tablet from its fallback mode into full tablet
    /// mode. Confirmed two ways: the vendor driver's `sendPackageAnalysisCommand`
    /// and `SwitchDeviceChannel` both build `02 B0 04` + zero padding, and
    /// OpenTabletDriver's config for this exact model carries
    /// `"OutputInitReport": ["ArAE"]` (base64 → `02 B0 04`).
    public static let initFrame: [UInt8] = [0x02, 0xB0, 0x04]

    /// Active area in millimetres (XP-Pen spec / OTD config).
    public static let activeWidthMM: Double = 254.0
    public static let activeHeightMM: Double = 158.75

    /// Coordinate ceiling. **Provisional** until a full-surface sweep is captured;
    /// OTD's config for this model says 50800 × 31750.
    public static var maxX: UInt32 = 50800
    public static var maxY: UInt32 = 31750

    /// Maximum pressure. Verified on hardware: a hard press ramps the raw value
    /// smoothly to exactly 16383, and the high byte never exceeds 0x3f, so the
    /// field is 14-bit. The vendor applies its `& 0x1f` mask only to devices whose
    /// maximum is <= 0x2000; `CTablet::OnPostTabletMouseData` switches to the full
    /// 16-bit read when the device's maximum is larger, which is our case.
    public static let maxPressure: UInt16 = 16383

    /// Raw tilt ceiling. The vendor clamps tilt to +/-60 before use
    /// (`DAT_10001d040` = 0xC4 = -60, `DAT_10001d050` = 0x3C = 60).
    public static let maxTilt: Int8 = 60

    /// A single device id shared by the proximity event and every tablet point
    /// event. These have to agree: an application that tracks the pen by device id
    /// sees two different devices otherwise. The vendor uses one id throughout
    /// (measured: 5 on both), while we previously reported the product id on the
    /// point events and an unrelated value on the proximity event.
    public static let tabletDeviceID: Int64 = 1

    /// Divisor the vendor applies to raw tilt before writing the CGEvent field
    /// (`DAT_10001f208` = 0x4055000000000000 = 84.0). Used as the default
    /// `tiltScale` so behaviour matches the original driver exactly.
    public static let vendorTiltDivisor: Double = 84.0
}

/// A decoded pen report from the vendor-defined interface.
public struct PenReport: Equatable {
    public var x: UInt32
    public var y: UInt32
    /// 13-bit pressure, 0 ... 8191.
    public var pressure: UInt16
    /// Tilt in raw signed units, roughly -90 ... 90 degrees.
    public var tiltX: Int8
    public var tiltY: Int8
    public var tipDown: Bool
    public var eraser: Bool
    public var penButton1: Bool
    public var penButton2: Bool
    /// True when the pen is within range of the surface (hovering or touching).
    public var inRange: Bool
    /// The raw status byte, kept so unrecognised bits stay visible during bring-up.
    public var status: UInt8

    public init(
        x: UInt32, y: UInt32, pressure: UInt16,
        tiltX: Int8, tiltY: Int8,
        tipDown: Bool, eraser: Bool, penButton1: Bool, penButton2: Bool,
        inRange: Bool, status: UInt8
    ) {
        self.x = x; self.y = y; self.pressure = pressure
        self.tiltX = tiltX; self.tiltY = tiltY
        self.tipDown = tipDown; self.eraser = eraser
        self.penButton1 = penButton1; self.penButton2 = penButton2
        self.inRange = inRange; self.status = status
    }

    public var pressureNormalised: Double {
        min(1.0, Double(pressure) / Double(Device.maxPressure))
    }
}

/// A tablet (express-key) state report.
///
/// Verified on hardware: when an express key is pressed the device sends
/// `report[1] = 0xF0` with a one-hot bit in `report[2]` (key 1 = 0x01 … key 8 =
/// 0x80), and `report[2] = 0` on release.
public struct AuxReport: Equatable {
    /// Button states, index 0 = key 1.
    public var buttons: [Bool]
    public init(buttons: [Bool]) { self.buttons = buttons }
}

public enum DecodedReport: Equatable {
    /// Pen left the surface.
    case outOfRange
    /// Express-key state.
    case aux(AuxReport)
    /// Pen position / pressure / tilt.
    case pen(PenReport)
    /// A device-to-host command reply (`report[1]` in 0xB0...0xBF or 0xF0...0xFF).
    /// Acknowledgements such as `02 B1 04` land here.
    case command(response: UInt8, bytes: [UInt8])
    /// Report we do not recognise yet — surfaced, never silently dropped.
    case unknown(prefix: [UInt8])
}

/// Whether a report counts as the pen touching the surface.
///
/// This lives here, as one function, because getting it wrong is not obvious: the
/// tablet reports pressure while merely hovering. Measured on this unit, the tip
/// switch open still produced pressure up to 877, against a tip-down minimum of
/// 13, so the two ranges overlap and pressure alone cannot separate them. The tip
/// switch is the only reliable signal; a non-zero threshold can only make contact
/// *harder*, never easier.
public enum Contact {
    public static func isTouching(tipDown: Bool, pressure: UInt16, threshold: UInt16) -> Bool {
        threshold > 0 ? (tipDown && pressure >= threshold) : tipDown
    }
}

public enum ProtocolError: Error {
    case tooShort(expected: Int, got: Int)
}

/// Decoder for the 12-byte reports that arrive on the vendor interface.
///
/// Byte map, derived from the vendor driver's `CTablet::OnPostTabletMouseData`
/// (0x10000dd66) and `CTablet::OnEventCallBackEx` (0x10000d820), then confirmed
/// against captured hardware traffic:
///
///     [0]      report ID, always 0x02 on the pen interface
///     [1]      status:
///                bit 0  tip switch (contact)
///                bit 1  pen button 1 (lower barrel)
///                bit 2  pen button 2 (upper barrel)
///                bit 3  eraser
///                bit 4  express-key report (buttons arrive in [2])
///                bit 6  set when the pen is OUT of range
///                high nibble 0xA = pen in range, 0xC = out of range
///     [2..3]   X, low 16 bits, little-endian
///     [4..5]   Y, low 16 bits, little-endian
///     [6]      pressure, low 8 bits
///     [7]      pressure bits 8..13 in the low 6 bits (max 0x3f)
///     [8]      tilt X, signed degrees, -60 ... 60
///     [9]      tilt Y, signed degrees; the vendor negates it for CGEvent tilt Y
///     [10]     X bit 16 (overflow)
///     [11]     Y bit 16 (overflow)
///
/// Express-key reports are `report[1] = 0xF0` with a one-hot bit in `report[2]`.
///
/// The vendor's own expressions, verbatim from the pseudocode, with the 14-bit
/// pressure branch selected because this device's maximum exceeds 0x2000:
///     x        = report[10] << 16 | u16le(report[2])
///     y        = report[11] << 16 | u16le(report[4])
///     pressure = report[7] << 8 | report[6]        (16-bit read, 14 bits used)
///     tiltX    = report[8]           (signed, clamped to +/-60)
///     tiltY    = -(report[9])        (signed, clamped to +/-60)
public enum ReportDecoder {

    public static func decode(_ bytes: [UInt8]) throws -> DecodedReport {
        guard bytes.count >= 10 else {
            throw ProtocolError.tooShort(expected: 10, got: bytes.count)
        }

        let status = bytes[1]

        // Express keys arrive as status 0xF0 with a bitmask in report[2].
        if status == 0xF0 {
            let mask = bytes.count > 2 ? bytes[2] : 0
            return .aux(AuxReport(buttons: (0..<8).map { mask & (1 << UInt8($0)) != 0 }))
        }

        // The vendor's range test is `(status & 0x40) == 0` for "in range".
        if status & 0x40 != 0 || status == 0xC0 {
            return .outOfRange
        }

        // Command / status frames never carry pen data. The vendor's dispatch in
        // `CTablet::OnEventCallBackEx` explicitly excludes `report[1] >= 0xf0`
        // and `(report[1] & 0xf0) == 0xb0` from the pen path.
        let high = status & 0xF0
        if high == 0xB0 {
            return .command(response: status, bytes: Array(bytes.dropFirst(2)))
        }

        guard bytes.count >= 12 else {
            return .unknown(prefix: Array(bytes.prefix(min(9, bytes.count))))
        }

        let x = UInt32(bytes[2]) | (UInt32(bytes[3]) << 8) | (UInt32(bytes[10]) << 16)
        let y = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[11]) << 16)
        let pressure = UInt16(bytes[6]) | (UInt16(bytes[7] & 0x3F) << 8)

        // Express keys are not yet characterised on hardware. If the status high
        // nibble is something other than the pen values 0xA0/0xC0, surface it as
        // unknown so `xppen-probe` shows it instead of guessing.
        if high != 0xA0 {
            return .unknown(prefix: Array(bytes.prefix(min(9, bytes.count))))
        }

        return .pen(PenReport(
            x: x,
            y: y,
            pressure: pressure,
            tiltX: clampTilt(Int8(bitPattern: bytes[8])),
            tiltY: clampTilt(Int8(bitPattern: bytes[9])),
            tipDown: status & 0x01 != 0,
            eraser: status & 0x08 != 0,
            penButton1: status & 0x02 != 0,
            penButton2: status & 0x04 != 0,
            inRange: true,
            status: status
        ))
    }

    private static func clampTilt(_ value: Int8) -> Int8 {
        min(max(value, -Device.maxTilt), Device.maxTilt)
    }

    private static func bits(in bytes: [UInt8], at index: Int, count: Int) -> [Bool] {
        var result: [Bool] = []
        for bit in 0..<count {
            let byteIndex = index + (bit / 8)
            guard byteIndex < bytes.count else { break }
            result.append(bytes[byteIndex] & (1 << UInt8(bit % 8)) != 0)
        }
        return result
    }
}
