// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TimeToClickup",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TimeToClickup",
            path: "Sources/TimeToClickup"
        )
    ]
)
