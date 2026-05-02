// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BepisLoader",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BepisLoader",
            path: "Sources/BepInExMacClient",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ]
)
