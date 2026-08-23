import XCTest
import AppKit
@testable import MacSequator

final class TimelapseExporterTests: XCTestCase {
    private func makeImage(width: Int = 320, height: Int = 240, value: UInt8) -> NSImage {
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
        let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testH264AndHEVCTimelapseCanBeRenderedWithDeflicker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try [40, 80, 120].enumerated().map { index, value -> ImageFile in
            let url = directory.appendingPathComponent("frame_\(index).png")
            try writePNG(makeImage(value: UInt8(value)), to: url)
            return ImageFile(url: url)
        }
        for codec in [TimelapseSettings.OutputCodec.h264, .hevc] {
            let codecName = codec == .h264 ? "h264" : "hevc"
            let output = directory.appendingPathComponent("timelapse_\(codecName).mp4")
            var settings = TimelapseSettings()
            settings.startFrame = 0
            settings.endFrame = files.count - 1
            settings.fps = 2
            settings.deflicker = true
            settings.codec = codec

            try TimelapseExporter.renderTimelapse(
                imageFiles: files,
                settings: settings,
                baseFile: files.first,
                outputURL: output,
                progress: { _, _ in }
            )

            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            XCTAssertGreaterThan(attributes[.size] as? UInt64 ?? 0, 1_000, codec.rawValue)
        }
    }
}
