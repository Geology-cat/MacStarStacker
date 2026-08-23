// swift-tools-version: 5.9
import PackageDescription

#if arch(arm64)
let opencvPrefix = "/opt/homebrew/opt/opencv"
#else
let opencvPrefix = "/usr/local/opt/opencv"
#endif

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
        .executableTarget(
            name: "MacSequator",
            dependencies: ["OpenCVWrapper"],
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
