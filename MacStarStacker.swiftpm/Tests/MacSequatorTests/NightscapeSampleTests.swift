import XCTest
import AppKit
import OpenCVWrapper
@testable import MacSequator

/// 実際の撮影データで新星景モードを試す（手動確認用）。
/// 環境変数 NIGHTSCAPE_SAMPLE_DIR に RAW のフォルダ、NIGHTSCAPE_OUTPUT_DIR に書き出し先を指定したときだけ実行する。
/// NIGHTSCAPE_BASE_INDEX で基準画像の番号（0始まり）、NIGHTSCAPE_HINTS で判定の手がかりのマスク画像を指定できる。
final class NightscapeSampleTests: XCTestCase {
    func testComposeSampleFolder() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sample = environment["NIGHTSCAPE_SAMPLE_DIR"], let outputPath = environment["NIGHTSCAPE_OUTPUT_DIR"] else {
            throw XCTSkip("NIGHTSCAPE_SAMPLE_DIR と NIGHTSCAPE_OUTPUT_DIR を指定したときだけ実行する")
        }
        // NIGHTSCAPE_GROUND_FIXED に地上固定フレームのパス（カンマ区切り）を指定できる（Light からは除く）
        let groundFixed = (environment["NIGHTSCAPE_GROUND_FIXED"] ?? "").split(separator: ",")
            .map { URL(fileURLWithPath: String($0)).standardizedFileURL }
        let lights = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: sample), includingPropertiesForKeys: nil)
            .filter(RawDecoder.isRawFile)
            // 名前に「地上固定」を含むファイルは、NIGHTSCAPE_GROUND_FIXED に指定しないときも Light に含めない
            .filter { url in !groundFixed.contains { $0.lastPathComponent == url.lastPathComponent } }
            .filter { !$0.lastPathComponent.contains("地上固定") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(lights.isEmpty)
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let baseIndex = Int(environment["NIGHTSCAPE_BASE_INDEX"] ?? "") ?? lights.count / 2

        // NIGHTSCAPE_HINTS に、ブラシと同じ色（空=青、地上=緑）で塗ったマスク画像を指定できる
        let hints = environment["NIGHTSCAPE_HINTS"].flatMap { NSImage(contentsOfFile: $0) }
        var input = RawStackPipeline.Input(
            lights: lights, baseIndex: baseIndex, darks: [], flats: [], biases: [], mode: .average, align: true,
            skyGroundMask: hints, maskFeatherRadius: 0, trailMasks: [:], nightscape: true
        )
        input.groundFixed = groundFixed
        // NIGHTSCAPE_FEATHER で境界ぼかし（px）を指定できる
        input.nightscapeFeatherRadius = CGFloat(Double(environment["NIGHTSCAPE_FEATHER"] ?? "") ?? 0)
        // NIGHTSCAPE_PREPARE を指定すると、アプリと同じく先に解析し、その結果を使い回して合成する
        var prepared: RawStackPipeline.NightscapePreparation?
        if environment["NIGHTSCAPE_PREPARE"] != nil {
            let prepareStart = Date()
            prepared = try RawStackPipeline.prepareNightscape(input) { _, _ in }
            print("解析時間: \(Date().timeIntervalSince(prepareStart))秒")
        }
        let start = Date()
        let result = try XCTUnwrap(RawStackPipeline.stack(input, nightscape: prepared) { fraction, status in
            print(String(format: "[%5.1fs %3.0f%%] %@", Date().timeIntervalSince(start), fraction * 100, status))
        })
        print("合成時間: \(Date().timeIntervalSince(start))秒 補足: \(result.note ?? "なし")")

        // RAW（DNG）での書き出し
        try result.writeDNG(metadata: nil, embedLensProfile: false, to: output.appendingPathComponent("nightscape.dng"))
        // 合成したカメラ色空間RGB（現像前、16bit、R・G・Bの順）
        try result.pixels.withUnsafeBytes { Data($0) }.write(to: output.appendingPathComponent("pixels.raw"))
        // 表示用の現像画像（撮影時の向き）
        let tiff = try XCTUnwrap(result.displayImage.tiffRepresentation)
        try tiff.write(to: output.appendingPathComponent("nightscape.tiff"))
        // 自動判定した空の割合（センサーの向き）
        if let alpha = result.skyAlpha {
            let bytes = alpha.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let image = CGImage(width: result.width, height: result.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                bytesPerRow: result.width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)!
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try png.write(to: output.appendingPathComponent("sky_alpha.png"))
        }
    }

    /// 各フレームの地上・星の変換を JSON に書き出す（位置合わせの精度の確認用）
    func testDumpHomographies() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sample = environment["NIGHTSCAPE_SAMPLE_DIR"], let outputPath = environment["NIGHTSCAPE_DUMP_H"] else {
            throw XCTSkip("NIGHTSCAPE_SAMPLE_DIR と NIGHTSCAPE_DUMP_H を指定したときだけ実行する")
        }
        let lights = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: sample), includingPropertiesForKeys: nil)
            .filter(RawDecoder.isRawFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let baseIndex = Int(environment["NIGHTSCAPE_BASE_INDEX"] ?? "") ?? lights.count / 2
        let base = try RawDecoder.demosaicCameraRGB(from: lights[baseIndex])
        let count = base.width * base.height
        let baseGray = NightscapeCompositor.gray(of: base.pixels, count: count)
        let ground = try GroundAligner(baseGray: baseGray, width: base.width, height: base.height)
        let star = try StarAligner(baseGray: baseGray, width: base.width, height: base.height, skyMask: nil)
        var result: [String: [String: [Double]]] = [:]
        for index in lights.indices where index != baseIndex {
            let frame = try RawDecoder.demosaicCameraRGB(from: lights[index])
            let gray = NightscapeCompositor.gray(of: frame.pixels, count: count)
            let g = try? ground.homography(fromGray: gray, initialGuess: nil)
            let s = try? star.homography(fromGray: gray, initialGuess: nil)
            result[String(index)] = ["ground": g?.map(\.doubleValue) ?? [], "star": s?.map(\.doubleValue) ?? []]
            print("frame \(index) ground \(g?.map(\.doubleValue) ?? [])")
        }
        try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: outputPath))
    }

    /// 1枚を現像した結果（カメラ色空間RGB、16bit、R・G・Bの順）をそのまま書き出す（現像の確認用）
    func testDumpDemosaicedFrame() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["NIGHTSCAPE_DEMOSAIC_FILE"], let outputPath = environment["NIGHTSCAPE_DEMOSAIC_OUT"] else {
            throw XCTSkip("NIGHTSCAPE_DEMOSAIC_FILE と NIGHTSCAPE_DEMOSAIC_OUT を指定したときだけ実行する")
        }
        let frame = try RawDecoder.demosaicCameraRGB(from: URL(fileURLWithPath: path))
        print("demosaic \(frame.width)x\(frame.height)")
        try frame.pixels.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: outputPath))
    }

    /// 解析（空と地上の自動判定）だけを行い、判定結果を書き出す。RAW でなければ現像済み画像として解析する
    func testAnalyzeSampleFolder() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sample = environment["NIGHTSCAPE_ANALYZE_DIR"], let outputPath = environment["NIGHTSCAPE_OUTPUT_DIR"] else {
            throw XCTSkip("NIGHTSCAPE_ANALYZE_DIR と NIGHTSCAPE_OUTPUT_DIR を指定したときだけ実行する")
        }
        let lights = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: sample), includingPropertiesForKeys: nil)
            .filter { ["cr2", "dng", "nef", "arw", "jpg", "jpeg", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let baseIndex = Int(environment["NIGHTSCAPE_BASE_INDEX"] ?? "") ?? lights.count / 2
        let state = StackingStateController.shared
        state.images = [.light: lights.map { ImageFile(url: $0) }, .dark: [], .flat: [], .bias: []]
        state.baseImage = state.images[.light]?[baseIndex]
        state.stackMode = "Average"
        state.maskBitmap = nil
        state.enableSkyGroundMask = true
        defer { state.enableSkyGroundMask = false }
        let start = Date()
        state.analyzeNightscape()
        while state.isAnalyzingNightscape && Date().timeIntervalSince(start) < 900 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        print("解析時間: \(Date().timeIntervalSince(start))秒 状況: \(state.nightscapeAnalysisStatus)")
        let mask = try XCTUnwrap(state.maskBitmap)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(mask.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            .representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("analysis_mask.png"))
    }

    /// 星に合わせた平均（新星景モードではない）を、シグマクリッピングあり・なしで合成して書き出す
    func testAverageSampleFolder() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sample = environment["AVERAGE_SAMPLE_DIR"], let outputPath = environment["AVERAGE_OUTPUT_DIR"] else {
            throw XCTSkip("AVERAGE_SAMPLE_DIR と AVERAGE_OUTPUT_DIR を指定したときだけ実行する")
        }
        let lights = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: sample), includingPropertiesForKeys: nil)
            .filter(RawDecoder.isRawFile)
            .filter { !$0.lastPathComponent.contains("地上固定") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for clipping in [false, true] {
            var input = RawStackPipeline.Input(
                lights: lights, baseIndex: lights.count / 2, darks: [], flats: [], biases: [], mode: .average, align: true,
                skyGroundMask: nil, maskFeatherRadius: 0, trailMasks: [:])
            input.sigmaClipping = clipping ? SigmaClipping() : nil
            let start = Date()
            let result = try XCTUnwrap(RawStackPipeline.stack(input) { _, _ in })
            print("合成時間（シグマクリッピング\(clipping ? "あり" : "なし")）: \(Date().timeIntervalSince(start))秒")
            try result.pixels.withUnsafeBytes { Data($0) }
                .write(to: output.appendingPathComponent(clipping ? "clipped.raw" : "plain.raw"))
        }
    }
}
