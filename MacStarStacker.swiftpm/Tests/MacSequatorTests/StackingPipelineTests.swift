import XCTest
import AppKit
@testable import MacSequator

final class StackingPipelineTests: XCTestCase {
    private func makeImage(width: Int = 32, height: Int = 24, value: UInt8) -> NSImage {
        var pixels = [UInt8](repeating: value, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    fileprivate func waitForStacking(_ state: StackingStateController, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while state.isStacking && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    func testAverageMedianCompareBrightAndSkyGroundPipelinesComplete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try [40, 80, 120].enumerated().map { index, value -> ImageFile in
            let url = directory.appendingPathComponent("light_\(index).png")
            try writePNG(makeImage(value: UInt8(value)), to: url)
            return ImageFile(url: url)
        }

        let state = StackingStateController.shared
        state.images = [.light: files, .dark: [], .flat: [], .bias: []]
        state.baseImage = files[1]
        state.previewImage = files[0]
        state.enableAlignment = false
        state.enableTrailRemoval = false
        state.enableSkyGroundMask = false
        state.maskBitmap = nil

        for mode in ["Average", "Median", "Compare Bright"] {
            state.stackMode = mode
            state.startStacking()
            waitForStacking(state)
            XCTAssertFalse(state.isStacking, "\(mode) がタイムアウトしました")
            XCTAssertNotNil(state.stackedResult, "\(mode) が結果を生成しませんでした: \(state.stackingStatus)")
        }

        // 平均の新星景モードはマスクを塗らなくても合成できる。星の無い画像では位置合わせできないため、
        // 空と地上を分けずに合成したことを知らせる
        state.stackMode = "Average"
        state.enableSkyGroundMask = true
        state.maskBitmap = nil
        state.startStacking()
        waitForStacking(state)
        XCTAssertNotNil(state.stackedResult, state.stackingStatus)
        XCTAssertTrue(state.stackingStatus.contains("空と地上を分けずに"), state.stackingStatus)

        // 比較明で空と地上を分けるには、塗ったマスクが必要
        state.stackMode = "Compare Bright"
        state.maskBitmap = nil
        state.startStacking()
        XCTAssertFalse(state.isStacking)
        XCTAssertTrue(state.stackingStatus.contains("ブラシ"))

        state.maskBitmap = makeImage(value: 0).tintedGreenMask()
        state.startStacking()
        waitForStacking(state)
        XCTAssertNotNil(state.stackedResult, state.stackingStatus)

        state.stackMode = "Average"
        state.enableSkyGroundMask = false
        state.maskBitmap = nil
    }

    /// 稜線（y≈200）の下が岩肌の地上、上が星空の画像。星だけが毎フレーム (2, -3) px 動く（固定撮影）
    fileprivate func writeNightscapeFrames(to directory: URL, count: Int) throws -> [ImageFile] {
        let width = 480, height = 320
        var random: UInt64 = 17
        func next() -> Double {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Double(random >> 11) / Double(1 << 53)
        }
        let stars = (0..<500).map { _ in (next() * 680 - 100, next() * 520 - 100, 4000 + next() * 26000) }
        func ridge(_ x: Int) -> Double { 200 + 25 * sin(Double(x) / 37) + 12 * sin(Double(x) / 11) }
        let texture = (0..<(width * height)).map { i -> Float in
            let x = i % width, y = i / width
            return 600 + 2500 * Float(0.5 + 0.5 * sin(Double(x) / 5.3) * cos(Double(y) / 4.1))
                + 1200 * Float((x * 7919 + y * 104729) % 97) / 97
        }
        return try (0..<count).map { frame -> ImageFile in
            var image = [Float](repeating: 2000, count: width * height)
            for i in image.indices { image[i] += Float((next() - 0.5) * 200) }
            for star in stars {
                let cx = star.0 + 2 * Double(frame), cy = star.1 - 3 * Double(frame)
                let top = max(0, Int(cy) - 4), bottom = min(height - 1, Int(cy) + 4)
                let left = max(0, Int(cx) - 4), right = min(width - 1, Int(cx) + 4)
                guard top <= bottom, left <= right else { continue }
                for y in top...bottom {
                    for x in left...right {
                        let d2 = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)
                        image[y * width + x] += Float(star.2 * exp(-d2 / (2 * 1.2 * 1.2)))
                    }
                }
            }
            var rgb = [UInt16](repeating: 0, count: width * height * 3)
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    let ground = Double(y) >= ridge(x)
                    let value = ground ? texture[i] + Float((next() - 0.5) * 200) : image[i]
                    let (r, b): (Float, Float) = ground ? (1.15, 0.8) : (0.85, 1.2)
                    rgb[i * 3] = UInt16(max(0, min(65535, value * r)))
                    rgb[i * 3 + 1] = UInt16(max(0, min(65535, value)))
                    rgb[i * 3 + 2] = UInt16(max(0, min(65535, value * b)))
                }
            }
            let data = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
            let cg = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
                             space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                             provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
                             intent: .defaultIntent)!
            let url = directory.appendingPathComponent("nightscape_\(frame).tiff")
            try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .tiff, properties: [:])).write(to: url)
            return ImageFile(url: url)
        }
    }

    func testNightscapeModeSeparatesSkyAndGroundForDevelopedImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try writeNightscapeFrames(to: directory, count: 6)

        let state = StackingStateController.shared
        state.images = [.light: files, .dark: [], .flat: [], .bias: []]
        state.baseImage = files[0]
        state.previewImage = files[0]
        state.stackMode = "Average"
        state.enableAlignment = false
        state.enableTrailRemoval = false
        state.enableSkyGroundMask = true
        state.maskBitmap = nil
        defer {
            state.enableSkyGroundMask = false
            state.enableAlignment = true
            state.maskBitmap = nil
        }
        XCTAssertTrue(state.isNightscapeActive)

        state.startStacking()
        waitForStacking(state, timeout: 120)
        XCTAssertFalse(state.isStacking)
        let result = try XCTUnwrap(state.stackedResult, state.stackingStatus)
        XCTAssertTrue(state.stackingStatus.contains("新星景モードで合成"), state.stackingStatus)
        XCTAssertEqual(result.size.width, 480)

        // 自動判定の結果がブラシで直せるマスクとして表示される（上は空=青、下は地上=緑）
        let overlay = try XCTUnwrap(state.maskBitmap)
        let hints = try XCTUnwrap(NightscapeCompositor.hints(from: overlay, width: 480, height: 320))
        XCTAssertEqual(hints[20 * 480 + 240], 3, "上は空（前回の自動判定）")
        XCTAssertEqual(hints[300 * 480 + 240], 4, "下は地上（前回の自動判定）")
    }
}

