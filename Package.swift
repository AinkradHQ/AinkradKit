// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AinkradKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ainkrad", targets: ["ainkrad"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/AinkradHQ/AinkradAppKit", revision: "f4fcb8f5d6fe3c0b49a14b72fd7ed6cb219d45be"),
    ],
    targets: [
        .executableTarget(
            name: "ainkrad",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AinkradAppKit", package: "AinkradAppKit"),
            ],
            resources: [
                .copy("Resources/Template"),
            ]
        ),
        .testTarget(
            name: "AinkradKitTests",
            dependencies: ["ainkrad"]
        ),
    ]
)
