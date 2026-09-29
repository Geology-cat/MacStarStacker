// swift-tools-version: 5.9
import PackageDescription

// OpenCV・LibRaw は scripts/build_deps.sh でソースからビルドした Universal 静的ライブラリを使う。
// （Homebrew の dylib はビルドしたMacのOSが最低対応OSになり、アーキテクチャも1種類しか含まないため）
// 最低対応OSを変えるときは、ここと Info.plist の LSMinimumSystemVersion、build_app.sh を合わせる。
let deploymentTarget = "14.0"
let vendorDir = "\(Context.packageDirectory)/Vendor/macos\(deploymentTarget)"

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
                    "-I\(vendorDir)/include/opencv4"
                ], .when(platforms: [.macOS]))
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
                .unsafeFlags(["-I\(vendorDir)/include/libraw"], .when(platforms: [.macOS]))
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
