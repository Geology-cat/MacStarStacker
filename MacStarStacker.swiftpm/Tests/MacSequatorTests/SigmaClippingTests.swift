import XCTest
import AppKit
@testable import MacSequator

/// 平均のシグマクリッピング（中央値基準の反復）のテスト
final class SigmaClippingTests: XCTestCase {
    private func clippedMean(_ values: [Float], _ clipping: SigmaClipping = SigmaClipping(), floor: Float = 1) -> Float {
        var copy = values
        var scratch = [Float](repeating: 0, count: values.count)
        return copy.withUnsafeMutableBufferPointer { v in
            scratch.withUnsafeMutableBufferPointer { s in
                clipping.clippedMean(v.baseAddress!, count: values.count, scratch: s.baseAddress!, floor: floor)
            }
        }
    }

    func testBrightOutlierIsRejected() {
        // 飛行機の光跡のような1枚だけ明るい値は除き、残りの平均にする
        let values: [Float] = [1000, 1010, 990, 1005, 995, 1002, 998, 9000]
        XCTAssertEqual(clippedMean(values), 1000, accuracy: 1)
        // 単純な平均は光跡に引っ張られる
        XCTAssertGreaterThan(values.reduce(0, +) / Float(values.count), 1900)
    }

    func testDarkAndBrightKappaAreSeparate() {
        // 少し暗い値（950、ばらつきの約7倍）は、下側 κ=10 なら残し、κ=3 なら除く。明るい値（1300）は上側 κ=3 で除く
        let values: [Float] = [1000, 1010, 990, 1005, 995, 1002, 998, 950, 1300]
        let keepsDark = (values.reduce(0, +) - 1300) / Float(values.count - 1)
        let dropsDark = (values.reduce(0, +) - 1300 - 950) / Float(values.count - 2)
        XCTAssertEqual(clippedMean(values, SigmaClipping(low: 10, high: 3)), keepsDark, accuracy: 0.5)
        XCTAssertEqual(clippedMean(values, SigmaClipping(low: 3, high: 3)), dropsDark, accuracy: 0.5)
    }

    func testFewerThanThreeFramesIsPlainMean() {
        XCTAssertEqual(clippedMean([100, 5000]), 2550, accuracy: 0.01)
    }

    func testIdenticalValuesDoNotRejectEverything() {
        // ばらつきが0でも（量子化の幅を下限にして）同じ値を残し、外れた値だけ除く
        XCTAssertEqual(clippedMean([500, 500, 500, 500, 501, 500, 4000]), 500.17, accuracy: 0.05)
    }

    func testStreamingStackerRejectsASpikeOnlyWhenClipping() {
        var frames = (0..<6).map { index in [UInt16](repeating: UInt16(1000 + index), count: 16) }
        frames[3][5] = 60000
        let clipped = StreamingStacker(mode: .average, count: 16, clipping: SigmaClipping())
        let plain = StreamingStacker(mode: .average, count: 16)
        for frame in frames { clipped.add(frame); plain.add(frame) }
        XCTAssertLessThan(abs(Int(clipped.result()[5]) - 1002), 2, "光った1枚を除いて平均する")
        XCTAssertGreaterThan(Int(plain.result()[5]), 10000, "シグマクリッピングしなければ光った値も平均に入る")
        XCTAssertEqual(Int(clipped.result()[0]), Int(plain.result()[0]), "外れ値の無い画素は同じ")
    }

