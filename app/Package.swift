// swift-tools-version:5.9
// shiibar-cc menu bar app (DESIGN.md §4.5, menubar-design.html). macOS 14+
// (§8.34: the Conversations window's bundled-SQLite trigram guarantee and
// Ventura's end of updates). Pure/testable logic lives in ShiibarCcCore;
// ConversationsWebPaneKit hosts the Conversations message page (WKWebView —
// §4.6/§8.38); ShiibarCcApp wires everything to SwiftUI, Network.framework
// (UDS), UserNotifications, and subprocess calls into the shiibar-cc CLI.

import PackageDescription

let package = Package(
    name: "ShiibarCcApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "ShiibarCcCore",
            path: "Sources/ShiibarCcCore"
        ),
        // The WKWebView message pane for the Conversations window (DESIGN.md
        // §4.6 "rendering engine", §8.38). A separate library so the page +
        // bridge behavior is testable outside the app executable.
        .target(
            name: "ConversationsWebPaneKit",
            dependencies: ["ShiibarCcCore"],
            path: "Sources/ConversationsWebPaneKit"
        ),
        .executableTarget(
            name: "ShiibarCcApp",
            dependencies: ["ShiibarCcCore", "ConversationsWebPaneKit"],
            path: "Sources/ShiibarCcApp"
        ),
        .testTarget(
            name: "ShiibarCcCoreTests",
            dependencies: ["ShiibarCcCore"],
            path: "Tests/ShiibarCcCoreTests"
        ),
        // Live-page tests (real WKWebView + bridge): malicious transcript
        // input renders as text and never executes (§4.6/§8.38, M39 T5).
        .testTarget(
            name: "ConversationsWebPaneKitTests",
            dependencies: ["ConversationsWebPaneKit", "ShiibarCcCore"],
            path: "Tests/ConversationsWebPaneKitTests"
        ),
        // View-model tests against the app executable target (SwiftPM
        // supports testing executables): the Conversations search pipeline
        // with a stubbed subprocess launcher (M39 T7).
        .testTarget(
            name: "ShiibarCcAppTests",
            dependencies: ["ShiibarCcApp", "ShiibarCcCore"],
            path: "Tests/ShiibarCcAppTests"
        ),
    ]
)
