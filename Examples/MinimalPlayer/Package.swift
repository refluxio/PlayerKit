// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MinimalPlayer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "PlayerKit", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "MinimalPlayer",
            dependencies: [
                .product(name: "PlayerKit", package: "PlayerKit"),
                .product(name: "PlayerKitNative", package: "PlayerKit"),
            ],
            path: "Sources"
        ),
    ]
)
