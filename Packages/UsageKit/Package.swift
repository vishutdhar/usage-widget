// swift-tools-version: 6.0
import PackageDescription

// Shared code for the Usage Widget app and its widget extension.
//
// UsageCore       pure model: snapshot schema, cswap mapping, thresholds,
//                 display rows, change detection, atomic file writes.
//                 Linked by both the app and the widget.
// UsageAgentCore  the agent's side: runs cswap and writes snapshots.
//                 Linked by the app only, so the widget never shells out.
// UsageWidgetUI   the SwiftUI widget views. Linked by the widget, and by
//                 the render tests.
let package = Package(
    name: "UsageKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .library(name: "UsageAgentCore", targets: ["UsageAgentCore"]),
        .library(name: "UsageWidgetUI", targets: ["UsageWidgetUI"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .target(name: "UsageAgentCore", dependencies: ["UsageCore"]),
        .target(name: "UsageWidgetUI", dependencies: ["UsageCore"]),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "UsageAgentCoreTests",
            dependencies: ["UsageAgentCore", "UsageCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "UsageWidgetUITests",
            dependencies: ["UsageWidgetUI", "UsageCore"],
            exclude: ["Approved"]  // read from the source tree, not bundled
        ),
    ]
)
