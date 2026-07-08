// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "PlayerKit", targets: ["PlayerKit"]),
        .library(name: "PlayerKitNative", targets: ["PlayerKitNative"]),
    ],
    targets: [
        .target(
            name: "PlayerKit",
            dependencies: [],
            path: "Sources/PlayerKit",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        // CFFmpeg: NativeBackend's FFmpeg wrapper.
        // xcframeworks are built by scripts/build_ffmpeg.sh → Sources/CFFmpeg/xcframeworks/
        // Run the script once after cloning, and again to upgrade FFmpeg.
        .target(
            name: "CFFmpeg",
            dependencies: ["FFAvformat", "FFAvcodec", "FFAvutil", "FFSwresample", "FFSwscale"],
            path: "Sources/CFFmpeg",
            cSettings: [
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "PlayerKitNative",
            dependencies: ["PlayerKit", "CFFmpeg"],
            path: "Sources/PlayerKitNative",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit", "PlayerKitNative"],
            path: "Tests/PlayerKitTests"
        ),

        // NativeBackend FFmpeg — built from source by scripts/build_ffmpeg.sh.
        // xcframeworks are committed to the refluxio/PlayerKit independent repo;
        // in the reflux monorepo they are git-ignored — run the script after cloning.
        .binaryTarget(name: "FFAvcodec",    path: "Sources/CFFmpeg/xcframeworks/libavcodec.xcframework"),
        .binaryTarget(name: "FFAvformat",   path: "Sources/CFFmpeg/xcframeworks/libavformat.xcframework"),
        .binaryTarget(name: "FFAvutil",     path: "Sources/CFFmpeg/xcframeworks/libavutil.xcframework"),
        .binaryTarget(name: "FFSwresample", path: "Sources/CFFmpeg/xcframeworks/libswresample.xcframework"),
        .binaryTarget(name: "FFSwscale",    path: "Sources/CFFmpeg/xcframeworks/libswscale.xcframework"),

    ]
)
