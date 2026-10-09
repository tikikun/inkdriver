// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 tikikun
#include "include/CTabletEvent.h"

#include <string.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include <IOKit/hidsystem/IOLLEvent.h>

int xp_hid_system_connect(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching(kIOHIDSystemClass));
    if (service == MACH_PORT_NULL) {
        return 0;
    }
    io_connect_t connect = MACH_PORT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), kIOHIDParamConnectType, &connect);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        return 0;
    }
    return (int)connect;
}

int xp_post_tablet_proximity(int connect, int x, int y, int entering,
                             int pointerType, int vendorID, int tabletID,
                             int pointerID, int capabilityMask) {
    if (connect <= 0) {
        return -1;
    }
    NXEventData data;
    memset(&data, 0, sizeof(data));
    data.mouse.tablet.proximity.vendorID = (UInt16)vendorID;
    data.mouse.tablet.proximity.tabletID = (UInt16)tabletID;
    data.mouse.tablet.proximity.pointerID = (UInt16)pointerID;
    data.mouse.tablet.proximity.deviceID = 0;
    data.mouse.tablet.proximity.systemTabletID = 0;
    data.mouse.tablet.proximity.vendorPointerType = 0;
    data.mouse.tablet.proximity.pointerSerialNumber = 0;
    data.mouse.tablet.proximity.uniqueID = 0;
    data.mouse.tablet.proximity.capabilityMask = (UInt32)capabilityMask;
    data.mouse.tablet.proximity.pointerType = (UInt8)pointerType;
    data.mouse.tablet.proximity.enterProximity = (UInt8)(entering ? 1 : 0);

    IOGPoint location;
    location.x = (SInt16)x;
    location.y = (SInt16)y;

    return (int)IOHIDPostEvent(connect, NX_TABLETPROXIMITY, location, &data,
                               kNXEventDataVersion, 0, 0);
}

int xp_post_tablet_point(int connect, int x, int y, int tabletX, int tabletY,
                         int tabletZ, int buttons, int pressure,
                         int tiltX, int tiltY, int deviceID) {
    if (connect <= 0) {
        return -1;
    }
    NXEventData data;
    memset(&data, 0, sizeof(data));
    data.mouse.tablet.point.x = (SInt32)tabletX;
    data.mouse.tablet.point.y = (SInt32)tabletY;
    data.mouse.tablet.point.z = (SInt32)tabletZ;
    data.mouse.tablet.point.buttons = (UInt16)buttons;
    data.mouse.tablet.point.pressure = (UInt16)pressure;
    data.mouse.tablet.point.tilt.x = (SInt16)tiltX;
    data.mouse.tablet.point.tilt.y = (SInt16)tiltY;
    data.mouse.tablet.point.rotation = 0;
    data.mouse.tablet.point.tangentialPressure = 0;
    data.mouse.tablet.point.deviceID = (UInt16)deviceID;

    IOGPoint location;
    location.x = (SInt16)x;
    location.y = (SInt16)y;

    return (int)IOHIDPostEvent(connect, NX_TABLETPOINTER, location, &data,
                               kNXEventDataVersion, 0, 0);
}

int xp_post_mouse_move_with_tablet(int connect, int x, int y, int tabletX, int tabletY,
                                   int pressure, int tiltX, int tiltY) {
    if (connect <= 0) {
        return -1;
    }
    NXEventData data;
    memset(&data, 0, sizeof(data));
    data.mouse.tablet.point.x = (SInt32)tabletX;
    data.mouse.tablet.point.y = (SInt32)tabletY;
    data.mouse.tablet.point.z = 0;
    data.mouse.tablet.point.buttons = 0;
    data.mouse.tablet.point.pressure = (UInt16)pressure;
    data.mouse.tablet.point.tilt.x = (SInt16)tiltX;
    data.mouse.tablet.point.tilt.y = (SInt16)tiltY;
    data.mouse.tablet.point.deviceID = 1;

    IOGPoint location;
    location.x = (SInt16)x;
    location.y = (SInt16)y;

    // NX_MOUSEMOVED == 5, the vendor's event type here.
    return (int)IOHIDPostEvent(connect, 5, location, &data, kNXEventDataVersion, 0,
                               kIOHIDSetCursorPosition);
}
