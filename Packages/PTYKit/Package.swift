// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PTYKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PTYKit", targets: ["PTYKit"])
    ],
    targets: [
        .target(
            name: "PTYKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "PTYKitTests",
            dependencies: ["PTYKit"]
        )
    ]
)
