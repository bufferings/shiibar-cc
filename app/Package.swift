// swift-tools-version:5.9
// shiibar-cc menu bar app (DESIGN.md §4.5, menubar-design.html). macOS 13+
// (MenuBarExtra window style). Pure/testable logic lives in ShiibarCcCore;
// ShiibarCcApp wires it to SwiftUI, Network.framework (UDS), UserNotifications,
// and subprocess calls into the shiibar-cc CLI.

import PackageDescription

let package = Package(
    name: "ShiibarCcApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "ShiibarCcCore",
            path: "Sources/ShiibarCcCore"
        ),
        .executableTarget(
            name: "ShiibarCcApp",
            dependencies: ["ShiibarCcCore"],
            path: "Sources/ShiibarCcApp"
        ),
        .testTarget(
            name: "ShiibarCcCoreTests",
            dependencies: ["ShiibarCcCore"],
            path: "Tests/ShiibarCcCoreTests"
        ),
    ]
)
