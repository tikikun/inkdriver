// swift-tools-version:5.9
import PackageDescription

// XPPen Deco 01 V3 — native arm64 macOS driver.
//
// Two executables:
//   xppen-probe  : read-only. Dumps raw HID reports so the protocol spec can be
//                  verified against YOUR hardware before trusting the driver.
//   xpdriverd    : the driver. Reads reports, maps coordinates, injects events.
//
// No third-party dependencies on purpose: IOKit + CoreGraphics are system
// frameworks, so this builds natively for arm64 with no Rosetta and no vendor code.

let package = Package(
    name: "XPPenNativeDriver",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "XPTabletCore",
            path: "Sources/XPTabletCore"
        ),
        .executableTarget(
            name: "xppen-probe",
            dependencies: ["XPTabletCore"],
            path: "Sources/xppen-probe"
        ),
        .executableTarget(
            name: "xpdriverd",
            dependencies: ["XPTabletCore"],
            path: "Sources/xpdriverd"
        ),
        .executableTarget(
            name: "xppen-tapcheck",
            dependencies: ["XPTabletCore"],
            path: "Sources/xppen-tapcheck"
        ),
        .executableTarget(
            name: "xppen-menu",
            dependencies: ["XPTabletCore"],
            path: "Sources/xppen-menu"
        )
    ]
)
