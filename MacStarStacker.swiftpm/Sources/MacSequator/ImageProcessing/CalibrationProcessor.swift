import Foundation
import AppKit
import Accelerate

/// Applies calibration frames (Dark, Flat, Bias) to light frames before stacking.
class CalibrationProcessor {

    // MARK: - Public API

    /// Apply bias subtraction → dark subtraction → flat-field division to a light frame.
    /// Pass nil for any calibration you don't have.
    static func calibrate(
        light: NSImage,
        masterBias: NSImage? = nil,
        masterDark: NSImage? = nil,
        masterFlat: NSImage? = nil
    ) -> NSImage? {

        // Convert all to Float32 pixel arrays
        guard var lightBuf = floatBuffer(from: light) else { return nil }

        let width = lightBuf.width
        let height = lightBuf.height
        let count = width * height * 4

        let biasBuf = masterBias.flatMap(floatBuffer)
        let darkBuf = masterDark.flatMap(floatBuffer)
        let flatBuf = masterFlat.flatMap(floatBuffer)

        for buffer in [biasBuf, darkBuf, flatBuf].compactMap({ $0 }) {
            guard buffer.width == width && buffer.height == height else { return nil }
        }

        // Dark は通常 Bias 成分を含む。両方をそのまま引く二重減算を避ける。
        if let darkBuf = darkBuf {
            var result = [Float](repeating: 0, count: count)
            vDSP_vsub(darkBuf.pixels, 1, lightBuf.pixels, 1, &result, 1, vDSP_Length(count))
            lightBuf = FloatBuffer(pixels: result, width: width, height: height)
        } else if let biasBuf = biasBuf {
            var result = [Float](repeating: 0, count: count)
            vDSP_vsub(biasBuf.pixels, 1, lightBuf.pixels, 1, &result, 1, vDSP_Length(count))
            lightBuf = FloatBuffer(pixels: result, width: width, height: height)
        }
        restoreOpaqueAlpha(in: &lightBuf.pixels)

        // Step 3: Flat-field division (normalize flat first)
        if let flatBuf = flatBuf {
            var rgbSum: Float = 0
            for i in stride(from: 0, to: count, by: 4) {
                rgbSum += flatBuf.pixels[i] + flatBuf.pixels[i + 1] + flatBuf.pixels[i + 2]
            }
            let mean = rgbSum / Float(width * height * 3)
            guard mean > 0 else { return nil }

            for i in stride(from: 0, to: count, by: 4) {
                for channel in 0..<3 {
                    let normalizedFlat = flatBuf.pixels[i + channel] / mean
                    guard normalizedFlat > 0.000_001 else { continue }
                    lightBuf.pixels[i + channel] /= normalizedFlat
                }
                lightBuf.pixels[i + 3] = 1.0
            }
        }

        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(lightBuf.pixels, 1, &lo, &hi, &lightBuf.pixels, 1, vDSP_Length(count))
        restoreOpaqueAlpha(in: &lightBuf.pixels)

        // Convert back to NSImage
        return nsImage(from: lightBuf.pixels, width: width, height: height)
    }

    /// Given a list of raw calibration images (e.g. multiple dark frames),
    /// create a master frame by median-stacking them.
    static func buildMaster(images: [NSImage]) -> NSImage? {
        return ImageStacker.stack(images: images, mode: .median)
    }

    // MARK: - Private Helpers

    struct FloatBuffer {
        var pixels: [Float]
        let width: Int
        let height: Int
    }

    static func floatBuffer(from image: NSImage) -> FloatBuffer? {
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

    private static func restoreOpaqueAlpha(in pixels: inout [Float]) {
        for index in stride(from: 3, to: pixels.count, by: 4) {
            pixels[index] = 1.0
        }
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
                  width: width, height: height,
                  bitsPerComponent: 16, bitsPerPixel: 64,
                  bytesPerRow: width * 8, space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                  ),
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
