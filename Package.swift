// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipStash",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "Vendor/GRDBEncrypted"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "ClipStashLib",
            dependencies: [
                .product(name: "GRDB", package: "GRDBEncrypted"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "ClipStash"
        ),
        .executableTarget(
            name: "ClipStashApp",
            dependencies: ["ClipStashLib"],
            path: "ClipStashEntry"
        ),
        // Standalone test runner (no XCTest dependency)
        .executableTarget(
            name: "ClipStashTests",
            dependencies: [
                "ClipStashLib",
                .product(name: "GRDB", package: "GRDBEncrypted"),
            ],
            path: "ClipStashTests"
        )
    ]
)
