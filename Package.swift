// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "metaBrain",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MetaBrainCore",
            targets: ["MetaBrainCore"]
        ),
        .executable(
            name: "metabrain",
            targets: ["MetaBrainCLI"]
        ),
        .executable(
            name: "MetaBrainApp",
            targets: ["MetaBrainApp"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "MetaBrainCore"
        ),
        .executableTarget(
            name: "MetaBrainCLI",
            dependencies: [
                "MetaBrainCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "MetaBrainApp",
            dependencies: [
                "MetaBrainCore"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
