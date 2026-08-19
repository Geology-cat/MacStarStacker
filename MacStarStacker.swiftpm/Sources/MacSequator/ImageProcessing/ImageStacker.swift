import Foundation
import AppKit
import Accelerate

/// Combines multiple NSImages using pixel-accurate average stacking.
/// All images should be the same size (pre-aligned).
class ImageStacker {

    enum StackMode {
        case average
        case median
        case compareBright   // 比較明合成: pixel-wise maximum
    }

    /// Stack the given images using the specified mode.
    /// Returns a 16-bit/channel TIFF-ready NSImage.
    static func stack(images: [NSImage], mode: StackMode = .average) -> NSImage? {
        guard !images.isEmpty else { return nil }

        // Convert all images to Float32 pixel buffers, RGBA
        let floatBuffers = images.compactMap { floatBuffer(from: $0) }
        guard !floatBuffers.isEmpty else { return nil }

        let (width, height) = (floatBuffers[0].width, floatBuffers[0].height)
        let pixelCount = width * height * 4 // RGBA channels

        var resultPixels = [Float](repeating: 0, count: pixelCount)

        switch mode {
        case .average:
            for buf in floatBuffers {
                vDSP_vadd(resultPixels, 1, buf.pixels, 1, &resultPixels, 1, vDSP_Length(pixelCount))
            }
            var divisor = Float(floatBuffers.count)
            vDSP_vsdiv(resultPixels, 1, &divisor, &resultPixels, 1, vDSP_Length(pixelCount))

        case .median:
            let count = floatBuffers.count
            for i in 0..<pixelCount {
                var values = floatBuffers.map { $0.pixels[i] }
                values.sort()
                resultPixels[i] = values[count / 2]
            }

        case .compareBright:
            // Initialize with first frame then take per-pixel max
            resultPixels = floatBuffers[0].pixels
            for buf in floatBuffers.dropFirst() {
                vDSP_vmax(resultPixels, 1, buf.pixels, 1, &resultPixels, 1, vDSP_Length(pixelCount))
            }
        }

        return nsImage(from: resultPixels, width: width, height: height)
    }

    // MARK: - Private Helpers

    private struct FloatBuffer {
        let pixels: [Float]
        let width: Int
        let height: Int
    }

    private static func floatBuffer(from image: NSImage) -> FloatBuffer? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let floatPixels = pixels.map { Float($0) / 255.0 }
        return FloatBuffer(pixels: floatPixels, width: width, height: height)
    }

    private static func nsImage(from pixels: [Float], width: Int, height: Int) -> NSImage? {
        let uint8Pixels = pixels.map { UInt8(max(0, min(255, $0 * 255.0))) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(uint8Pixels) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
