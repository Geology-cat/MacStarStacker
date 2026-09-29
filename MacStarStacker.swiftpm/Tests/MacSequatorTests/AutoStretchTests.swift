import XCTest
import AppKit
@testable import MacSequator

final class AutoStretchTests: XCTestCase {
    /// 一様な明るさ value（0〜1）に、決まった模様のばらつきを加えた 16bit 画像
    private func makeImage(background: Double, spread: Double = 0.01, width: Int = 200, height: Int = 100) -> CGImage {
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let noise = (Double((x * 37 + y * 101) % 17) / 16 - 0.5) * 2 * spread
                let value = UInt16(max(0, min(1, background + noise)) * 65535)
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 65535
            }
        }
        let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 2) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func median(of image: CGImage) -> Double {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let row = context.bytesPerRow / 2
        let p = context.data!.bindMemory(to: UInt16.self, capacity: row * image.height)
        var values: [Double] = []
        for y in 0..<image.height { for x in 0..<image.width { values.append(Double(p[y * row + x * 4]) / 65535) } }
        return values.sorted()[values.count / 2]
    }

    func testMidtonesTransferMapsBalancePointToHalf() {
        XCTAssertEqual(AutoStretch.midtonesTransfer(0, balance: 0.1), 0)
        XCTAssertEqual(AutoStretch.midtonesTransfer(1, balance: 0.1), 1)
        XCTAssertEqual(AutoStretch.midtonesTransfer(0.1, balance: 0.1), 0.5, accuracy: 1e-9)
        let m = AutoStretch.midtonesBalance(mapping: 0.03, to: 0.2)
        XCTAssertEqual(AutoStretch.midtonesTransfer(0.03, balance: m), 0.2, accuracy: 1e-9)
    }

    func testDarkNightSkyIsLiftedToTargetBackgroundWithoutBlowingOut() throws {
        // 暗い夜空（背景 0.05）
        let image = makeImage(background: 0.05, spread: 0.01)
        let parameters = AutoStretch.parameters(for: image)
        XCTAssertLessThan(parameters.midtones, 0.5, "暗い画像は持ち上げる")
        let stretched = try XCTUnwrap(AutoStretch.apply(parameters, to: image))
        XCTAssertEqual(median(of: stretched), AutoStretch.targetBackground, accuracy: 0.03,
                       "背景は目標の明るさになり、白く飛ばない")
    }

    func testNearlyBlackImageIsLiftedOnlyUpToTheLimit() {
        // ほぼ真っ黒な画像はノイズを強調しすぎないよう、持ち上げに上限がある
        let parameters = AutoStretch.parameters(for: makeImage(background: 0.003, spread: 0.002))
        XCTAssertEqual(parameters.midtones, AutoStretch.minimumMidtones)
    }

    func testBrightImageIsNotLiftedFurther() {
        // すでに明るい画像（背景 0.45）は何もしない
        let parameters = AutoStretch.parameters(for: makeImage(background: 0.45, spread: 0.02))
        XCTAssertEqual(parameters, .identity)
    }
}
