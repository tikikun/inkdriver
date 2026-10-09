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
/// The identity must be the same one the tablet point events carry. An application
/// matches a proximity announcement to the strokes that follow by device id, and if
/// the two disagree it cannot tell what is drawing, so it reports an unknown pointing
/// device type and eraser mode never arrives. Pass the same deviceID the point events
/// use, and the pointer type (1 pen, 3 eraser).
int xp_post_tablet_proximity(int connect, int x, int y, int entering,
                             int pointerType, int vendorID, int tabletID,
                             int pointerID, int capabilityMask,
                             int deviceID, int systemTabletID, int vendorPointerType);

/// Post a native tablet point event (NX_TABLETPOINTER).
int xp_post_tablet_point(int connect, int x, int y, int tabletX, int tabletY,
                         int tabletZ, int buttons, int pressure,
                         int tiltX, int tiltY, int deviceID);

#endif
