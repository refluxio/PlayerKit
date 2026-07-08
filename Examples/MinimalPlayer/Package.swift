// swift-tools-version: 5.9
// MinimalPlayer — example app for PlayerKit.
// Run with: cd Examples/MinimalPlayer && xcrun swift run

import PackageDescription

let package = Package(
    name: "MinimalPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MinimalPlayer",
            dependencies: [
                .product(name: "PlayerKit", package: "PlayerKit"),
                .product(name: "PlayerKitNative", package: "PlayerKit"),
            ],
            path: ".",
            exclude: ["MinimalPlayer.entitlements"],
            resources: [
                .copy("MinimalPlayer.entitlements")
            ]
        ),
    ]
)

// PlayerKit is the parent package (../../Package.swift). When MinimalPlayer is
// checked out as part of the PlayerKit repo, this relative path resolves to the
// root. If you've copied this example folder elsewhere, replace the path with
// `.package(url: "https://github.com/refluxio/PlayerKit.git", from: "0.1.0")`.
let playerKitDependency: PackageDescription.Package.Dependency = .package(path: "../..")
package.dependencies = [playerKitDependency]