    func testDevelopedImagesUseSigmaClipping() throws {
        func image(_ value: UInt8, spike: Bool) -> NSImage {
            var pixels = [UInt8](repeating: value, count: 8 * 8 * 4)
            for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
            if spike { pixels[0] = 255; pixels[1] = 255; pixels[2] = 255 }
            let cg = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                             provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                             shouldInterpolate: false, intent: .defaultIntent)!
            return NSImage(cgImage: cg, size: NSSize(width: 8, height: 8))
        }
        let images = (0..<6).map { image(60, spike: $0 == 2) }
        let clipped = try XCTUnwrap(ImageStacker.stack(images: images, mode: .average, sigmaClipping: SigmaClipping()))
        let plain = try XCTUnwrap(ImageStacker.stack(images: images, mode: .average))
        func firstRed(_ image: NSImage) -> Int {
            let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            return Int((rep.colorAt(x: 0, y: 0)?.redComponent ?? 0) * 255)
        }
        XCTAssertLessThan(firstRed(clipped), firstRed(plain) - 20, "光った1枚を除く")
    }

    func testSigmaClippingRetainsFramesAndIsMemoryChecked() throws {
        let info = RawSensorInfo(
            width: 5496, height: 3670, isBayer: true, cfaPattern: [0, 1, 1, 2], flip: 0,
            blackLevels: [512, 512, 512, 512], whiteLevel: 16000, colorMatrix1: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            illuminant1: 21, colorMatrix2: nil, illuminant2: 0, cameraMultipliers: [2, 1, 1.5], make: "Canon", model: "EOS 6D"
        )
        let gigabyte: UInt64 = 1_073_741_824
        // 位置合わせあり20枚（約2.4GB）: 平均だけならフレームを保持しないので可、シグマクリッピングは4GBでは不可
        XCTAssertNoThrow(try RawStackPipeline.checkMemory(frameCount: 20, info: info, kind: .cameraRGB, mode: .average,
                                                          hasSkyGroundMask: false, physicalMemory: 4 * gigabyte))
        XCTAssertThrowsError(try RawStackPipeline.checkMemory(frameCount: 20, info: info, kind: .cameraRGB, mode: .average,
                                                              hasSkyGroundMask: false, sigmaClipping: true,
                                                              physicalMemory: 4 * gigabyte)) { error in
            XCTAssertTrue(error.localizedDescription.contains("シグマクリッピング"))
        }
    }

    func testSettingsShowSigmaClippingOnlyForAverage() throws {
        let state = StackingStateController.shared
        let previous = (state.stackMode, state.enableSigmaClipping, state.enableSkyGroundMask)
        defer { (state.stackMode, state.enableSigmaClipping, state.enableSkyGroundMask) = previous }
        state.enableSkyGroundMask = false
        state.enableSigmaClipping = false
        state.stackMode = "Average"
        let controller = SettingsViewController()
        _ = controller.view  // loadViewIfNeeded() は macOS 14 以降
        func views() -> [NSView] {
            var result: [NSView] = []
            var stack: [NSView] = [controller.view]
            while let view = stack.popLast() { result.append(view); stack.append(contentsOf: view.subviews) }
            return result
        }
        let checkbox = try XCTUnwrap(views().compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("シグマクリッピング") })
        let lowField = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "SigmaLowField" })
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        settle()
        XCTAssertFalse(checkbox.isHidden)
        XCTAssertTrue(lowField.superview?.isHidden ?? true, "OFFの間は κ を出さない")

        checkbox.state = .on
        XCTAssertTrue(checkbox.sendAction(checkbox.action, to: checkbox.target))
        settle()
        XCTAssertTrue(state.enableSigmaClipping)
        XCTAssertFalse(lowField.superview?.isHidden ?? true)
        lowField.stringValue = "2.5"
        XCTAssertTrue(lowField.sendAction(lowField.action, to: lowField.target))
        XCTAssertEqual(state.sigmaClipping.low, 2.5, accuracy: 0.001)
        XCTAssertNotNil(state.activeSigmaClipping)

        state.stackMode = "Median"
        settle()
        XCTAssertTrue(checkbox.isHidden, "中央値では出さない")
        XCTAssertNil(state.activeSigmaClipping)

        // 新星景モードでは常にON（変更不可）
        state.stackMode = "Average"
        state.enableSigmaClipping = false
        state.enableSkyGroundMask = true
        settle()
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertFalse(checkbox.isEnabled)
        XCTAssertNotNil(state.activeSigmaClipping)
        state.enableSkyGroundMask = false
        state.sigmaClipping = SigmaClipping()
    }
}
