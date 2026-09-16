// swift-tools-version: 5.9
import PackageDescription
import Foundation

#if arch(arm64)
let homebrewPrefix = "/opt/homebrew/opt"
#else
let homebrewPrefix = "/usr/local/opt"
#endif

// OpenCV 5 はヘッダー配置とモジュール構成（calib3d の分割など）が変わったため、4系を使う。
// Homebrew の opencv が5系になった環境では opencv@4（keg-only）を優先する。
let opencvPrefix = FileManager.default.fileExists(atPath: "\(homebrewPrefix)/opencv@4/include/opencv4")
    ? "\(homebrewPrefix)/opencv@4"
    : "\(homebrewPrefix)/opencv"
let librawPrefix = "\(homebrewPrefix)/libraw"

let package = Package(
    name: "MacSequator",
    platforms: [
        .macOS(.v14)
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
                    "-I\(opencvPrefix)/include/opencv4"
                ], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(opencvPrefix)/lib",
                    "-lopencv_core",
                    "-lopencv_imgproc",
                    "-lopencv_imgcodecs",
                    "-lopencv_features2d",
                    "-lopencv_calib3d",
                    "-lopencv_flann",
                    "-lopencv_photo"
                ], .when(platforms: [.macOS]))
            ]
        ),
        // RAWのベイヤー配列・カメラ色空間データを読むためのLibRawブリッジ（brew install libraw）
        .target(
            name: "LibRawBridge",
            dependencies: [],
            path: "Sources/LibRawBridge",
            cSettings: [
                .unsafeFlags(["-I\(librawPrefix)/include/libraw"], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(librawPrefix)/lib",
                    "-lraw_r"
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
            ]
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
