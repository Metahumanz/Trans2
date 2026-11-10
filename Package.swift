// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Trans2",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Trans2", targets: ["Trans2"]),
        .library(name: "TransCore", targets: ["TransCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing", from: "0.11.0"),
    ],
    targets: [
        .target(name: "TransCore"),
        .executableTarget(
            name: "Trans2",
            dependencies: ["TransCore"],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "TransCoreTests",
            dependencies: ["TransCore", .product(name: "Testing", package: "swift-testing")]
        ),
        .testTarget(
            name: "Trans2Tests",
            dependencies: ["Trans2", .product(name: "Testing", package: "swift-testing")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
