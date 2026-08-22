// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SwiftySys",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SwiftySys", targets: ["SwiftySys"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system", from: "1.4.0")
    ],
    targets: [
        .target(
            name: "SwiftySys",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system")
            ]
        ),
        .testTarget(
            name: "SwiftySysTests",
            dependencies: ["SwiftySys"]
        ),
    ]
)
