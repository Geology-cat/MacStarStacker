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

        // Step 1: Bias subtraction
        if let bias = masterBias, let biasBuf = floatBuffer(from: bias) {
            if biasBuf.width == width && biasBuf.height == height {
                var result = [Float](repeating: 0, count: count)
                vDSP_vsub(biasBuf.pixels, 1, lightBuf.pixels, 1, &result, 1, vDSP_Length(count))
                lightBuf = FloatBuffer(pixels: result, width: width, height: height)
            }
        }

        // Step 2: Dark subtraction (dark already contains bias, so no double-subtract)
        if let dark = masterDark, let darkBuf = floatBuffer(from: dark) {
            if darkBuf.width == width && darkBuf.height == height {
                var result = [Float](repeating: 0, count: count)
                vDSP_vsub(darkBuf.pixels, 1, lightBuf.pixels, 1, &result, 1, vDSP_Length(count))
                lightBuf = FloatBuffer(pixels: result, width: width, height: height)
            }
        }

        // Step 3: Flat-field division (normalize flat first)
        if let flat = masterFlat, let flatBuf = floatBuffer(from: flat) {
            if flatBuf.width == width && flatBuf.height == height {
                // Normalise flat to have mean = 1.0 to preserve brightness
                let mean = flatBuf.pixels.reduce(0, +) / Float(count)
                let normalised = mean > 0 ? flatBuf.pixels.map { $0 / mean } : flatBuf.pixels

                var result = [Float](repeating: 0, count: count)
                vDSP_vdiv(normalised, 1, lightBuf.pixels, 1, &result, 1, vDSP_Length(count))
                // Clamp result to [0, 1]
                var lo: Float = 0, hi: Float = 1
                vDSP_vclip(result, 1, &lo, &hi, &result, 1, vDSP_Length(count))
                lightBuf = FloatBuffer(pixels: result, width: width, height: height)
            }
        }

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
        let pixels: [Float]
        let width: Int
        let height: Int
    }

    static func floatBuffer(from image: NSImage) -> FloatBuffer? {
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
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
