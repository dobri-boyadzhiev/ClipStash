// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GRDBEncrypted",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v7),
    ],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
        .library(name: "GRDB-dynamic", type: .dynamic, targets: ["GRDB"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.14.0"),
    ],
    targets: [
        .target(
            name: "GRDBSQLCipher",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ],
            path: "Sources/GRDBSQLCipher"
        ),
        .target(
            name: "GRDB",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
            ],
            swiftSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCipher"),
                .unsafeFlags(["-Xcc", "-DSQLITE_HAS_CODEC"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
