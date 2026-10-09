import Foundation
import CoreGraphics
import ApplicationServices
import XPTabletCore

// xppen-tapcheck — verify that tablet data actually reaches the event stream.
//
// Installs a listen-only event tap at the session tap and prints the tablet
// fields of every mouse event it sees. Run `xpdriverd` alongside it and move the
// pen: if pressure and tilt appear here, applications will see them too.
//
// Requires Accessibility permission.
//
// Usage:
//   xppen-tapcheck          print only events that carry tablet data
//   xppen-tapcheck --all    print every mouse event it sees

let printAll = CommandLine.arguments.contains("--all")
/// Marker written into kCGEventSourceUserData so our own posted events can be
/// told apart from anything else in the stream.
let marker: Int64 = 0x0BADF00D
let injectTest = CommandLine.arguments.contains("--inject-test")

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(
        "Accessibility permission is required for an event tap.\n"
        .data(using: .utf8)!)
    exit(1)
}

var seen = 0
var withTablet = 0
var maxPressure = 0.0
var maxAbsTilt = 0.0

let mask: CGEventMask =
    CGEventMask(1 << CGEventType.mouseMoved.rawValue) |
    CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
    CGEventMask(1 << CGEventType.leftMouseUp.rawValue) |
    CGEventMask(1 << CGEventType.leftMouseDragged.rawValue) |
    CGEventMask(1 << CGEventType.rightMouseDown.rawValue) |
    CGEventMask(1 << CGEventType.rightMouseUp.rawValue) |
    CGEventMask(1 << CGEventType.rightMouseDragged.rawValue) |
    CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
    CGEventMask(1 << CGEventType.otherMouseUp.rawValue) |
    CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)

let callback: CGEventTapCallBack = { _, type, event, _ in
    seen += 1
    let subtype = event.getIntegerValueField(.mouseEventSubtype)
    let px = event.getDoubleValueField(.tabletEventPointX)
    let py = event.getDoubleValueField(.tabletEventPointY)
    let pressure = event.getDoubleValueField(.tabletEventPointPressure)
    let tiltX = event.getDoubleValueField(.tabletEventTiltX)
    let tiltY = event.getDoubleValueField(.tabletEventTiltY)
    let buttons = event.getIntegerValueField(.tabletEventPointButtons)
    let location = event.location

    let hasTablet = pressure > 0 || tiltX != 0 || tiltY != 0 || px != 0 || py != 0 || subtype == 1 || subtype == 2
    let userData = event.getIntegerValueField(.eventSourceUserData)
    if hasTablet || userData == marker {
        withTablet += 1
        maxPressure = max(maxPressure, pressure)
        maxAbsTilt = max(maxAbsTilt, abs(tiltX), abs(tiltY))
        print(String(format: "type=%-3d subtype=%lld at=(%.0f,%.0f) tablet=(%.0f,%.0f) pressure=%.4f tilt=(%.3f,%.3f) buttons=%lld marker=%@",
                     type.rawValue, subtype, location.x, location.y, px, py, pressure, tiltX, tiltY, buttons,
                     userData == marker ? "YES" : "-"))
    } else if printAll {
        print(String(format: "type=%-3d subtype=%lld at=(%.0f,%.0f) (no tablet data)",
                     type.rawValue, subtype, location.x, location.y))
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .listenOnly,
                                  eventsOfInterest: mask,
                                  callback: callback,
                                  userInfo: nil) else {
    FileHandle.standardError.write("could not create event tap.\n".data(using: .utf8)!)
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("xppen-tapcheck running — move the pen. \(printAll || injectTest ? "Showing all events." : "Showing tablet events only.")")

if injectTest {
    // Post a marked event built exactly the way EventInjector builds one, then
    // report what the tap sees. If the marker arrives with subtype=1 and the
    // tablet fields intact, injection is correct and any unmarked events in the
    // stream come from somewhere else.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: CGPoint(x: 7, y: 7), mouseButton: .left) else {
            print("could not create event"); exit(1)
        }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.setIntegerValueField(.mouseEventSubtype, value: 1)   // TabletPoint
        event.setDoubleValueField(.tabletEventPointX, value: 12345)
        event.setDoubleValueField(.tabletEventPointY, value: 6789)
        event.setDoubleValueField(.tabletEventPointPressure, value: 0.5)
        event.setDoubleValueField(.tabletEventTiltX, value: 0.25)
        event.setIntegerValueField(.tabletEventPointButtons, value: 1)
        print("--- posting marked event: at=(7,7) tablet=(12345,6789) pressure=0.5 ---")
        event.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            print("--- done (\(seen) events seen, \(withTablet) carried tablet data) ---")
            exit(0)
        }
    }
}

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    print("\n--- \(seen) mouse events, \(withTablet) carried tablet data ---")
    print(String(format: "max pressure %.4f, max |tilt| %.3f", maxPressure, maxAbsTilt))
    exit(0)
}
interrupt.resume()

CFRunLoopRun()
