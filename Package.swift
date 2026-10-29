// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskRecall",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskRecall", targets: ["DeskRecallApp"]),
        .executable(name: "DeskRecallProbe", targets: ["DeskRecallProbe"])
    ],
    targets: [
        .target(name: "DeskRecallCore"),
        .target(name: "DeskRecallPrivateBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("CoreGraphics")]),
        .target(name: "DeskRecallPlatform", dependencies: ["DeskRecallCore", "DeskRecallPrivateBridge"]),
        .executableTarget(name: "DeskRecallApp", dependencies: ["DeskRecallCore", "DeskRecallPlatform"]),
        .executableTarget(name: "DeskRecallProbe", dependencies: ["DeskRecallCore", "DeskRecallPlatform"]),
        .executableTarget(name: "DeskRecallChecks", dependencies: ["DeskRecallCore", "DeskRecallPlatform"], path: "Tests/DeskRecallCoreTests")
    ]
)
