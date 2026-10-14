// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoSync",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .library(name: "SMBAdapter", targets: ["SMBAdapter"]),
        .library(name: "PhotoSource", targets: ["PhotoSource"]),
    ],
    dependencies: [
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "4.0.0"),
    ],
    targets: [
        .target(name: "SyncCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "SMBAdapter",
            dependencies: ["SyncCore", .product(name: "AMSMB2", package: "AMSMB2")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "PhotoSource", dependencies: ["SyncCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SMBAdapterTests", dependencies: ["SMBAdapter"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SMBIntegrationTests", dependencies: ["SMBAdapter", "SyncCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PhotoSourceTests", dependencies: ["PhotoSource"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
