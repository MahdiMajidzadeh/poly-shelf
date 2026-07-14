// swift-tools-version:5.9
// SwiftPM build of the app executable — lets the full app compile and bundle
// without Xcode (see scripts/build-app.sh). The Xcode project (project.yml)
// remains the primary development path once Xcode is installed.
import PackageDescription

let package = Package(
    name: "PolyShelfApp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "PolyShelfCore")
    ],
    targets: [
        .executableTarget(
            name: "PolyShelf",
            dependencies: [
                .product(name: "PolyShelfCore", package: "PolyShelfCore")
            ],
            path: "PolyShelf",
            exclude: ["Support"]
        ),
        // End-to-end smoke test runnable without Xcode/XCTest:
        // swift run polyshelf-smoke
        .executableTarget(
            name: "polyshelf-smoke",
            dependencies: [
                .product(name: "PolyShelfCore", package: "PolyShelfCore")
            ],
            path: "scripts/smoke"
        )
    ]
)
