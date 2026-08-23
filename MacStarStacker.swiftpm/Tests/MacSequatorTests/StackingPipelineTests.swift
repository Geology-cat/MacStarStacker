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

    private func waitForStacking(_ state: StackingStateController, timeout: TimeInterval = 10) {
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

        state.stackMode = "Average"
        state.enableSkyGroundMask = true
        state.maskBitmap = nil
        state.startStacking()
        XCTAssertFalse(state.isStacking)
        XCTAssertTrue(state.stackingStatus.contains("マスク"))

        state.maskBitmap = makeImage(value: 0).tintedGreenMask()
        state.startStacking()
        waitForStacking(state)
        XCTAssertNotNil(state.stackedResult, state.stackingStatus)

        state.enableSkyGroundMask = false
        state.maskBitmap = nil
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
