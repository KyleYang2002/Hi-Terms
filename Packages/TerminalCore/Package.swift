// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .target(
            name: "TerminalCore",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "TerminalCoreTests",
            dependencies: ["TerminalCore"]
        )
    ]
)
