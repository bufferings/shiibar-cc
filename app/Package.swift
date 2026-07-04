// swift-tools-version:5.9
// shiibar-cc menu bar app (DESIGN.md §4.5, menubar-design.html). macOS 13+
// (MenuBarExtra window style). Pure/testable logic lives in ShiibarCCCore;
// ShiibarCCApp wires it to SwiftUI, Network.framework (UDS), UserNotifications,
// and subprocess calls into the shiibar-cc CLI.

import PackageDescription

let package = Package(
    name: "ShiibarCCApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "ShiibarCCCore",
            path: "Sources/ShiibarCCCore"
        ),
        .executableTarget(
            name: "ShiibarCCApp",
            dependencies: ["ShiibarCCCore"],
            path: "Sources/ShiibarCCApp"
        ),
        .testTarget(
            name: "ShiibarCCCoreTests",
            dependencies: ["ShiibarCCCore"],
            path: "Tests/ShiibarCCCoreTests"
        ),
    ]
)
