import XCTest
@testable import MacSequator

/// 新星景モードの地上固定フレーム
final class GroundFixedTests: XCTestCase {
    func testGroundReferenceScalesExposureAndTakesTheMedian() {
        // 黒レベル 100。倍率 1・2・4 で揃えると、どれも黒からの値が 400 になる
        let frames: [[UInt16]] = [[500, 100], [300, 100], [200, 100]]
        let reference = NightscapeCompositor.groundReference(frames: frames, scales: [1, 2, 4], blackLevel: 100, whiteLevel: 10000)
        XCTAssertEqual(reference, [500, 100])
        // 3枚なら中央値（外れた1枚に引きずられない）
        let median = NightscapeCompositor.groundReference(frames: [[1000], [1100], [9000]], scales: [1, 1, 1],
                                                          blackLevel: 0, whiteLevel: 65535)
        XCTAssertEqual(median, [1100])
        // 2枚なら平均
        let mean = NightscapeCompositor.groundReference(frames: [[1000], [2000]], scales: [1, 1], blackLevel: 0, whiteLevel: 65535)
        XCTAssertEqual(mean, [1500])
    }

    func testGroundReferenceSkipsSaturatedValuesAndClampsToWhite() {
        // 露出の長いフレーム（倍率1）で白飛びした値は使わず、短いフレーム（倍率4）を揃えた値にする
        let reference = NightscapeCompositor.groundReference(frames: [[10000], [1000]], scales: [1, 4],
                                                             blackLevel: 0, whiteLevel: 10000)
        XCTAssertEqual(reference, [4000])
        // 揃えると飽和を超える値・すべて飽和した値は白レベルにする
        let clamped = NightscapeCompositor.groundReference(frames: [[9900], [5000]], scales: [1, 4], blackLevel: 0, whiteLevel: 10000)
        XCTAssertEqual(clamped, [10000])
        let saturated = NightscapeCompositor.groundReference(frames: [[9990], [9995]], scales: [1, 1], blackLevel: 0, whiteLevel: 10000)
        XCTAssertEqual(saturated, [10000])
    }

    func testExposureScaleFromMetadata() {
        var light = RawMetadataInfo()
        light.exposureTime = 30
        light.iso = 8000
        light.fNumber = 2.8
        var ground = light
        ground.exposureTime = 8
        XCTAssertEqual(NightscapeCompositor.exposureScale(light: light, ground: ground) ?? 0, 3.75, accuracy: 1e-9)
        ground.iso = 1600
        ground.fNumber = 5.6
        XCTAssertEqual(NightscapeCompositor.exposureScale(light: light, ground: ground) ?? 0, 30.0 * 8000 / (8 * 1600) * 4,
                       accuracy: 1e-9)
        ground.exposureTime = nil
        XCTAssertNil(NightscapeCompositor.exposureScale(light: light, ground: ground))
    }

    func testMultiplyComposesTransforms() {
        let shift: [NSNumber] = [1, 0, 5, 0, 1, -3, 0, 0, 1]
        let scale: [NSNumber] = [2, 0, 0, 0, 2, 0, 0, 0, 1]
        // 拡大してから移動: (x, y) → (2x + 5, 2y - 3)
        XCTAssertEqual(NightscapeCompositor.multiply(shift, scale).map(\.doubleValue), [2, 0, 5, 0, 2, -3, 0, 0, 1])
    }

    func testNightscapeKeyChangesWithGroundFixedFrames() {
        var input = RawStackPipeline.Input(
            lights: [URL(fileURLWithPath: "/a.cr2"), URL(fileURLWithPath: "/b.cr2")], baseIndex: 0, darks: [], flats: [],
            biases: [], mode: .average, align: true, skyGroundMask: nil, maskFeatherRadius: 0, trailMasks: [:], nightscape: true)
        let plain = RawStackPipeline.nightscapeKey(for: input)
        input.groundFixed = [URL(fileURLWithPath: "/g.cr2")]
        XCTAssertTrue(input.usesGroundFixed)
        XCTAssertNotEqual(RawStackPipeline.nightscapeKey(for: input), plain)
        // 比較明では地上固定フレームを使わない
        input.nightscape = false
        XCTAssertFalse(input.usesGroundFixed)
    }
}
