// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TerminalUI", targets: ["TerminalUI"])
    ],
    dependencies: [
        .package(path: "../TerminalCore"),
        .package(path: "../TerminalRenderer"),
        .package(path: "../PTYKit")
    ],
    targets: [
        .target(
            name: "TerminalUI",
            dependencies: [
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalRenderer", package: "TerminalRenderer"),
                .product(name: "PTYKit", package: "PTYKit")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "TerminalUITests",
            dependencies: ["TerminalUI"]
        )
    ]
)
