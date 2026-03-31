// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Configuration",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Configuration", targets: ["Configuration"])
    ],
    targets: [
        .target(
            name: "Configuration",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ConfigurationTests",
            dependencies: ["Configuration"]
        )
    ]
)
