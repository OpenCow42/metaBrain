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
        ),
        .package(
            url: "git@github.com:OpenCow42/swift-leveldb.git",
            branch: "main"
        )
    ],
    targets: [
        .target(
            name: "MetaBrainCore",
            dependencies: [
                .product(name: "swift-leveldb-zstd", package: "swift-leveldb")
            ]
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
        ),
        .testTarget(
            name: "MetaBrainCoreTests",
            dependencies: [
                "MetaBrainCore"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