extension StackingPipelineTests {
    private func preparedAnalysis(_ state: StackingStateController) -> NightscapeCompositor.Analysis? {
        switch state.nightscapePrepared {
        case .developed(_, let analysis)?: return analysis
        case .raw(let preparation)?: return preparation.analysis
        case nil: return nil
        }
    }

    /// 新しい解析の結果が出るまで待つ（自動解析は少し待ってから始まる）
    private func waitForNightscapeAnalysis(_ state: StackingStateController, replacing previous: NightscapeCompositor.Analysis?,
                                           timeout: TimeInterval = 120) {
        let start = Date()
        while (preparedAnalysis(state) == nil || preparedAnalysis(state) === previous)
                && Date().timeIntervalSince(start) < timeout {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        while state.isAnalyzingNightscape && Date().timeIntervalSince(start) < timeout {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    func testNightscapeModeAnalyzesBeforeStackingAndReusesTheAnalysis() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try writeNightscapeFramesForAnalysis(to: directory)

        let state = StackingStateController.shared
        state.enableSkyGroundMask = false
        state.images = [.light: files, .dark: [], .flat: [], .bias: []]
        state.baseImage = files[0]
        state.previewImage = files[3]
        state.stackMode = "Average"
        state.enableTrailRemoval = false
        state.maskBitmap = nil
        state.showResult = true
        defer {
            state.enableSkyGroundMask = false
            state.maskBitmap = nil
        }

        // ONにすると自動で解析し、判定結果を基準画像の上にブラシで直せるマスクとして表示する
        let before = preparedAnalysis(state)
        state.enableSkyGroundMask = true
        waitForNightscapeAnalysis(state, replacing: before)
        XCTAssertFalse(state.isAnalyzingNightscape)
        let prepared = try XCTUnwrap(state.nightscapePrepared, state.nightscapeAnalysisStatus)
        XCTAssertEqual(state.previewImage?.id, files[0].id, "判定結果は基準画像の上に表示する")
        XCTAssertFalse(state.showResult)
        let overlay = try XCTUnwrap(state.maskBitmap)
        let hints = try XCTUnwrap(NightscapeCompositor.hints(from: overlay, width: 480, height: 320))
        XCTAssertEqual(hints[20 * 480 + 240], 3, "上は空（自動判定）")
        XCTAssertEqual(hints[300 * 480 + 240], 4, "下は地上（自動判定）")
        guard case .developed(_, let analysis) = prepared else { return XCTFail("現像済み画像の解析になっていません") }

        // ブラシで塗った所は、判定し直しても残る
        let stroke = try XCTUnwrap(NSImage(size: NSSize(width: 480, height: 320), flipped: true) { _ in
            overlay.draw(in: NSRect(x: 0, y: 0, width: 480, height: 320))
            NSColor(red: 0, green: 1, blue: 0, alpha: 1).setFill()
            NSRect(x: 100, y: 40, width: 30, height: 20).fill()
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil))
        state.maskBitmap = NSImage(cgImage: stroke, size: NSSize(width: 480, height: 320))
        state.analyzeNightscape()
        waitForNightscapeAnalysis(state, replacing: analysis)
        let repainted = try XCTUnwrap(NightscapeCompositor.hints(from: try XCTUnwrap(state.maskBitmap), width: 480, height: 320))
        XCTAssertEqual(repainted[50 * 480 + 110], 2, "ブラシで塗った地上が残る")
        guard case .developed(_, let reanalyzed)? = state.nightscapePrepared else { return XCTFail("解析がありません") }

        // スタッキングは解析を使い回す（位置合わせをやり直さない）
        state.startStacking()
        waitForStacking(state, timeout: 120)
        XCTAssertNotNil(state.stackedResult, state.stackingStatus)
        XCTAssertTrue(state.stackingStatus.contains("新星景モードで合成"), state.stackingStatus)
        guard case .developed(_, let used)? = state.nightscapePrepared else { return XCTFail("解析がありません") }
        XCTAssertTrue(used === reanalyzed, "スタッキングで解析をやり直さない")
        XCTAssertFalse(used === analysis)

        // 基準画像を変えたら、前の自動判定の結果（位置がずれている）はすぐに消し、ブラシで塗った所だけ残す
        let painted = try XCTUnwrap(state.maskBitmap)
        state.baseImage = files[2]
        XCTAssertNil(state.nightscapePrepared, "前の解析は手放す")
        let remaining = try XCTUnwrap(NightscapeCompositor.hints(from: try XCTUnwrap(state.maskBitmap), width: 480, height: 320))
        XCTAssertFalse(remaining.contains(3) || remaining.contains(4), "前の自動判定の結果が残っていない")
        XCTAssertEqual(remaining[50 * 480 + 110], 2, "ブラシで塗った所は残る")
        XCTAssertNotNil(painted)
        state.enableSkyGroundMask = false
    }

    private func writeNightscapeFramesForAnalysis(to directory: URL) throws -> [ImageFile] {
        try writeNightscapeFrames(to: directory, count: 6)
    }
}

private extension NSImage {
    func tintedGreenMask() -> NSImage {
        let width = Int(size.width), height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index + 1] = 255
            pixels[index + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return NSImage(cgImage: cg, size: size)
    }
}
