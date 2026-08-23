import XCTest
import AppKit
import OpenCVWrapper

final class TrailCleanerTests: XCTestCase {
    private func makeImage(
        width: Int = 240,
        height: Int = 160,
        value: UInt8,
        line: Bool = false,
        secondLine: Bool = false,
        lineValue: UInt8 = 220,
        lineThickness: Int = 3,
        diagonalLine: Bool = false
    ) -> NSImage {
        var pixels = [UInt8](repeating: value, count: width * height * 4)
        if line {
            for x in 20..<(width - 20) {
                let centerY = diagonalLine
                    ? height / 4 + (x - 20) * (height / 2) / max(1, width - 40)
                    : height / 2
                let firstY = centerY - (lineThickness - 1) / 2
                let lastY = firstY + lineThickness - 1
                for y in firstY...lastY where y >= 0 && y < height {
                    let index = (y * width + x) * 4
                    pixels[index] = lineValue
                    pixels[index + 1] = lineValue
                    pixels[index + 2] = lineValue
                    pixels[index + 3] = 255
                }
            }
        } else {
            for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        }
        if secondLine {
            for y in (height / 4 - 1)...(height / 4 + 1) {
                for x in 20..<(width - 20) {
                    let index = (y * width + x) * 4
                    pixels[index] = 220
                    pixels[index + 1] = 220
                    pixels[index + 2] = 220
                    pixels[index + 3] = 255
                }
            }
        }

        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let image = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    private func makeNoiseImage(
        width: Int = 320,
        height: Int = 200,
        seed: UInt64,
        line: Bool = false,
        lineValue: UInt8 = 38,
        lineThickness: Int = 1,
        noiseAmplitude: Int = 3,
        gapPeriod: Int? = nil,
        gapWidth: Int = 0
    ) -> NSImage {
        var generator = seed
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            generator = generator &* 6_364_136_223_846_793_005 &+ 1
            let noiseSpan = UInt64(max(1, noiseAmplitude * 2 + 1))
            let noise = Int((generator >> 32) % noiseSpan) - noiseAmplitude
            let value = UInt8(clamping: 24 + noise)
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
        if line {
            for x in 20..<(width - 20) {
                if let gapPeriod,
                   gapPeriod > 0,
                   (x - 20) % gapPeriod < gapWidth {
                    continue
                }
                let firstY = height / 2 - (lineThickness - 1) / 2
                for y in firstY..<(firstY + lineThickness) where y >= 0 && y < height {
                    let index = (y * width + x) * 4
                    pixels[index] = lineValue
                    pixels[index + 1] = lineValue
                    pixels[index + 2] = lineValue
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    private func write(_ image: NSImage, to url: URL) throws {
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    func testTwoFramesAreRejectedWithoutTemporalContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try [0, 1].map { index -> URL in
            let url = directory.appendingPathComponent("frame_\(index).png")
            try write(makeImage(value: 20, line: index == 1), to: url)
            return url
        }
        XCTAssertTrue(TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil).isEmpty)
    }

    func testUniformExposureChangeDoesNotCreateWholeFrameTrail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try [20, 60, 20].enumerated().map { index, value -> URL in
            let url = directory.appendingPathComponent("frame_\(index).png")
            try write(makeImage(value: UInt8(value)), to: url)
            return url
        }
        XCTAssertTrue(TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil).isEmpty)
    }

    func testUniformSatelliteLineIsNotAutomaticallyProtectedAsMeteor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try [0, 1, 2].map { index -> URL in
            let url = directory.appendingPathComponent("frame_\(index).png")
            try write(makeImage(value: 20, line: index == 1), to: url)
            return url
        }
        let results = TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { !$0.isLikelyMeteor })
        XCTAssertTrue(results.allSatisfy { $0.isMarkedForRemoval })
    }

