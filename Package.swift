// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AudioFile",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "AudioFile",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
