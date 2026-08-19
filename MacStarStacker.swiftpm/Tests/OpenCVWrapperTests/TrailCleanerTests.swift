import XCTest
import AppKit
import OpenCVWrapper

final class TrailCleanerTests: XCTestCase {
    private func makeImage(width: Int = 240, height: Int = 160, value: UInt8, line: Bool = false, secondLine: Bool = false) -> NSImage {
        var pixels = [UInt8](repeating: value, count: width * height * 4)
        if line {
            for y in (height / 2 - 1)...(height / 2 + 1) {
                for x in 20..<(width - 20) {
                    let index = (y * width + x) * 4
                    pixels[index] = 220
                    pixels[index + 1] = 220
                    pixels[index + 2] = 220
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
}
