// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "PlayerKit", targets: ["PlayerKit"]),
        .library(name: "PlayerKitMPV", targets: ["PlayerKitMPV"]),
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
        .target(
            name: "PlayerKitMPV",
            dependencies: ["PlayerKit",
                           "Mpv", "Avcodec", "Avfilter", "Avformat", "Avutil",
                           "Swresample", "Swscale", "Ass", "Dav1d",
                           "Freetype", "Fribidi", "Harfbuzz",
                           "Mbedcrypto", "Mbedtls", "Mbedx509",
                           "Png16", "Uchardet", "Xml2"],
            path: "Sources/PlayerKitMPV",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Metal"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security"),
                .linkedLibrary("bz2"),
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit", "PlayerKitNative"],
            path: "Tests/PlayerKitTests"
        ),

        // NativeBackend FFmpeg — built from source by scripts/build_ffmpeg.sh
        // xcframeworks are in .gitignore; run the script to generate them.
        .binaryTarget(name: "FFAvcodec",    path: "Sources/CFFmpeg/xcframeworks/libavcodec.xcframework"),
        .binaryTarget(name: "FFAvformat",   path: "Sources/CFFmpeg/xcframeworks/libavformat.xcframework"),
        .binaryTarget(name: "FFAvutil",     path: "Sources/CFFmpeg/xcframeworks/libavutil.xcframework"),
        .binaryTarget(name: "FFSwresample", path: "Sources/CFFmpeg/xcframeworks/libswresample.xcframework"),
        .binaryTarget(name: "FFSwscale",    path: "Sources/CFFmpeg/xcframeworks/libswscale.xcframework"),

        // MPV backend — still uses media-kit's libmpv bundle (unchanged)
        .binaryTarget(name: "Avformat",   path: "../MPVKit/libmpv/Avformat.xcframework"),
        .binaryTarget(name: "Avcodec",    path: "../MPVKit/libmpv/Avcodec.xcframework"),
        .binaryTarget(name: "Avutil",     path: "../MPVKit/libmpv/Avutil.xcframework"),
        .binaryTarget(name: "Swresample", path: "../MPVKit/libmpv/Swresample.xcframework"),
        .binaryTarget(name: "Swscale",    path: "../MPVKit/libmpv/Swscale.xcframework"),
        .binaryTarget(name: "Dav1d",      path: "../MPVKit/libmpv/Dav1d.xcframework"),
        // MPV-specific libraries
        .binaryTarget(name: "Mpv",        path: "../MPVKit/libmpv/Mpv.xcframework"),
        .binaryTarget(name: "Avfilter",   path: "../MPVKit/libmpv/Avfilter.xcframework"),
        .binaryTarget(name: "Ass",        path: "../MPVKit/libmpv/Ass.xcframework"),
        .binaryTarget(name: "Freetype",   path: "../MPVKit/libmpv/Freetype.xcframework"),
        .binaryTarget(name: "Fribidi",    path: "../MPVKit/libmpv/Fribidi.xcframework"),
        .binaryTarget(name: "Harfbuzz",   path: "../MPVKit/libmpv/Harfbuzz.xcframework"),
        .binaryTarget(name: "Mbedcrypto", path: "../MPVKit/libmpv/Mbedcrypto.xcframework"),
        .binaryTarget(name: "Mbedtls",    path: "../MPVKit/libmpv/Mbedtls.xcframework"),
        .binaryTarget(name: "Mbedx509",   path: "../MPVKit/libmpv/Mbedx509.xcframework"),
        .binaryTarget(name: "Png16",      path: "../MPVKit/libmpv/Png16.xcframework"),
        .binaryTarget(name: "Uchardet",   path: "../MPVKit/libmpv/Uchardet.xcframework"),
        .binaryTarget(name: "Xml2",       path: "../MPVKit/libmpv/Xml2.xcframework"),
    ]
)
