import Foundation
import IOKit
import IOKit.hid
import XPTabletCore

// xppen-probe — READ-ONLY bring-up tool.
//
// It enumerates the tablet's HID interfaces, optionally sends the tablet-mode
// handshake, and prints every input report as hex plus its decoding. It never
// posts input events, so it is safe to run alongside another driver.
//
// Usage:
//   xppen-probe                     list interfaces and report IDs
//   xppen-probe --descriptor        print the raw HID report descriptors
//   xppen-probe --watch             stream and decode pen reports
//   xppen-probe --watch --init      send 02 B0 04 first
//   xppen-probe --watch --raw       include the raw hex on every line
//   xppen-probe --watch --all       also show the mouse/digitizer interfaces
//   xppen-probe --stats             print min/max per field when you press Ctrl-C
//
// The pen stream lives on usage page 0xFF0A (report ID 2, 12 bytes). The other
// two interfaces are the fallback mouse and an unused digitizer pen collection.

struct Options {
    var watch = false
    var sendInit = false
    var raw = false
    var descriptor = false
    var all = false
    var stats = false
}

func parseOptions() -> Options {
    var o = Options()
    for arg in CommandLine.arguments.dropFirst() {
        switch arg {
        case "--watch": o.watch = true
        case "--init": o.sendInit = true
        case "--raw": o.raw = true
        case "--all": o.all = true
        case "--stats": o.stats = true
        case "--descriptor": o.descriptor = true
        case "--check-workspace":
            // Verify the tablet -> screen mapping for each mode using a synthetic
            // 2560x1440 display, so the numbers are checkable by hand.
            let display = AreaMapper.DisplayBounds(originX: 0, originY: 0, width: 2560, height: 1440, displayID: 724_053_248)
            let corners: [(String, UInt32, UInt32)] = [
                ("top-left", 0, 0),
                ("top-right", Device.maxX, 0),
                ("bottom-left", 0, Device.maxY),
                ("bottom-right", Device.maxX, Device.maxY),
                ("centre", Device.maxX / 2, Device.maxY / 2),
            ]
            print("synthetic display 2560x1440 at (0,0); tablet aspect "
                  + String(format: "%.4f", Device.activeWidthMM / Device.activeHeightMM))
            for mode in MappingMode.allCases {
                var workspace = WorkspaceConfig()
                workspace.mode = mode
                if mode == .custom {
                    workspace.screenRect = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                }
                let mapper = AreaMapper(workspace: workspace, displays: [display])
                let rect = mapper.targetRect
                print(String(format: "\n%-14s targetRect = (%.0f, %.0f) %.0fx%.0f",
                             (mode.rawValue as NSString).utf8String!,
                             rect.origin.x, rect.origin.y, rect.width, rect.height))
                for (name, x, y) in corners {
                    let p = mapper.map(x: x, y: y)
                    print(String(format: "    %-13s raw(%6u,%6u) -> (%7.1f, %7.1f)",
                                 (name as NSString).utf8String!, x, y, p.x, p.y))
                }
            }

            print("\nrotations (mode stretch, 2560x1440):")
            for angle in [90, 180, 270] {
                var workspace = WorkspaceConfig()
                workspace.rotation = angle
                let mapper = AreaMapper(workspace: workspace, displays: [display])
                let parts = corners.prefix(4).map { name, x, y -> String in
                    let p = mapper.map(x: x, y: y)
                    return String(format: "%@=(%.0f,%.0f)",
                                  name.replacingOccurrences(of: "-", with: ""), p.x, p.y)
                }
                print("  \(angle)°: " + parts.joined(separator: "  "))
            }

            // Three displays, one of them portrait, to prove displays are tracked
            // by their stable ID rather than by list position.
            let second = AreaMapper.DisplayBounds(originX: 2560, originY: 0, width: 2880, height: 5120, displayID: 724_053_249)
            let third = AreaMapper.DisplayBounds(originX: -1920, originY: 0, width: 1920, height: 1080, displayID: 724_053_250)
            let live = [display, second, third]

            print("\ndisplays are keyed by CGDirectDisplayID, so adding one changes nothing:")
            var ws = WorkspaceConfig(displayID: 724_053_249)
            ws.setProfile(DisplayProfile(mode: .fit), forDisplayID: 724_053_248)
            ws.setProfile(DisplayProfile(mode: .custom,
                                         screenRect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
                          forDisplayID: 724_053_249)
            ws = ws.normalize(live)
            print("  target=\(ws.resolvedDisplayID(live).map(String.init) ?? "nil") index=\(ws.targetIndex(live))"
                  + "  profile=\(ws.profile(for: live).mode.rawValue)  hasOwn=\(ws.hasProfile(for: live))")

            print("  switching (empty switch list = every display, in order):")
            var walk = ws
            for _ in 0..<4 {
                guard let next = walk.nextDisplayID(live) else { break }
                walk.displayID = next
                print("    -> id \(next) (index \(walk.targetIndex(live))) profile \(walk.profile(for: live).mode.rawValue)")
            }

            print("  a display that goes away: settings survive, others unaffected")
            var removed = ws
            removed = removed.normalize([display, third])   // the second display unplugged
            print("    target falls back to id \(removed.resolvedDisplayID([display, third]).map(String.init) ?? "nil")"
                  + "  first display profile kept=\(removed.hasProfile(forDisplayID: 724_053_248))")

            print("  legacy index-keyed config migrates once the displays are known:")
            var legacy = WorkspaceConfig(display: 1)
            legacy.profiles = ["1": DisplayProfile(mode: .fit)]
            legacy.switchDisplays = [0, 1, 2]
            let migrated = legacy.normalize(live)
            print("    display index 1 -> id \(migrated.displayID.map(String.init) ?? "nil"),"
                  + " profiles=\(migrated.profiles.keys.sorted()),"
                  + " switchIDs=\(migrated.switchDisplayIDs)")

            print("\ntablet area (mode stretch, corners map to the screen edges):")
            for (label, rect) in [("full", NormalizedRect.full),
                                  ("centre 50%", NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))] {
                var workspace = WorkspaceConfig()
                workspace.tabletRect = rect
                let mapper = AreaMapper(workspace: workspace, displays: [display])
                let a = mapper.map(x: 0, y: 0)
                let b = mapper.map(x: Device.maxX, y: Device.maxY)
                print(String(format: "  %-11s -> (%.0f,%.0f) .. (%.0f,%.0f)",
                             (label as NSString).utf8String!, a.x, a.y, b.x, b.y))
            }
            exit(0)

        case "--check-bindings":
            // Regression check for the config parser: every form the UI and the
            // sample config can write must round-trip.
            let samples = [
                "none", "wheel", "eraser", "panel", "monitor", "precision",
                "mouse:right", "mouse:middle", "double:left",
                "scroll:up", "scroll:down", "scroll:left", "scroll:right",
                "key:1+cmd", "key:6+cmd,shift", "action:207", "action:210",
                "Right click", "Scroll up", "Wheel mode (hold to scroll)",
                "system:screenKeyboard", "bogus",
            ]
            print("binding parse table")
            print("-------------------")
            for text in samples {
                let binding = Binding.parse(text)
                let rendered = binding.map { "\($0.configString)   [\($0.displayName)]" } ?? "nil (falls back to none)"
                print(String(format: "%-34s %@", (text as NSString).utf8String!, rendered))
            }
            print("\naction catalogue (vendor Actid -> name)")
            print("-------------------------------------")
            for action in ActionCatalog.all {
                print(String(format: "%4d  %-28s %@", action.id, (action.name as NSString).utf8String!, action.binding.configString))
            }
            exit(0)
        case "--help", "-h":
            print("""
            xppen-probe — inspect the XP-Pen Deco 01 V3 HID interfaces

              (no args)        list interfaces
              --descriptor     print the HID report descriptors
              --watch          stream and decode input reports
              --init           send the 02 B0 04 tablet-mode handshake first
              --raw            print raw hex with every report
              --all            watch every interface, not just the pen one
              --stats          summarise field ranges on exit (Ctrl-C)
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown option: \(arg)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

let options = parseOptions()

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

let discovery = HIDDiscovery()

guard !discovery.interfaces.isEmpty else {
    print("No HID interface with VID 0x\(String(Device.vendorID, radix: 16)) "
        + "PID 0x\(String(Device.productID, radix: 16)) found.")
    print("Is the tablet plugged in? Is another driver holding it?")
    print("Check with: pgrep -fl 'XPPen|XTouchDriver|PenTabletInfo'")
    exit(1)
}

print("Found \(discovery.interfaces.count) HID interface(s):")
for iface in discovery.interfaces {
    print("  • \(iface.product)  \(iface.label)  in=\(iface.maxInputReportSize) out=\(iface.maxOutputReportSize)")
}

if options.descriptor {
    for iface in discovery.interfaces {
        if let data = IOHIDDeviceGetProperty(iface.device, kIOHIDReportDescriptorKey as CFString) as? Data {
            print("\nReport descriptor — \(iface.label) (\(data.count) bytes):")
            print(hex([UInt8](data)))
        }
    }
}

guard let pen = discovery.penInterface else {
    print("\nNo vendor-defined (0x\(String(Device.penUsagePage, radix: 16))) interface found.")
    exit(1)
}

if !options.watch {
    print("\nPen stream: \(pen.label), report ID \(Device.penReportID), \(Device.inputReportLength) bytes.")
    print("Run `xppen-probe --watch --init`, then move the pen.")
    exit(0)
}

// MARK: - Open

var readers: [HIDReportReader] = []
var openError: IOReturn = kIOReturnSuccess

let targets = options.all ? discovery.interfaces : [pen]
for iface in targets {
    let r = openHIDDevice(iface)
    if r != kIOReturnSuccess {
        FileHandle.standardError.write(
            "failed to open \(iface.label): 0x\(String(UInt32(bitPattern: r), radix: 16))\n".data(using: .utf8)!)
        openError = r
    }
}
if openError != kIOReturnSuccess {
    print("Grant Input Monitoring to this binary:")
    print("  System Settings > Privacy & Security > Input Monitoring")
    exit(1)
}

// MARK: - Handshake

if options.sendInit {
    let result = sendOutputReport(pen, frame: Device.initFrame)
    if result == kIOReturnSuccess {
        print("Sent handshake: \(hex(Device.initFrame))")
    } else {
        print("Handshake failed: IOReturn 0x\(String(UInt32(bitPattern: result), radix: 16))")
    }
}

// MARK: - Stats

struct FieldStats {
    var count = 0
    var xMin = UInt32.max, xMax: UInt32 = 0
    var yMin = UInt32.max, yMax: UInt32 = 0
    var pMin = UInt16.max, pMax: UInt16 = 0
    var tiltXMin: Int8 = .max, tiltXMax: Int8 = .min
    var tiltYMin: Int8 = .max, tiltYMax: Int8 = .min
    var statuses: [UInt8: Int] = [:]

    mutating func add(_ pen: PenReport) {
        count += 1
        xMin = min(xMin, pen.x); xMax = max(xMax, pen.x)
        yMin = min(yMin, pen.y); yMax = max(yMax, pen.y)
        pMin = min(pMin, pen.pressure); pMax = max(pMax, pen.pressure)
        tiltXMin = min(tiltXMin, pen.tiltX); tiltXMax = max(tiltXMax, pen.tiltX)
        tiltYMin = min(tiltYMin, pen.tiltY); tiltYMax = max(tiltYMax, pen.tiltY)
        statuses[pen.status, default: 0] += 1
    }
}

var stats = FieldStats()
var reportCount = 0
let started = Date()

func describe(_ bytes: [UInt8], tag: String) {
    reportCount += 1
    var line = String(format: "%7.3f", Date().timeIntervalSince(started))
    line += " #\(reportCount)"
    if options.all { line += " \(tag)" }
    line += " len=\(bytes.count)"
    if options.raw { line += " \(hex(bytes))" }

    guard tag.hasPrefix("pen") else {
        print(line)
        return
    }

    do {
        switch try ReportDecoder.decode(bytes) {
        case .outOfRange:
            print(line + "  -> out of range")
        case .aux(let aux):
            let pressed = aux.buttons.enumerated().filter { $0.element }.map { String($0.offset + 1) }
            print(line + "  -> buttons: \(pressed.isEmpty ? "none" : pressed.joined(separator: ","))")
        case .command(let response, let payload):
            print(line + String(format: "  -> command reply 0x%02X %@", response, hex(payload)))
        case .pen(let pen):
            stats.add(pen)
            var flags: [String] = []
            if pen.tipDown { flags.append("TIP") }
            if pen.penButton1 { flags.append("B1") }
            if pen.penButton2 { flags.append("B2") }
            if pen.eraser { flags.append("ERASER") }
            let f = flags.isEmpty ? "" : " " + flags.joined(separator: " ")
            print(line + String(format: "  -> x=%-6u y=%-6u p=%-5u (%.3f) tilt=(%d,%d) status=0x%02X%@",
                                pen.x, pen.y, pen.pressure, pen.pressureNormalised,
                                Int(pen.tiltX), Int(pen.tiltY), pen.status, f))
        case .unknown(let prefix):
            print(line + "  -> unrecognised, first bytes \(hex(prefix))")
        }
    } catch {
        print(line + "  -> decode failed: \(error)")
    }
}

for iface in targets {
    let reader = HIDReportReader(interface: iface) { bytes in
        describe(bytes, tag: iface.label)
    }
    readers.append(reader)
}

print("\nWatching \(targets.count) interface(s). Move the pen, press the tip, tilt it, press the")
print("pen buttons and the express keys. Ctrl-C to stop.")

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    if options.stats && stats.count > 0 {
        print("\n--- field ranges over \(stats.count) pen reports ---")
        print(String(format: "x      %u ... %u", stats.xMin, stats.xMax))
        print(String(format: "y      %u ... %u", stats.yMin, stats.yMax))
        print(String(format: "pressure %u ... %u", stats.pMin, stats.pMax))
        print("tiltX  \(stats.tiltXMin) ... \(stats.tiltXMax)")
        print("tiltY  \(stats.tiltYMin) ... \(stats.tiltYMax)")
        print("status bytes: " + stats.statuses.sorted { $0.key < $1.key }
            .map { String(format: "0x%02X×%d", $0.key, $0.value) }.joined(separator: " "))
    }
    exit(0)
}
interrupt.resume()

CFRunLoopRun()
