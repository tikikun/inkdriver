import Foundation
import XPTabletCore

// xpdriverd — headless driver.
//
// The same driver core the menu-bar app runs; this target exists for scripting,
// debugging and running under launchd without a GUI.
//
// Usage:
//   xpdriverd                       run in the foreground
//   xpdriverd --dry-run             log what it would do, inject nothing
//   xpdriverd --raw                 also log every raw report
//   xpdriverd --config PATH         configuration file to use
//   xpdriverd --print-config        print the effective config and exit
//   xpdriverd --write-default-config  write a starter config and exit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(2)
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

var dryRun = false
var raw = false
var configPath: String?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--dry-run": dryRun = true
    case "--raw": raw = true
    case "--config":
        i += 1
        guard i < args.count else { fail("--config needs a path") }
        configPath = args[i]
    case "--print-config":
        let path = DriverConfig.resolvePath(explicit: nil)
        print("config file: \(path ?? "(none — using defaults)")")
        print(DriverConfig.sample)
        exit(0)
    case "--write-default-config":
        let path = DriverConfig.defaultPath()
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            try DriverConfig.sample.write(toFile: path, atomically: true, encoding: .utf8)
            print("wrote \(path)")
        } catch {
            fail("could not write \(path): \(error)")
        }
        exit(0)
    case "--help", "-h":
        print("""
        xpdriverd — native driver for the XP-Pen Deco 01 V3

          --dry-run               log intended actions, inject nothing
          --raw                   also log raw HID reports
          --config PATH           configuration file to use
          --print-config          print the effective config and exit
          --write-default-config  write a starter config and exit
        """)
        exit(0)
    default:
        fail("unknown option: \(args[i])")
    }
    i += 1
}

if !dryRun && !EventInjector.hasAccessibilityPermission {
    log("Accessibility permission is NOT granted — injected events would be silently dropped.")
    log("  System Settings > Privacy & Security > Accessibility")
    log("  binary: \(CommandLine.arguments[0])")
    EventInjector.requestAccessibilityPermission()
    exit(1)
}

let resolved = DriverConfig.resolvePath(explicit: configPath)
let config = DriverConfig.load(path: resolved)
if let resolved { log("config: \(resolved)") }

let driver = Driver(config: config, dryRun: dryRun)
driver.onEvent = { event in
    switch event {
    case .started: log("driver started\(dryRun ? " (dry run)" : "")")
    case .stopped: log("driver stopped")
    case .tabletConnected(let up): log(up ? "tablet connected" : "tablet disconnected")
    case .proximity(let entering): if raw { log(entering ? "pen entered proximity" : "pen left proximity") }
    case .penDown(let x, let y, let pressure): log("pen down at (\(x), \(y)) pressure=\(pressure)")
    case .penUp: log("pen up")
    case .expressKey(let index, let down): log("express key \(index + 1) \(down ? "down" : "up")")
    case .penButton(let index, let down): log("pen button \(index + 1) \(down ? "down" : "up")")
    case .workspaceChanged(let workspace): log("workspace -> display \(workspace.display)")
    case .message(let text): log(text)
    }
}

driver.start()
if !driver.tabletConnected {
    log("no tablet found (VID 0x\(String(Device.vendorID, radix: 16)) PID 0x\(String(Device.productID, radix: 16)))")
    log("Plug the tablet in, and make sure no other driver holds it:")
    log("  pgrep -fl 'XPPen|XTouchDriver|PenTabletInfo'")
    exit(1)
}

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    driver.stop()
    exit(0)
}
interrupt.resume()

CFRunLoopRun()
