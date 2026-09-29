import XCTest
import CoreGraphics
import ImageIO
@testable import MacSequator

/// タイムラプスの「星に合わせる」位置合わせのテスト。
/// 固定撮影（地上は動かず、星が少しずつ動く）で、各フレームを最初のフレームの星の位置に揃える。
final class TimelapseAlignmentTests: XCTestCase {
    private let width = 800
    private let height = 540
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TimelapseAlignmentTests-\(UUID().uuidString)")
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

    /// 星を starShift だけずらし、下 1/3 に動かない地上を置いた 16bit グレーのTIFFを書く
    private func writeFrame(_ index: Int, starShift: (Double, Double), withStars: Bool = true) throws -> URL {
        var noise = Random(state: 500 + UInt64(index))
        var stars = Random(state: 9)
        var ground = Random(state: 3)
        var image = [Float](repeating: 0, count: width * height)
        for i in 0..<image.count { image[i] = Float(800 + (noise.next() - 0.5) * 200) }
        for _ in 0..<300 {
            let cx = stars.next() * Double(width) + starShift.0
            let cy = stars.next() * Double(height) + starShift.1
            let brightness = 3000 + stars.next() * 20000
            guard withStars else { continue }
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
        for y in (height * 2 / 3)..<height {
            for x in 0..<width {
                image[y * width + x] = Float(3000 + ground.next() * 9000)
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

    func testStarAlignmentFollowsStarsAcrossFramesAndCloudyGap() throws {
        let aligner = StarTimelapseAligner()
        // 星は毎フレーム (8, 3) px 動く。フレーム3は雲で星が写っていない
        for index in 0..<6 {
            let shift = (Double(index) * 8, Double(index) * 3)
            let url = try writeFrame(index, starShift: shift, withStars: index != 3)
            let h = try aligner.homographyForImage(at: url)
            guard index != 3 else { continue }
            // フレームの星の位置 (x+shift) は最初のフレームの (x) に写る
            for point in [(300.0, 100.0), (600.0, 250.0)] {
                let mapped = project(h, (point.0 + shift.0, point.1 + shift.1))
                XCTAssertLessThan(hypot(mapped.0 - point.0, mapped.1 - point.1), 0.5,
                                  "フレーム\(index): 最初のフレームの星の位置に揃うこと")
            }
        }
        XCTAssertEqual(aligner.failedFrameCount, 1, "星の無いフレームだけが位置合わせできない")
    }

    func testAlignmentChoicesAreOfferedInOrder() {
        XCTAssertEqual(TimelapseSettings.FrameAlignment.allCases, [.none, .ground, .stars])
        XCTAssertEqual(TimelapseSettings().alignment, .none)
    }
}
