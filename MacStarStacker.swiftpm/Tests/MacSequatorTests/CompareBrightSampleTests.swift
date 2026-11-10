import XCTest
import AppKit
@testable import MacSequator

/// 実際の撮影データで比較明合成（RAW経路）を試す（手動確認用）。
/// 環境変数 COMPARE_BRIGHT_SAMPLE_DIR に RAW のフォルダ、COMPARE_BRIGHT_OUTPUT_DIR に書き出し先を指定したときだけ実行する。
/// COMPARE_BRIGHT_ALIGN を指定すると位置合わせあり（カメラ色空間RGB）で合成する。
final class CompareBrightSampleTests: XCTestCase {
    func testStackSampleFolder() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sample = environment["COMPARE_BRIGHT_SAMPLE_DIR"], let outputPath = environment["COMPARE_BRIGHT_OUTPUT_DIR"] else {
            throw XCTSkip("COMPARE_BRIGHT_SAMPLE_DIR と COMPARE_BRIGHT_OUTPUT_DIR を指定したときだけ実行する")
        }
        let lights = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: sample), includingPropertiesForKeys: nil)
            .filter(RawDecoder.isRawFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(lights.isEmpty)
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let input = RawStackPipeline.Input(
            lights: lights, baseIndex: lights.count / 2, darks: [], flats: [], biases: [], mode: .compareBright,
            align: environment["COMPARE_BRIGHT_ALIGN"] != nil, skyGroundMask: nil, maskFeatherRadius: 0, trailMasks: [:]
        )
        let start = Date()
        let result = try XCTUnwrap(RawStackPipeline.stack(input) { fraction, status in
            print(String(format: "[%5.1fs %3.0f%%] %@", Date().timeIntervalSince(start), fraction * 100, status))
        })
        print("合成時間: \(Date().timeIntervalSince(start))秒（\(lights.count)枚、\(result.modeDescription)）")

        // RAW（DNG）での書き出しと、表示用の現像画像（撮影時の向き）
        try result.writeDNG(metadata: nil, embedLensProfile: false, to: output.appendingPathComponent("compare_bright.dng"))
        let tiff = try XCTUnwrap(result.displayImage.tiffRepresentation)
        try tiff.write(to: output.appendingPathComponent("compare_bright.tiff"))
    }
}
