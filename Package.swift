// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ios-sign-kit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "IOSSignKit",
            targets: ["IOSSignKit"]
        )
    ],
    targets: [
        .executableTarget(
            name: "IOSSignKit",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "IOSSignKitTests",
            dependencies: ["IOSSignKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
