// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentOrbit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "AgentOrbit",
            targets: ["AgentOrbit"]
        )
    ],
    targets: [
        .target(
            name: "AgentOrbitCore",
            path: "Sources/AgentOrbitCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AgentOrbit",
            dependencies: ["AgentOrbitCore"],
            path: "Sources/AgentOrbit"
        ),
        .testTarget(
            name: "AgentOrbitTests",
            dependencies: ["AgentOrbitCore"],
            path: "Tests/AgentOrbitTests"
        )
    ]
)
