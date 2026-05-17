// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "metaBrain",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "MetaBrainCore",
            targets: ["MetaBrainCore"]
        ),
        .executable(
            name: "metabrain",
            targets: ["MetaBrainCLI"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/ordo-one/package-benchmark",
            from: "1.32.0",
            traits: []
        ),
        .package(
            url: "https://github.com/x-sheep/swift-property-based.git",
            from: "1.2.0"
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
            name: "MetaBrainCoreBenchmarks",
            dependencies: [
                "MetaBrainCore",
                .product(name: "Benchmark", package: "package-benchmark")
            ],
            path: "Benchmarks/MetaBrainCoreBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
        .executableTarget(
            name: "MetaBrainCoreFuzzer",
            dependencies: [
                "MetaBrainCore"
            ],
            path: "Fuzzers/MetaBrainCoreFuzzer"
        ),
        .testTarget(
            name: "MetaBrainCoreTests",
            dependencies: [
                "MetaBrainCore"
            ]
        ),
        .testTarget(
            name: "MetaBrainCoreFuzzTests",
            dependencies: [
                "MetaBrainCore",
                .product(name: "PropertyBased", package: "swift-property-based")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
