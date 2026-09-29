import XCTest
import CoreGraphics
import ImageIO
@testable import OpenCVWrapper

/// タイムラプスの揺れ補正のテスト。星は日周運動で動き、地上（岩肌）はカメラの揺れの分だけずれる画像で、
/// 星ではなく地上の揺れを打ち消すことを確かめる。
final class TimelapseStabilizerTests: XCTestCase {
    private let width = 800
    private let height = 540
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TimelapseStabilizerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// 地上の模様（下半分と左の崖）。ぼかした乱数で、写真の岩肌のような大小の模様にする
    private lazy var groundTexture: [Float] = {
        var random = Random(state: 11)
        let coarse = 8
        let cw = width / coarse + 2, ch = height / coarse + 2
        let grid = (0..<(cw * ch)).map { _ in Float(random.next()) }
        var texture = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let gx = Float(x) / Float(coarse), gy = Float(y) / Float(coarse)
                let x0 = Int(gx), y0 = Int(gy), fx = gx - Float(x0), fy = gy - Float(y0)
                let v = grid[y0 * cw + x0] * (1 - fx) * (1 - fy) + grid[y0 * cw + x0 + 1] * fx * (1 - fy)
                    + grid[(y0 + 1) * cw + x0] * (1 - fx) * fy + grid[(y0 + 1) * cw + x0 + 1] * fx * fy
                texture[y * width + x] = 3000 + 9000 * v + Float(random.next()) * 1500
            }
        }
        return texture
    }()

    private func isGround(_ x: Int, _ y: Int) -> Bool {
        y > height / 2 || x < width / 4
    }

    /// 星を starShift、地上を groundShift だけずらした 16bit グレーのTIFFを書く
    private func writeFrame(_ index: Int, starShift: (Double, Double), groundShift: (Int, Int)) throws -> URL {
        var random = Random(state: 1000 + UInt64(index))
        var starsRandom = Random(state: 5)
        var image = [Float](repeating: 0, count: width * height)
        for i in 0..<image.count { image[i] = Float(800 + (random.next() - 0.5) * 200) }
        for _ in 0..<300 {
            let cx = starsRandom.next() * Double(width) + starShift.0
            let cy = starsRandom.next() * Double(height) + starShift.1
            let brightness = 3000 + starsRandom.next() * 20000
            let top = max(0, Int(cy) - 3), bottom = min(height - 1, Int(cy) + 3)
            let left = max(0, Int(cx) - 3), right = min(width - 1, Int(cx) + 3)
            guard top <= bottom, left <= right else { continue }
            for y in top...bottom {
                for x in left...right {
                    let d2 = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)
                    image[y * width + x] += Float(brightness * exp(-d2 / 2.0))
                }
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let sx = x - groundShift.0, sy = y - groundShift.1
                guard (0..<width).contains(sx), (0..<height).contains(sy), isGround(sx, sy) else { continue }
                image[y * width + x] = groundTexture[sy * width + sx]
            }
        }
        var pixels = image.map { UInt16(max(0, min(65535, $0))) }
        let url = directory.appendingPathComponent("frame\(index).tif")
        let provider = CGDataProvider(data: Data(bytes: &pixels, count: pixels.count * 2) as CFData)!
        let cgImage = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                              bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func project(_ h: [NSNumber], _ point: (Double, Double)) -> (Double, Double) {
        let m = h.map(\.doubleValue)
        let w = m[6] * point.0 + m[7] * point.1 + m[8]
        return ((m[0] * point.0 + m[1] * point.1 + m[2]) / w, (m[3] * point.0 + m[4] * point.1 + m[5]) / w)
    }

    func testCancelsGroundShakeWhileStarsMove() throws {
        // 固定撮影の揺れ: 星は毎フレーム動き、地上はカメラの揺れの分だけずれる
        let shakes = [(0, 0), (4, -3), (-5, 2), (7, 6), (1, -4)]
        let stabilizer = TimelapseStabilizer()
        for (index, shake) in shakes.enumerated() {
            let url = try writeFrame(index, starShift: (Double(index) * 9, Double(index) * 3), groundShift: shake)
            let h = try stabilizer.homographyForImage(at: url)
            // フレームの地上の点 (x+shake) は最初のフレームの (x) に写る
            for point in [(100.0, 400.0), (600.0, 450.0), (60.0, 150.0)] {
                let mapped = project(h, (point.0 + Double(shake.0), point.1 + Double(shake.1)))
                XCTAssertLessThan(hypot(mapped.0 - point.0, mapped.1 - point.1), 0.7,
                                  "フレーム\(index): 星ではなく地上の揺れを打ち消すこと")
            }
        }
        XCTAssertEqual(stabilizer.failedFrameCount, 0)
    }

    func testKeepsFramesWithoutGroundInsteadOfFailing() throws {
        // 地上の写っていない（ノイズと星だけの）フレームは補正せずそのまま使い、書き出しを止めない
        let stabilizer = TimelapseStabilizer()
        for index in 0..<3 {
            var random = Random(state: UInt64(index + 77))
            var pixels = (0..<(width * height)).map { _ in UInt16(800 + random.next() * 200) }
            let url = directory.appendingPathComponent("noise\(index).tif")
            let provider = CGDataProvider(data: Data(bytes: &pixels, count: pixels.count * 2) as CFData)!
            let cgImage = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                                  bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, cgImage, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let h = try stabilizer.homographyForImage(at: url).map(\.doubleValue)
            XCTAssertEqual(h, [1, 0, 0, 0, 1, 0, 0, 0, 1], "合わせられないフレームは動かさない")
        }
        XCTAssertEqual(stabilizer.failedFrameCount, 2)
    }
}
