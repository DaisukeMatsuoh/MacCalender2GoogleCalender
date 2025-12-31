// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacCalendarSync",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MacCalendarSync",
            targets: ["MacCalendarSync"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MacCalendarSync",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "MacCalendarSyncTests",
            dependencies: ["MacCalendarSync"],
            path: "Tests"
        )
    ]
)
