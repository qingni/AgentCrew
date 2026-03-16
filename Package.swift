// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentCrew",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AgentCrew",
            dependencies: [],
            path: "Sources/AgentCrew"
        )
    ]
)