    func testFaintOnePixelSatelliteLineIsDetected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("frame_\(index).png")
            try write(makeImage(
                width: 320,
                height: 200,
                value: 20,
                line: index == 2,
                lineValue: 27,
                lineThickness: 1
            ), to: url)
            return url
        }

        let results = TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil)
        let satelliteResults = results.filter { $0.frameIndex == 2 && $0.detectedType.contains("人工衛星") }
        XCTAssertFalse(satelliteResults.isEmpty, "微弱1pxの人工衛星線を検出できませんでした")
        XCTAssertTrue(satelliteResults.allSatisfy { $0.isMarkedForRemoval })
    }

    func testFaintDiagonalSatelliteLineIsDetected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("diagonal_\(index).png")
            try write(makeImage(
                width: 360,
                height: 240,
                value: 20,
                line: index == 2,
                lineValue: 27,
                lineThickness: 1,
                diagonalLine: true
            ), to: url)
            return url
        }
        let results = TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil)
        XCTAssertTrue(results.contains { $0.frameIndex == 2 && $0.detectedType.contains("人工衛星") })
    }

    func testFaintTrailSurvives4KWidthDownsampling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("wide_\(index).png")
            try write(makeImage(
                width: 4_096,
                height: 512,
                value: 20,
                line: index == 2,
                lineValue: 28,
                lineThickness: 2
            ), to: url)
            return url
        }
        let results = TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil)
        XCTAssertTrue(results.contains { $0.frameIndex == 2 && $0.detectedType.contains("人工衛星") })
    }

    func testIndependentLowLevelNoiseDoesNotCreateTrail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("noise_\(index).png")
            try write(makeNoiseImage(seed: UInt64(index + 1)), to: url)
            return url
        }
        XCTAssertTrue(TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil).isEmpty)
    }

    func testFaintLongTrailIsDetectedAgainstIndependentNoise() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("noisy_trail_\(index).png")
            try write(makeNoiseImage(seed: UInt64(index + 20), line: index == 2), to: url)
            return url
        }
        let results = TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil)
        XCTAssertTrue(results.contains { $0.frameIndex == 2 && $0.detectedType.contains("人工衛星") })
    }

    func testSubNoiseTrailUsesIntegratedLineEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("sub_noise_trail_\(index).png")
            try write(makeNoiseImage(
                width: 360,
                height: 240,
                seed: UInt64(index + 100),
                line: index == 2,
                lineValue: 36,
                lineThickness: 3,
                noiseAmplitude: 16
            ), to: url)
            return url
        }
        let results = TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil)
        XCTAssertTrue(results.contains {
            $0.frameIndex == 2 && $0.detectedType.contains("低コントラスト")
        }, "画素単位のノイズ床より暗い長い衛星線を線積算で検出できませんでした")
    }

    func testBrokenLowContrastTrailIsDetected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("broken_trail_\(index).png")
            try write(makeNoiseImage(
                width: 360,
                height: 240,
                seed: UInt64(index + 150),
                line: index == 2,
                lineValue: 40,
                lineThickness: 3,
                noiseAmplitude: 16,
                gapPeriod: 12,
                gapWidth: 1
            ), to: url)
            return url
        }
        let results = TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil)
        XCTAssertTrue(results.contains {
            $0.frameIndex == 2 && $0.detectedType.contains("低コントラスト")
        }, "短く途切れた低コントラスト光跡を連続する一本の候補として検出できませんでした")
    }

    func testIndependentHighNoiseDoesNotCreateTrail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("high_noise_\(index).png")
            try write(makeNoiseImage(
                width: 360,
                height: 240,
                seed: UInt64(index + 200),
                noiseAmplitude: 16
            ), to: url)
            return url
        }
        XCTAssertTrue(TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil).isEmpty)
    }

    func testStaticLinearFeatureInEveryFrameDoesNotCreateTrail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("static_edge_\(index).png")
            try write(makeNoiseImage(
                width: 360,
                height: 240,
                seed: UInt64(index + 250),
                line: true,
                lineValue: 48,
                lineThickness: 3,
                noiseAmplitude: 16
            ), to: url)
            return url
        }
        XCTAssertTrue(
            TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil).isEmpty,
            "全フレームに存在する地形境界を一時的な光跡として誤検出しています"
        )
    }

    func testSequenceEdgesAreNotReportedWithSymmetricContextAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<5).map { index -> URL in
            let url = directory.appendingPathComponent("edge_\(index).png")
            try write(makeImage(value: 20, line: index == 0 || index == 4), to: url)
            return url
        }
        XCTAssertTrue(TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil).isEmpty)
    }

    func testSeparateCandidatesRemainSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try [0, 1, 2].map { index -> URL in
            let url = directory.appendingPathComponent("frame_\(index).png")
            try write(makeImage(value: 20, line: index == 1, secondLine: index == 1), to: url)
            return url
        }
        let results = TrailCleaner.detectTrails(inImageURLs: urls, progressCallback: nil)
        XCTAssertGreaterThanOrEqual(results.filter { $0.frameIndex == 1 }.count, 2)
    }

    func testBundledRealAirTrafficSequenceFindsTrails() throws {
        guard ProcessInfo.processInfo.environment["RUN_REAL_TRAIL_TEST"] == "1" else {
            throw XCTSkip("4K実写連番を使う手動統合テストです")
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let framesDirectory = repositoryRoot
            .appendingPathComponent("test_materials/wikimedia_air_traffic_4k/frames")
        let urls = try FileManager.default.contentsOfDirectory(
            at: framesDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "jpg" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(12)
        let results = TrailCleaner.detectTrails(
            inImageURLs: Array(urls),
            progressCallback: nil
        )
        let perFrame = Dictionary(grouping: results, by: \.frameIndex)
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        print("REAL_TRAIL_RESULTS=\(results.count), PER_FRAME=\(perFrame)")
        for result in results where result.frameIndex == 4 {
            print("REAL_TRAIL_FRAME5 type=\(result.detectedType) bounds=\(result.detectedBounds)")
        }
        XCTAssertFalse(results.isEmpty)
        XCTAssertLessThan(results.count, 130, "星像ノイズを過剰な光跡候補として列挙しています")
        XCTAssertTrue(results.allSatisfy { (2...9).contains($0.frameIndex) })
        let previouslyMissedShortTrail = NSRect(x: 930, y: 440, width: 80, height: 60)
        XCTAssertTrue(results.contains {
            $0.frameIndex == 4
                && $0.detectedType.contains("低コントラスト")
                && $0.detectedBounds.intersects(previouslyMissedShortTrail)
        }, "実写フレーム5の短い低コントラスト光跡を検出できませんでした")
    }
}
