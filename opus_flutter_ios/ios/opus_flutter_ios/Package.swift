// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "opus_flutter_ios",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "opus-flutter-ios", targets: ["opus_flutter_ios"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "opus_flutter_ios",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "opus",
            ]
        ),
        .binaryTarget(name: "opus", path: "opus.xcframework"),
    ]
)
