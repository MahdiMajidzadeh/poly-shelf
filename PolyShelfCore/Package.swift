// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PolyShelfCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PolyShelfCore", targets: ["PolyShelfCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "PolyShelfCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PolyShelfCoreTests",
            dependencies: ["PolyShelfCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
