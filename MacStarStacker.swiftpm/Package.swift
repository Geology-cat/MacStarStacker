// swift-tools-version: 5.9
import PackageDescription
import Foundation

// OpenCV・LibRaw は scripts/build_deps.sh でソースからビルドした Universal 静的ライブラリを使う。
// （Homebrew の dylib はビルドしたMacのOSが最低対応OSになり、アーキテクチャも1種類しか含まないため）
// 最低対応OSを変えるときは、ここと Info.plist の LSMinimumSystemVersion、build_app.sh を合わせる。
let deploymentTarget = "10.12.6"
let vendorDir = "\(Context.packageDirectory)/Vendor/macos\(deploymentTarget)"

// Xcode 14 以降の SwiftPM は、platforms に 10.13 より前を指定しても 10.13 向けにビルドする（10.13 が最も古い対応版）。
// macOS 10.12 で動かすため、コンパイラとリンカに対象（ターゲットトリプル）を直接指定する。
// arm64 は macOS 11 からなので 11.0 のまま。ビルドするアーキテクチャは、環境変数 MSS_BUILD_ARCH（build_app.sh が
// アーキテクチャごとに指定する）か、無ければこのマニフェストを動かしているMacのアーキテクチャにする。
#if arch(arm64)
let hostArch = "arm64"
#else
let hostArch = "x86_64"
#endif
let buildArch = ProcessInfo.processInfo.environment["MSS_BUILD_ARCH"] ?? hostArch
let targetTriple = buildArch == "arm64" ? "arm64-apple-macosx11.0" : "x86_64-apple-macosx\(deploymentTarget)"
let targetFlags = ["-target", targetTriple]

let package = Package(
    name: "MacSequator",
    platforms: [
        // SwiftPM が受け付ける最も古い版。実際の最低対応OSは上の targetTriple で決める
        .macOS(.v10_13)
    ],
    products: [
        .executable(
            name: "MacSequator",
            targets: ["MacSequator"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "OpenCVWrapper",
            dependencies: [],
            path: "Sources/OpenCVWrapper",
            cxxSettings: [
                .unsafeFlags([
                    "-std=c++17",
                    "-I\(vendorDir)/include/opencv4"
                ] + targetFlags, .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorDir)/lib",
                    "-lopencv_photo",
                    "-lopencv_calib3d",
                    "-lopencv_features2d",
                    "-lopencv_flann",
                    "-lopencv_imgcodecs",
                    "-lopencv_imgproc",
                    "-lopencv_core",
                    // imgcodecs が同梱する画像コーデック（OpenCV付属のソースからビルド）
                    "-llibjpeg-turbo",
                    "-llibpng",
                    "-llibtiff",
                    "-lz"
                ], .when(platforms: [.macOS]))
            ]
        ),
        // RAWのベイヤー配列・カメラ色空間データを読むためのLibRawブリッジ
        .target(
            name: "LibRawBridge",
            dependencies: [],
            path: "Sources/LibRawBridge",
            cSettings: [
                .unsafeFlags(["-I\(vendorDir)/include/libraw"] + targetFlags, .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorDir)/lib",
                    "-lraw_r",
                    "-lz",
                    "-lc++"
                ], .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "MacSequator",
            dependencies: ["OpenCVWrapper", "LibRawBridge"],
            path: "Sources/MacSequator",
            exclude: ["Info.plist", "AppIcon.icns"],
            resources: [
                .process("Metal/Stacking.metal")
            ],
            swiftSettings: [.unsafeFlags(targetFlags)],
            linkerSettings: [.unsafeFlags(targetFlags)]
        ),
        .testTarget(
            name: "OpenCVWrapperTests",
            dependencies: ["OpenCVWrapper"],
            path: "Tests/OpenCVWrapperTests"
        ),
        .testTarget(
            name: "MacSequatorTests",
            dependencies: ["MacSequator"],
            path: "Tests/MacSequatorTests"
        )
    ]
)
