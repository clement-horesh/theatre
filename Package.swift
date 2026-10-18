// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Theatre",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "JellyfinKit", targets: ["JellyfinKit"]),
        .executable(name: "Theatre", targets: ["JellyMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),
        .target(name: "JellyfinKit"),
        .executableTarget(
            name: "JellyMac", dependencies: ["JellyfinKit", "VLCKit", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "JellyfinKitTests", dependencies: ["JellyfinKit"]),
        .testTarget(name: "JellyMacTests", dependencies: ["JellyMac", "JellyfinKit"], resources: [.copy("Fixtures")]),
    ]
)
