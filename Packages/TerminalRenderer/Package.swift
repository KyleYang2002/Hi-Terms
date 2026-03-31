// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalRenderer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TerminalRenderer", targets: ["TerminalRenderer"])
    ],
    dependencies: [
        .package(path: "../TerminalCore")
    ],
    targets: [
        .target(
            name: "TerminalRenderer",
            dependencies: [
                .product(name: "TerminalCore", package: "TerminalCore")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "TerminalRendererTests",
            dependencies: ["TerminalRenderer"]
        )
    ]
)
