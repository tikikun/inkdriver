// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 tikikun
//
// Minimal C shim around IOHIDPostEvent.
//
// IOKit's hidsystem headers cannot be imported from Swift, and CGEvent cannot
// create a native tablet event: it can only set a mouse event's subtype. Apple's
// event guide is explicit that proximity events are always native tablet events,
// never mouse subtypes, so a driver that only uses CGEvent can never tell an
// application that a pen is in range.
//
// Firefox requires exactly that. Its widget code ignores tablet data entirely
// until it has seen a tabletProximity: event, so without this the pen looks like a
// mouse to Firefox and pressure never arrives.
#ifndef CTABLET_EVENT_H
#define CTABLET_EVENT_H

/// Open a connection to IOHIDSystem. Returns 0 on failure.
int xp_hid_system_connect(void);

/// Post a native tablet proximity event (NX_TABLETPROXIMITY).
/// Returns the IOReturn, or -1 if the connection is unusable.
int xp_post_tablet_proximity(int connect, int x, int y, int entering,
                             int pointerType, int vendorID, int tabletID,
                             int pointerID, int capabilityMask);

/// Post a mouse move through IOHIDPostEvent (NX_MOUSEMOVED), carrying tablet
/// point data in the event payload. This is the vendor's CTablet::PostTabletOldMove
/// path: IOHIDPostEvent returns success but produces no native *tablet* event on
/// this macOS, so the question is whether the mouse-move form works.
int xp_post_mouse_move_with_tablet(int connect, int x, int y, int tabletX, int tabletY,
                                   int pressure, int tiltX, int tiltY);

#endif
