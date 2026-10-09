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
                             int pointerID, int capabilityMask,
                             int deviceID, int systemTabletID, int vendorPointerType) {
    if (connect <= 0) {
        return -1;
    }

    // The vendor passes a *bare* NXTabletProximityData to IOHIDPostEvent, with its
    // fields at offset zero of the buffer. That is not the same thing as an
    // NXEventData, whose tablet union does not begin until +0x10, and passing one of
    // those puts every field 16 bytes out: the kernel then sees a malformed event and
    // stops delivering input afterwards. Recovered from the vendor's
    // CEventPort::PostTabletProximity, and reproduced field for field:
    //
    //   +0x00 vendorID        +0x18 capabilityMask
    //   +0x02 tabletID        +0x1c pointerType
    //   +0x04 pointerID       +0x1d enterProximity
    //   +0x06 deviceID
    //   +0x08 systemTabletID
    //   +0x0a vendorPointerType
    //
    // Coordinates travel in the location argument, not in the buffer.
    unsigned char buf[64];
    memset(buf, 0, sizeof(buf));
    *(unsigned short *)(buf + 0x00) = (unsigned short)vendorID;
    *(unsigned short *)(buf + 0x02) = (unsigned short)tabletID;
    *(unsigned short *)(buf + 0x04) = (unsigned short)pointerID;
    // Same identity as the tablet point events. These used to be the vendor's
    // numbers, hardcoded, which made the proximity announcement describe a device
    // that never sent a stroke: AppKit then reported an unknown pointing device type
    // and an application could not tell pen from eraser.
    *(unsigned short *)(buf + 0x06) = (unsigned short)deviceID;
    *(unsigned short *)(buf + 0x08) = (unsigned short)systemTabletID;
    *(unsigned short *)(buf + 0x0a) = (unsigned short)vendorPointerType;
    *(unsigned int *)(buf + 0x18) = (unsigned int)capabilityMask;
    buf[0x1c] = (unsigned char)pointerType;
    buf[0x1d] = (unsigned char)(entering ? 1 : 0);

    IOGPoint location;
    location.x = (SInt16)x;
    location.y = (SInt16)y;

    return (int)IOHIDPostEvent(connect, NX_TABLETPROXIMITY, location, (NXEventData *)buf,
                               kNXEventDataVersion, 0, kIOHIDSetCursorPosition);
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
