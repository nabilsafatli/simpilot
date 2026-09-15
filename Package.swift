// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimulatorManagerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SimulatorManagerKit", targets: ["SimulatorManagerKit"])
    ],
    targets: [
        .target(
            name: "SimulatorManagerKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SimulatorManagerKitTests",
            dependencies: ["SimulatorManagerKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
