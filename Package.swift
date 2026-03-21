// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentCrew",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "AgentCrew",
            targets: ["AgentCrew"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AgentCrew",
            dependencies: [],
            path: "Sources/AgentCrew",
            exclude: [
                "AgentCrew.entitlements"
            ],
            resources: [
                .process("Assets.xcassets"),
                .process("Resources")
            ]
        )
    ]
)
