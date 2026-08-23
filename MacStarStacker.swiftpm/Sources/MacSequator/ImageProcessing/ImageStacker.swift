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

        guard let firstBuffer = floatBuffer(from: images[0]) else { return nil }
        let (width, height) = (firstBuffer.width, firstBuffer.height)
        let pixelCount = width * height * 4 // RGBA channels
        var resultPixels = firstBuffer.pixels

        switch mode {
        case .average:
            for image in images.dropFirst() {
                guard let buf = floatBuffer(from: image),
                      buf.width == width, buf.height == height else { return nil }
                vDSP_vadd(resultPixels, 1, buf.pixels, 1, &resultPixels, 1, vDSP_Length(pixelCount))
            }
            var divisor = Float(images.count)
            vDSP_vsdiv(resultPixels, 1, &divisor, &resultPixels, 1, vDSP_Length(pixelCount))

        case .median:
            let remainingBuffers = images.dropFirst().compactMap { floatBuffer(from: $0) }
            guard remainingBuffers.count == images.count - 1,
                  remainingBuffers.allSatisfy({ $0.width == width && $0.height == height }) else { return nil }
            let floatBuffers = [firstBuffer] + remainingBuffers
            let count = floatBuffers.count
            for i in 0..<pixelCount {
                var values = floatBuffers.map { $0.pixels[i] }
                values.sort()
                if count.isMultiple(of: 2) {
                    resultPixels[i] = (values[count / 2 - 1] + values[count / 2]) / 2.0
                } else {
                    resultPixels[i] = values[count / 2]
                }
            }

        case .compareBright:
            for image in images.dropFirst() {
                guard let buf = floatBuffer(from: image),
                      buf.width == width, buf.height == height else { return nil }
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

        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 32,
                    bytesPerRow: width * 16,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return FloatBuffer(pixels: pixels, width: width, height: height)
    }

    private static func nsImage(from pixels: [Float], width: Int, height: Int) -> NSImage? {
        let uint16Pixels = pixels.map { value -> UInt16 in
            guard value.isFinite else { return 0 }
            return UInt16(max(0, min(65_535, value * 65_535.0)).rounded())
        }
        let data = uint16Pixels.withUnsafeBytes { Data($0) }
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 16,
                  bitsPerPixel: 64,
                  bytesPerRow: width * 8,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
