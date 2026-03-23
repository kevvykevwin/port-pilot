// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PortPilot",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "PortPilotCore",
            path: "Sources/PortPilotCore"
        ),
        .executableTarget(
            name: "PortPilot",
            dependencies: ["PortPilotCore"],
            path: "Sources/PortPilot"
        ),
        .executableTarget(
            name: "PortPilotTests",
            dependencies: ["PortPilotCore"],
            path: "Tests/PortPilotTests"
        )
    ]
)
