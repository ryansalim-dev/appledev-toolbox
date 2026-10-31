// swift-tools-version: 6.0
import PackageDescription

// ToolboxCore holds every parser and generator the app uses. It depends only on
// Foundation so it builds and tests on macOS and Linux (`swift test`).
// The SwiftUI Mac app lives in App/ at the repo root and is generated with XcodeGen (see README).
let package = Package(
    name: "ToolboxCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ToolboxCore", targets: ["ToolboxCore"]),
    ],
    targets: [
        .target(name: "ToolboxCore"),
        .testTarget(
            name: "ToolboxCoreTests",
            dependencies: ["ToolboxCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
