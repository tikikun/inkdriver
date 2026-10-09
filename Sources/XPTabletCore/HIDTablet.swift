import Foundation
import IOKit
import IOKit.hid

/// The three HID interfaces the Deco 01 V3 exposes, and which one matters.
public enum InterfaceRole: String {
    /// Usage page 0xFF0A — the vendor-defined interface. Pen and express-key
    /// traffic arrives here as 12-byte report 2. This is the one to use.
    case pen
    /// Usage page 0x0001/0x0002 — generic desktop mouse. Fallback mode only.
    case mouse
    /// Usage page 0x000D/0x0002 — a standard digitizer-pen interface. The vendor
    /// ignores it for this device, so we do too.
    case digitizer
    case other
}

/// One openable HID interface belonging to the tablet.
public struct TabletInterface {
    public let device: IOHIDDevice
    public let usagePage: Int
    public let usage: Int
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int
    public let product: String
    public let role: InterfaceRole

    public var label: String {
        "\(role.rawValue)[page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16))]"
    }
}

public enum HIDError: Error, CustomStringConvertible {
    case managerOpenFailed(IOReturn)
    case deviceOpenFailed(IOReturn)
    case noDevice

    public var description: String {
        switch self {
        case .managerOpenFailed(let r):
            return "IOHIDManagerOpen failed: 0x\(String(UInt32(bitPattern: r), radix: 16)) — grant Input Monitoring to this binary"
        case .deviceOpenFailed(let r):
            return "IOHIDDeviceOpen failed: 0x\(String(UInt32(bitPattern: r), radix: 16)) — grant Input Monitoring to this binary"
        case .noDevice:
            return "no matching HID interface found"
        }
    }
}

/// Enumerates the tablet's HID interfaces. Keep the instance alive for as long as
/// you use the devices it hands out — the underlying IOHIDManager owns them.
public final class HIDDiscovery {
    public let manager: IOHIDManager
    public private(set) var interfaces: [TabletInterface] = []

    public init(vendorID: Int = Device.vendorID, productID: Int = Device.productID, settle: TimeInterval = 0.4) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ] as CFDictionary)
        // kCFRunLoopCommonModes, not the default mode: opening a menu bar menu or a
        // modal sheet runs AppKit's event-tracking loop, which is a different mode.
        // Registered only for the default mode the driver goes deaf the moment a
        // menu opens, and the pen appears frozen.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        _ = CFRunLoopRunInMode(.defaultMode, settle, false)
        refresh()
    }

    public func refresh() {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            interfaces = []
            return
        }
        interfaces = set.map { device in
            let page = intProperty(device, kIOHIDPrimaryUsagePageKey) ?? 0
            let usage = intProperty(device, kIOHIDPrimaryUsageKey) ?? 0
            let role: InterfaceRole
            if page == Device.penUsagePage { role = .pen }
            else if page == 0x0D { role = .digitizer }
            else if page == 0x01 { role = .mouse }
            else { role = .other }
            return TabletInterface(
                device: device,
                usagePage: page,
                usage: usage,
                maxInputReportSize: intProperty(device, kIOHIDMaxInputReportSizeKey) ?? 0,
                maxOutputReportSize: intProperty(device, kIOHIDMaxOutputReportSizeKey) ?? 0,
                product: stringProperty(device, kIOHIDProductKey) ?? "(unnamed)",
                role: role
            )
        }
        .sorted { $0.role.rawValue < $1.role.rawValue }
    }

    public var penInterface: TabletInterface? {
        interfaces.first { $0.role == .pen }
    }

    // MARK: - Properties

    public func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    public func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

/// Owns one open HID device and delivers its input reports to a Swift closure.
///
/// `IOHIDReportCallback` is `@convention(c)`, so the closure cannot capture
/// anything. State travels through a boxed `Handler` passed as the ref-context
/// and kept alive by this object.
public final class HIDReportReader {
    private final class Handler {
        let onReport: ([UInt8]) -> Void
        let label: String
        init(label: String, onReport: @escaping ([UInt8]) -> Void) {
            self.label = label
            self.onReport = onReport
        }
    }

    private static let trampoline: IOHIDReportCallback = { refcon, _, _, _, _, report, length in
        guard let refcon else { return }
        let handler = Unmanaged<Handler>.fromOpaque(refcon).takeUnretainedValue()
        handler.onReport(Array(UnsafeBufferPointer(start: report, count: length)))
    }

    /// Readers are registered with IOKit for the life of the process and own the
    /// callback context (the boxed `Handler`) plus the report buffer. If a reader
    /// were deallocated while the callback was still registered, the next report
    /// would fault in freed memory — so every instance pins itself here.
    private static var retained: [HIDReportReader] = []

    public let interface: TabletInterface
    private let handler: Handler
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 1024

    public init(interface: TabletInterface, onReport: @escaping ([UInt8]) -> Void) {
        self.interface = interface
        self.handler = Handler(label: interface.label, onReport: onReport)
        self.buffer = .allocate(capacity: bufferSize)
        IOHIDDeviceRegisterInputReportCallback(
            interface.device, buffer, bufferSize,
            HIDReportReader.trampoline,
            Unmanaged.passUnretained(handler).toOpaque()
        )
        // Common modes, so reports keep arriving while a menu or modal panel is up.
        IOHIDDeviceScheduleWithRunLoop(interface.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        HIDReportReader.retained.append(self)
    }

    deinit { buffer.deallocate() }

    /// Detach the callback so no further reports are delivered.
    public func unregister() {
        IOHIDDeviceRegisterInputReportCallback(interface.device, buffer, 0, nil, nil)
        HIDReportReader.retained.removeAll { $0 === self }
    }
}

/// Sends a numbered output report to the pen interface.
///
/// IOKit's convention for numbered reports: pass the report ID both as the
/// `reportID` argument **and** as the first byte of the buffer. The vendor driver
/// does exactly this (`IOHIDDeviceSetReport(dev, 1, 2, buf, MaxOutputReportSize)`
/// with `buf[0] = 0x02`).
@discardableResult
public func sendOutputReport(_ interface: TabletInterface, frame: [UInt8], reportID: CFIndex = Device.penReportID, length: Int? = nil) -> IOReturn {
    let size = length ?? max(interface.maxOutputReportSize, frame.count)
    var buffer = frame
    if buffer.count < size { buffer += [UInt8](repeating: 0, count: size - buffer.count) }
    if buffer.count > size { buffer = Array(buffer.prefix(size)) }
    return buffer.withUnsafeBufferPointer {
        IOHIDDeviceSetReport(interface.device, kIOHIDReportTypeOutput, reportID, $0.baseAddress!, $0.count)
    }
}

/// Opens a HID device for reading. Without this the input callback never fires.
@discardableResult
public func openHIDDevice(_ interface: TabletInterface) -> IOReturn {
    IOHIDDeviceOpen(interface.device, IOOptionBits(kIOHIDOptionsTypeNone))
}

/// IORegistry entry id of a HID device.
///
/// This is stable for as long as the physical device stays connected, and changes
/// when it is unplugged and replugged or re-enumerated — which is exactly what
/// happens across a sleep/wake cycle. Comparing it is how the driver notices that
/// the `IOHIDDevice` it holds has become a stale handle.
public func registryEntryID(of device: IOHIDDevice) -> UInt64? {
    let service = IOHIDDeviceGetService(device)
    guard service != 0 else { return nil }
    var identifier: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { return nil }
    return identifier
}
