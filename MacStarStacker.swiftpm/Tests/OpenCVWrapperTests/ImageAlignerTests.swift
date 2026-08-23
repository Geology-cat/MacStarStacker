import XCTest
import AppKit
import OpenCVWrapper

final class ImageAlignerTests: XCTestCase {
    private func featureImage(width: Int = 320, height: Int = 240) -> NSImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var generator: UInt64 = 0x1234_5678
        for y in 0..<height {
            for x in 0..<width {
                generator = generator &* 6_364_136_223_846_793_005 &+ 1
                let noise = UInt8((generator >> 56) & 0x1F)
                let checker = ((x / 20) + (y / 20)).isMultiple(of: 2) ? UInt8(35) : UInt8(110)
                let index = (y * width + x) * 4
                pixels[index] = checker &+ noise
                pixels[index + 1] = checker
                pixels[index + 2] = 180 &- noise
                pixels[index + 3] = 255
            }
        }
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

    private func write16BitTIFF(_ image: NSImage, to url: URL) throws {
        let source = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var pixels = [UInt16](repeating: 0, count: source.width * source.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: source.width,
            height: source.height,
            bitsPerComponent: 16,
            bytesPerRow: source.width * 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        ))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let rendered = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: rendered).representation(using: .tiff, properties: [:]))
        try data.write(to: url)
    }

    func testIdenticalFeatureRichImagesCanBeAligned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseURL = directory.appendingPathComponent("base.png")
        let targetURL = directory.appendingPathComponent("target.png")
        let image = featureImage()
        try writePNG(image, to: baseURL)
        try writePNG(image, to: targetURL)

        let aligned = try ImageAligner.alignImage(at: targetURL, toBaseImageAt: baseURL)
        let cg = try XCTUnwrap(aligned.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 320)
        XCTAssertEqual(cg.height, 240)
    }

    func testAlignmentPreserves16BitTargetDepth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseURL = directory.appendingPathComponent("base.tiff")
        let targetURL = directory.appendingPathComponent("target.tiff")
        let image = featureImage()
        try write16BitTIFF(image, to: baseURL)
        try write16BitTIFF(image, to: targetURL)

        let aligned = try ImageAligner.alignImage(at: targetURL, toBaseImageAt: baseURL)
        let cg = try XCTUnwrap(aligned.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.bitsPerComponent, 16)
    }
}
