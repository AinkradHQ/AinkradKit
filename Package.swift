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
        .package(url: "https://github.com/AinkradHQ/AinkradAppKit", revision: "636baa4cb5925a4603a589eaad98139e3b93d888"),
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
