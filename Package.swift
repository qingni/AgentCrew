// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentCrew",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentCrew",
            dependencies: ["SwiftTerm"],
            path: "Sources/AgentCrew"
        )
    ]
)
