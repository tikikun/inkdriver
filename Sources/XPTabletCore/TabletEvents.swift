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

import Foundation
import CoreGraphics
import CTabletEvent

/// Posts genuine tablet events through IOHIDPostEvent.
///
/// `CGEvent` can set a mouse event's *subtype* to tablet point, and that is enough
/// for Chromium and for native AppKit applications. It cannot create a native
/// tablet event, because CoreGraphics has no way to set an event's type, and Apple's
/// event guide states that **proximity events are always native tablet events, never
/// mouse subtypes**.
///
/// That matters because Firefox gates all of its tablet handling behind them: its
/// `nsChildView.mm` keeps a `sIsTabletPointerActivated` flag, sets it only from
/// `tabletProximity:`, and returns early from `convertCocoaTabletPointerEvent`
/// unless it is set. Without a proximity event, Firefox reports `pointerType:
/// "mouse"`, no pressure, and no tilt, however correct the mouse events are.
///
/// IOHIDPostEvent has been deprecated since macOS 11 but remains the only public
/// route to this, and is what the vendor driver uses.
public final class TabletEventPoster {

    private let connect: Int32

    /// False when the IOHIDSystem connection could not be opened, in which case
    /// proximity events are unavailable but everything else still works.
    public let isAvailable: Bool

    public init() {
        let handle = xp_hid_system_connect()
        connect = handle
        isAvailable = handle > 0
    }

    private static let penPointerType: Int32 = 1   // NX_TABLET_POINTER_PEN
    private static let capabilityMask: Int32 = 0x17c7  // vendor constant

    /// Post a mouse move through IOHIDPostEvent carrying tablet point data. This is
    /// the vendor's PostTabletOldMove path; the question is whether it produces an
    /// observable event, given that the native tablet types do not.
    @discardableResult
    public func postMouseMoveWithTablet(at point: CGPoint, tabletX: UInt32, tabletY: UInt32,
                                        pressure: UInt16, tiltX: Int8, tiltY: Int8) -> Int32 {
        guard connect > 0 else { return -1 }
        return xp_post_mouse_move_with_tablet(
            connect,
            Int32(point.x.rounded()), Int32(point.y.rounded()),
            Int32(tabletX), Int32(tabletY), Int32(pressure),
            Int32(tiltX), Int32(tiltY)
        )
    }

    /// Announce that the pen has entered or left the tablet's range.
    @discardableResult
    public func postProximity(entering: Bool, at point: CGPoint) -> Int32 {
        guard connect > 0 else { return -1 }
        return xp_post_tablet_proximity(
            connect,
            Int32(point.x.rounded()), Int32(point.y.rounded()),
            entering ? 1 : 0,
            Self.penPointerType,
            Int32(Device.vendorID), Int32(Device.productID),
            1,
            Self.capabilityMask
        )
    }
}
