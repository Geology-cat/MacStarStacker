import XCTest
import AppKit
import CoreImage
import LibRawBridge
@testable import MacSequator

/// RAW（ベイヤー配列）のまま合成する経路のテスト。入力には既知の値で作ったベイヤー配列DNGを使う。
final class RawStackPipelineTests: XCTestCase {
    private var directory: URL!

    private let black: UInt16 = 512
    private let white: Double = 16000
    /// RGGB
    private let pattern: [UInt8] = [0, 1, 1, 2]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RawStackPipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func placeholder() -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    private func testCamera(orientation: UInt16 = 1) -> DNGWriter.CameraColorProfile {
        DNGWriter.CameraColorProfile(
            make: "Canon", model: "EOS 6D", uniqueCameraModel: "Canon EOS 6D",
            colorMatrix1: [0.7034, -0.0804, -0.1014, -0.4420, 1.2564, 0.2058, -0.0851, 0.1994, 0.5758],
            illuminant1: 21, colorMatrix2: nil, illuminant2: 0,
            asShotNeutral: [0.5, 1, 0.6], orientation: orientation
        )
    }

    /// 既知の生の値を持つベイヤー配列DNGを作る
    @discardableResult
    private func makeBayerDNG(_ name: String, width: Int = 64, height: Int = 48, orientation: UInt16 = 1,
                              value: (Int, Int, UInt8) -> UInt16) throws -> (URL, [UInt16]) {
        var pixels = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = value(x, y, pattern[(y & 1) << 1 | (x & 1)])
            }
        }
        let url = directory.appendingPathComponent(name)
        try DNGWriter.writeBayer(
            pixels: pixels, width: width, height: height,
            mosaic: DNGWriter.BayerMosaic(pattern: pattern, blackLevels: [512, 512, 512, 512], whiteLevel: white),
            camera: testCamera(orientation: orientation), previewSource: placeholder(), metadata: nil, embedLensProfile: false, to: url
        )
        return (url, pixels)
    }

    private func input(lights: [URL], darks: [URL] = [], flats: [URL] = [], mode: RawStackPipeline.Mode,
                       align: Bool = false, mask: NSImage? = nil, trails: [Int: [NSImage]] = [:]) -> RawStackPipeline.Input {
        RawStackPipeline.Input(lights: lights, baseIndex: 0, darks: darks, flats: flats, biases: [], mode: mode,
                               align: align, skyGroundMask: mask, maskFeatherRadius: 0, trailMasks: trails)
    }

    // MARK: - 読み込み

    func testLibRawReadsBayerDNGWithoutChangingValues() throws {
        let (url, pixels) = try makeBayerDNG("roundtrip.dng") { x, y, color -> UInt16 in
            let value: Int = 600 + x * 7 + y * 13 + Int(color) * 100
            return UInt16(value)
        }
        let frame = try RawDecoder.readBayer(from: url)
        XCTAssertTrue(frame.info.isBayer)
        XCTAssertEqual(frame.info.width, 64)
        XCTAssertEqual(frame.info.height, 48)
        XCTAssertEqual(frame.info.cfaPattern, pattern, "ベイヤー配列の位相")
        XCTAssertEqual(frame.info.blackLevels, [512, 512, 512, 512])
        XCTAssertEqual(frame.info.whiteLevel, white, accuracy: 1)
        XCTAssertEqual(frame.pixels, pixels, "生の値がそのまま読めること")
    }

    func testCameraRGBDemosaicKeepsUnbalancedChannelRatios() throws {
        // デモザイクは撮影時ホワイトバランス（AsShotNeutral 0.5,1,0.6 → 係数 2,1,1.67）を掛けて行うが、
        // 結果はホワイトバランスなしのカメラ色空間の値に戻ること（R・G・Bの比が生の値の比のまま）
        let raw: [UInt16] = [3000, 2000, 1200]
        let (url, _) = try makeBayerDNG("flat.dng") { _, _, color in raw[Int(color)] }
        let frame = try RawDecoder.demosaicCameraRGB(from: url)
        let count = Double(frame.width * frame.height)
        var means = [Double](repeating: 0, count: 3)
        for i in 0..<(frame.width * frame.height) {
            for c in 0..<3 { means[c] += Double(frame.pixels[i * 3 + c]) / count }
        }
        // 出力は黒が blackLevel、センサーの飽和が whiteLevel になる線形の値
        let above = means.map { $0 - frame.blackLevel }
        let expectedRed = Double(raw[0] - black) / Double(raw[1] - black)
        let expectedBlue = Double(raw[2] - black) / Double(raw[1] - black)
        XCTAssertEqual(above[0] / above[1], expectedRed, accuracy: expectedRed * 0.01)
        XCTAssertEqual(above[2] / above[1], expectedBlue, accuracy: expectedBlue * 0.01)
        let expectedGreen = Double(raw[1] - black) / (white - Double(black)) * (frame.whiteLevel - frame.blackLevel)
        XCTAssertEqual(above[1], expectedGreen, accuracy: expectedGreen * 0.01)
    }

    func testCameraRGBDemosaicKeepsValuesBelowBlack() throws {
        // 黒より暗いノイズ（生の値が黒レベル未満）を0に切り捨てず、黒レベルの台の下に残す。
        // 切り捨てると合成したときに最も暗い所の平均が持ち上がる
        let (url, _) = try makeBayerDNG("dark.dng") { x, y, _ in (x + y) % 2 == 0 ? black - 8 : black + 8 }
        let frame = try RawDecoder.demosaicCameraRGB(from: url)
        XCTAssertGreaterThan(frame.blackLevel, 0)
        let values = frame.pixels.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        XCTAssertEqual(mean, frame.blackLevel, accuracy: frame.blackLevel * 0.05, "黒の上下のノイズの平均は黒レベルのまま")
        XCTAssertGreaterThan(values.min() ?? 0, 0, "黒より暗い値が0に切り捨てられていない")
    }

    func testLinearDNGIsNotTreatedAsBayer() throws {
        // アプリが以前書き出したリニアDNG（デモザイク済み）はベイヤー経路に乗せない
        let context = CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 16, height: 12))
        let url = directory.appendingPathComponent("linear.dng")
        try DNGWriter.write(image: image, metadata: nil, embedLensProfile: false, to: url)

        // LibRawで開けないか、開けてもベイヤー配列ではないこと
        XCTAssertFalse((try? RawDecoder.readInfo(from: url))?.isBayer ?? false)
        let (bayer, _) = try makeBayerDNG("bayer.dng") { _, _, _ in 1000 }
        XCTAssertNil(RawStackPipeline.route(for: input(lights: [bayer, url], mode: .average)),
                     "ベイヤー配列でないファイルが混ざる場合は従来経路")
    }

    func testRouteDependsOnAlignment() throws {
        let (a, _) = try makeBayerDNG("a.dng") { _, _, _ in 1000 }
        let (b, _) = try makeBayerDNG("b.dng") { _, _, _ in 1000 }
        XCTAssertEqual(RawStackPipeline.route(for: input(lights: [a, b], mode: .average, align: false)), .bayer)
        XCTAssertEqual(RawStackPipeline.route(for: input(lights: [a, b], mode: .average, align: true)), .cameraRGB)
        // 新星景モードは位置合わせの設定に関係なくカメラ色空間RGB。比較明では使わない（塗ったマスクで分ける）
        var nightscape = input(lights: [a, b], mode: .median, align: false)
        nightscape.nightscape = true
        XCTAssertEqual(RawStackPipeline.route(for: nightscape), .cameraRGB)
        var compareBright = input(lights: [a, b], mode: .compareBright, align: false)
        compareBright.nightscape = true
        XCTAssertEqual(RawStackPipeline.route(for: compareBright), .bayer)
        let jpeg = directory.appendingPathComponent("frame.jpg")
        try Data([0xFF, 0xD8]).write(to: jpeg)
        XCTAssertNil(RawStackPipeline.route(for: input(lights: [a, jpeg], mode: .average)))
    }

    // MARK: - ベイヤー配列のまま合成

    /// テスト用カメラ（AsShotNeutral 0.5, 1, 0.6）での比較明合成の重み。RGGBの各位置のWB係数の逆数。
    private var brightWeights: [Double] { [0.5, 1, 1, 0.6] }

    /// 2x2ブロックごとに、WB係数の逆数で重み付けした合計が最大のフレームのブロックを採用した結果
    private func blockCompareBright(_ frames: [[UInt16]], width: Int = 64, height: Int = 48) -> [UInt16] {
        var output = frames[0]
        var best = [Double](repeating: -1, count: (width / 2) * (height / 2))
        for frame in frames {
            for by in 0..<(height / 2) {
                for bx in 0..<(width / 2) {
                    let i = [by * 2 * width + bx * 2, by * 2 * width + bx * 2 + 1, (by * 2 + 1) * width + bx * 2, (by * 2 + 1) * width + bx * 2 + 1]
                    var score = 0.0
                    for k in 0..<4 { score += brightWeights[k] * Double(frame[i[k]]) }
                    if score > best[by * (width / 2) + bx] {
                        best[by * (width / 2) + bx] = score
                        for k in 0..<4 { output[i[k]] = frame[i[k]] }
                    }
                }
            }
        }
        return output
    }

    func testCompareBrightSelectsWholeBayerBlocksWeightedByWhiteBalance() throws {
        let (a, pa) = try makeBayerDNG("a.dng") { x, y, _ in UInt16(800 + (x * 31 + y * 17) % 900) }
        let (b, pb) = try makeBayerDNG("b.dng") { x, y, _ in UInt16(800 + (x * 13 + y * 29) % 900) }
        let result = try XCTUnwrap(RawStackPipeline.stack(input(lights: [a, b], mode: .compareBright)) { _, _ in })
        XCTAssertEqual(result.kind, .bayer)
        XCTAssertEqual(result.pixels, blockCompareBright([pa, pb]))
        // 2x2ブロックの4画素は必ず同じフレームから来る（色の組み合わせが崩れない）
        for by in 0..<24 {
            for bx in 0..<32 {
                let i = [by * 128 + bx * 2, by * 128 + bx * 2 + 1, by * 128 + 64 + bx * 2, by * 128 + 65 + bx * 2]
                let fromA = i.allSatisfy { result.pixels[$0] == pa[$0] }
                let fromB = i.allSatisfy { result.pixels[$0] == pb[$0] }
                XCTAssertTrue(fromA || fromB, "ブロック(\(bx),\(by))が2枚のフレームの混ざりになっている")
            }
        }
    }

    func testCompareBrightNoiseFloorStaysNeutralAfterWhiteBalance() throws {
        // 真っ暗な空（黒レベル+ノイズのみ、センサー値でのノイズはR・G・B同じ）を30枚比較明合成する
        var seed: UInt64 = 12345
        func gaussian() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u1 = max(1e-12, Double(seed >> 11) / Double(1 << 53))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u2 = Double(seed >> 11) / Double(1 << 53)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let lights = try (0..<30).map { index -> URL in
            try makeBayerDNG("noise_\(index).dng") { _, _, _ in UInt16(Double(black) + 1000 + 40 * gaussian()) }.0
        }
        let result = try XCTUnwrap(RawStackPipeline.stack(input(lights: lights, mode: .compareBright)) { _, _ in })

        // WB後（R×2、B×1/0.6）の「本来の値1000からの底上げ量」が色ごとに揃っていること
        let multipliers = [2.0, 1.0, 1.0, 1 / 0.6]
        var lift = [Double](repeating: 0, count: 4), counts = [Double](repeating: 0, count: 4)
        for y in 0..<48 {
            for x in 0..<64 {
                let position = (y & 1) << 1 | (x & 1)
                lift[position] += (Double(result.pixels[y * 64 + x]) - Double(black) - 1000) * multipliers[position]
                counts[position] += 1
            }
        }
        let red = lift[0] / counts[0], green = (lift[1] + lift[2]) / (counts[1] + counts[2]), blue = lift[3] / counts[3]
        XCTAssertGreaterThan(green, 10, "比較明合成はノイズの分だけ明るくなる")
        XCTAssertEqual(red / green, 1, accuracy: 0.2, "赤だけ持ち上がるとマゼンタに転ぶ")
        XCTAssertEqual(blue / green, 1, accuracy: 0.2, "青だけ持ち上がるとマゼンタに転ぶ")
    }

    func testCompareBrightKeepsBrightestRGBPixelWeightedByWhiteBalance() {
        let stacker = StreamingStacker(mode: .compareBright, count: 6, grouping: .rgbPixels(weights: [0.5, 1, 0.6]))
        stacker.add([1000, 100, 1000, /**/ 10, 10, 10])
        stacker.add([100, 900, 100, /**/ 20, 5, 20])
        // 1画素目: 0.5*1000+100+0.6*1000=1200 > 0.5*100+900+0.6*100=1010 → 1枚目を丸ごと
        // 2画素目: 0.5*10+10+6=21 < 0.5*20+5+12=27 → 2枚目を丸ごと
        XCTAssertEqual(stacker.result(), [1000, 100, 1000, 20, 5, 20])
    }

    func testAverageAndMedianOnRawValues() throws {
        let (a, pa) = try makeBayerDNG("a.dng") { x, _, _ in UInt16(1000 + x) }
        let (b, pb) = try makeBayerDNG("b.dng") { x, _, _ in UInt16(2000 + x) }
        let (c, pc) = try makeBayerDNG("c.dng") { x, _, _ in UInt16(9000 + x) }

        let average = try XCTUnwrap(RawStackPipeline.stack(input(lights: [a, b, c], mode: .average)) { _, _ in })
        for i in [0, 5, 100, 3000] {
            let expected = (Double(pa[i]) + Double(pb[i]) + Double(pc[i])) / 3
            XCTAssertEqual(Double(average.pixels[i]), expected, accuracy: 0.51)
        }
        let median = try XCTUnwrap(RawStackPipeline.stack(input(lights: [a, b, c], mode: .median)) { _, _ in })
        XCTAssertEqual(median.pixels, pb, "3枚の中央値は中間のフレーム")
    }

    func testDarkSubtractionKeepsBlackLevelPedestal() throws {
        // 生の値 = 黒512 + 信号。ダーク（黒512 + 熱ノイズ40）を引いても黒レベルは保たれる
        let (light, _) = try makeBayerDNG("light.dng") { _, _, _ in 512 + 40 + 1000 }
        let (dark, _) = try makeBayerDNG("dark.dng") { _, _, _ in 512 + 40 }
        let result = try XCTUnwrap(RawStackPipeline.stack(input(lights: [light], darks: [dark], mode: .average)) { _, _ in })
        XCTAssertTrue(result.pixels.allSatisfy { $0 == 512 + 1000 })
    }

    func testFlatIsNormalizedPerCFAColor() throws {
        // 周辺減光のない一様なフラットでも、色ごとに明るさが違う（R:2000, G:4000, B:3000）
        let (light, _) = try makeBayerDNG("light.dng") { _, _, _ in 512 + 1000 }
        let (flat, _) = try makeBayerDNG("flat.dng") { _, _, color in 512 + [2000, 4000, 3000][Int(color)] }
        let result = try XCTUnwrap(RawStackPipeline.stack(input(lights: [light], flats: [flat], mode: .average)) { _, _ in })
        // 色ごとに正規化されていれば色かぶりは起きず、値は変わらない
        XCTAssertTrue(result.pixels.allSatisfy { $0 == 512 + 1000 }, "フラットで色かぶりが発生しています")
    }

    func testTrailRemovalReplacesMaskedPixelsWithNeighborFrames() throws {
        let width = 64, height = 48
        let (f0, _) = try makeBayerDNG("f0.dng") { _, _, _ in 1000 }
        // 中央の行に明るい光跡
        let (f1, _) = try makeBayerDNG("f1.dng") { _, y, _ in y == 24 || y == 25 ? 15000 : 1000 }
        let (f2, _) = try makeBayerDNG("f2.dng") { _, _, _ in 1000 }

        var maskPixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 14...35 {
            for x in 0..<width {
                let i = (y * width + x) * 4
                maskPixels[i] = 255; maskPixels[i + 1] = 255; maskPixels[i + 2] = 255
            }
        }
        for i in stride(from: 3, to: maskPixels.count, by: 4) { maskPixels[i] = 255 }
        let provider = CGDataProvider(data: Data(maskPixels) as CFData)!
        let maskCG = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let mask = NSImage(cgImage: maskCG, size: NSSize(width: width, height: height))

        let without = try XCTUnwrap(RawStackPipeline.stack(input(lights: [f0, f1, f2], mode: .compareBright)) { _, _ in })
        XCTAssertEqual(without.pixels[24 * width + 10], 15000)

        let with = try XCTUnwrap(RawStackPipeline.stack(input(lights: [f0, f1, f2], mode: .compareBright, trails: [1: [mask]])) { _, _ in })
        XCTAssertEqual(Double(with.pixels[24 * width + 10]), 1000, accuracy: 20, "光跡が前後フレームの値で置き換わること")
        XCTAssertEqual(with.pixels[5 * width + 10], 1000)
    }

    func testCompareBrightWithAlignmentStacksAlignedStarsAndRemovesTrails() throws {
        let width = 640, height = 480
        var stars: [(Int, Int, Int)] = []
        var seed: UInt64 = 21
        func random(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(upper))
        }
        for _ in 0..<400 { stars.append((20 + random(width - 40), 20 + random(height - 60), 3000 + random(9000))) }
        let trailRow = height - 20  // 星の無い下端付近を横切る光跡
        func field(shiftX: Int, shiftY: Int, trail: Bool = false) -> (Int, Int, UInt8) -> UInt16 {
            var canvas = [UInt16](repeating: 700, count: width * height)
            for (sx, sy, brightness) in stars {
                for dy in -3...3 {
                    for dx in -3...3 {
                        let d2 = dx * dx + dy * dy
                        let x = sx + shiftX + dx, y = sy + shiftY + dy
                        guard d2 <= 9, x >= 0, y >= 0, x < width, y < height else { continue }
                        canvas[y * width + x] = max(canvas[y * width + x], UInt16(700 + brightness / (1 + d2)))
                    }
                }
            }
            if trail {
                for y in (trailRow - 1)...(trailRow + 1) {
                    for x in 0..<width { canvas[y * width + x] = 14000 }
                }
            }
            return { x, y, _ in canvas[y * width + x] }
        }
        let (f0, _) = try makeBayerDNG("cb0.dng", width: width, height: height, value: field(shiftX: 0, shiftY: 0))
        let (f1, _) = try makeBayerDNG("cb1.dng", width: width, height: height, value: field(shiftX: 6, shiftY: 4, trail: true))
        let (f2, _) = try makeBayerDNG("cb2.dng", width: width, height: height, value: field(shiftX: 12, shiftY: 8))

        // フレーム1の光跡のマスク（表示の向き＝センサーの向き）
        var maskPixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in (trailRow - 6)...(trailRow + 6) {
            for x in 0..<width {
                let i = (y * width + x) * 4
                maskPixels[i] = 255; maskPixels[i + 1] = 255; maskPixels[i + 2] = 255
            }
        }
        for i in stride(from: 3, to: maskPixels.count, by: 4) { maskPixels[i] = 255 }
        let provider = CGDataProvider(data: Data(maskPixels) as CFData)!
        let maskCG = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let mask = NSImage(cgImage: maskCG, size: NSSize(width: width, height: height))

        let result = try XCTUnwrap(RawStackPipeline.stack(
            input(lights: [f0, f1, f2], mode: .compareBright, align: true, trails: [1: [mask]])) { _, _ in })
        XCTAssertEqual(result.kind, .cameraRGB, "位置合わせありはカメラ色空間RGBで合成する")

        // 位置合わせしなかった場合に星が写る位置（ずれた先）が、星の無い背景のままであること
        let background = try RawDecoder.demosaicCameraRGB(from: f0)
        func green(_ pixels: [UInt16], _ x: Int, _ y: Int) -> Double { Double(pixels[(y * width + x) * 3 + 1]) }
        /// (x, y) に（基準画像の）星が重なるか
        func hasStar(near x: Int, _ y: Int) -> Bool {
            stars.contains { abs($0.0 - x) < 5 && abs($0.1 - y) < 5 }  // 星の半径は3px
        }
        // ずれた先（6,4 と 12,8）に別の星が無い星だけを使う
        let isolated = stars.filter { !hasStar(near: $0.0 + 12, $0.1 + 8) && !hasStar(near: $0.0 + 6, $0.1 + 4) }.prefix(60)
        XCTAssertGreaterThan(isolated.count, 20)
        var atStars = 0.0, atShifted = 0.0
        for (sx, sy, _) in isolated {
            atStars += green(result.pixels, sx, sy)
            atShifted += green(result.pixels, sx + 12, sy + 8)
        }
        let backgroundLevel = green(background.pixels, 5, 5)
        XCTAssertLessThan((atShifted / Double(isolated.count)) - backgroundLevel,
                          0.1 * ((atStars / Double(isolated.count)) - backgroundLevel),
                          "星が合っていれば、ずれた位置に星の軌跡が残らない")

        // 光跡は前後のフレームの値に置き換わり、比較明合成の結果に残らない。
        // フレーム1は位置合わせで (-6, -4) 動くため、結果の画像では光跡は4行上の位置になる
        let trailX = (0..<width).first { x in !stars.contains { abs($0.0 - x) < 20 } } ?? 0
        XCTAssertLessThan(green(result.pixels, trailX, trailRow - 4), backgroundLevel * 1.5, "光跡が除去されていること")
    }

    func testSkyGroundMaskBlendsOnBayerData() throws {
        let width = 64, height = 48
        let (a, _) = try makeBayerDNG("a.dng") { _, _, _ in 1000 }
        let (b, _) = try makeBayerDNG("b.dng") { _, _, _ in 3000 }
        // 左半分を地上（緑）、右半分を空（青）
        var maskPixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                maskPixels[i + (x < width / 2 ? 1 : 2)] = 255
                maskPixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(maskPixels) as CFData)!
        let maskCG = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let mask = NSImage(cgImage: maskCG, size: NSSize(width: width, height: height))

        let result = try XCTUnwrap(RawStackPipeline.stack(input(lights: [a, b], mode: .compareBright, mask: mask)) { _, _ in })
        XCTAssertEqual(result.pixels[10 * width + 5], 2000, "地上（左）は平均")
        XCTAssertEqual(result.pixels[10 * width + 60], 3000, "空（右）は比較明")

        // 上下が非対称なマスク（下半分が地上）で、上下が反転しないこと
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                maskPixels[i + 1] = y >= height / 2 ? 255 : 0
                maskPixels[i + 2] = y >= height / 2 ? 0 : 255
            }
        }
        let verticalProvider = CGDataProvider(data: Data(maskPixels) as CFData)!
        let verticalCG = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                 provider: verticalProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let vertical = NSImage(cgImage: verticalCG, size: NSSize(width: width, height: height))
        let verticalResult = try XCTUnwrap(RawStackPipeline.stack(input(lights: [a, b], mode: .compareBright, mask: vertical)) { _, _ in })
        XCTAssertEqual(verticalResult.pixels[40 * width + 30], 2000, "地上（下）は平均")
        XCTAssertEqual(verticalResult.pixels[5 * width + 30], 3000, "空（上）は比較明")
    }

    func testSkyGroundMaskFollowsPortraitOrientation() throws {
        // センサー 64x48、Orientation=6（表示するには時計回りに90°回転 → 表示は 48x64 の縦位置）
        let (a, _) = try makeBayerDNG("portrait_a.dng", orientation: 6) { _, _, _ in 1000 }
        let (b, _) = try makeBayerDNG("portrait_b.dng", orientation: 6) { _, _, _ in 3000 }
        XCTAssertEqual(try RawDecoder.readInfo(from: a).orientation, 6)

        // 表示の向きで、下半分を地上（緑）、上半分を空（青）に塗ったマスク
        let displayWidth = 48, displayHeight = 64
        var maskPixels = [UInt8](repeating: 0, count: displayWidth * displayHeight * 4)
        for y in 0..<displayHeight {
            for x in 0..<displayWidth {
                let i = (y * displayWidth + x) * 4
                maskPixels[i + (y >= displayHeight / 2 ? 1 : 2)] = 255
                maskPixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(maskPixels) as CFData)!
        let maskCG = CGImage(width: displayWidth, height: displayHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: displayWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let mask = NSImage(cgImage: maskCG, size: NSSize(width: displayWidth, height: displayHeight))

        let result = try XCTUnwrap(RawStackPipeline.stack(input(lights: [a, b], mode: .compareBright, mask: mask)) { _, _ in })
        // 時計回り90°回転では、表示の下半分 = センサーの右半分（x >= 32）
        XCTAssertEqual(result.pixels[10 * 64 + 60], 2000, "表示の下（地上）= センサー右側は平均")
        XCTAssertEqual(result.pixels[10 * 64 + 4], 3000, "表示の上（空）= センサー左側は比較明")
        // 表示用画像は撮影時の向き（縦位置）、プレビューはセンサーの向き
        XCTAssertEqual(result.displayImage.size.width, 48)
        XCTAssertEqual(result.displayImage.size.height, 64)
        XCTAssertEqual(result.previewImage.width, 64)
    }

    func testMedianRefusesWhenFramesDoNotFitInMemory() throws {
        let (a, _) = try makeBayerDNG("m.dng") { _, _, _ in 1000 }
        let info = try RawDecoder.readInfo(from: a)
        let gigabyte: UInt64 = 1_073_741_824
        let full = RawSensorInfo(
            width: 5496, height: 3670, isBayer: true, cfaPattern: info.cfaPattern, flip: 0,
            blackLevels: info.blackLevels, whiteLevel: info.whiteLevel, colorMatrix1: info.colorMatrix1,
            illuminant1: info.illuminant1, colorMatrix2: nil, illuminant2: 0,
            cameraMultipliers: info.cameraMultipliers, make: "Canon", model: "EOS 6D"
        )
        // 6D 20枚・位置合わせあり中央値: 1枚121MB → 約2.4GB。16GB搭載なら可、4GB搭載なら不可
        XCTAssertNoThrow(try RawStackPipeline.checkMemory(frameCount: 20, info: full, kind: .cameraRGB, mode: .median,
                                                          hasSkyGroundMask: false, physicalMemory: 16 * gigabyte))
        XCTAssertThrowsError(try RawStackPipeline.checkMemory(frameCount: 20, info: full, kind: .cameraRGB, mode: .median,
                                                              hasSkyGroundMask: false, physicalMemory: 4 * gigabyte)) { error in
            XCTAssertEqual((error as? RawStackPipeline.PipelineError)?.allowsFallback, false)
        }
        // マスクありは地上側も保持するので2倍（約4.8GB）
        XCTAssertThrowsError(try RawStackPipeline.checkMemory(frameCount: 20, info: full, kind: .cameraRGB, mode: .median,
                                                              hasSkyGroundMask: true, physicalMemory: 8 * gigabyte))
        // 平均・比較明はフレームを保持しないので枚数に関係なく可
        XCTAssertNoThrow(try RawStackPipeline.checkMemory(frameCount: 5000, info: full, kind: .cameraRGB, mode: .average,
                                                          hasSkyGroundMask: true, physicalMemory: 4 * gigabyte))
    }

    // MARK: - 書き出し

    func testBayerResultIsWrittenAsCFADNGAndRendersForDisplay() throws {
        let (a, pa) = try makeBayerDNG("a.dng") { x, y, color -> UInt16 in
            let value: Int = 2000 + x * 20 + y * 10 + Int(color) * 500
            return UInt16(value)
        }
        let result = try XCTUnwrap(RawStackPipeline.stack(input(lights: [a], mode: .average)) { _, _ in })
        XCTAssertEqual(result.displayImage.size.width, 64, "表示用画像は合成結果と同じ大きさで現像されること")
        XCTAssertEqual(result.previewImage.width, 64)

        let url = directory.appendingPathComponent("out.dng")
        try result.writeDNG(metadata: nil, embedLensProfile: false, to: url)
        let reread = try RawDecoder.readBayer(from: url)
        XCTAssertTrue(reread.info.isBayer)
        XCTAssertEqual(reread.pixels, pa)
        XCTAssertEqual(reread.info.cfaPattern, pattern)
        XCTAssertEqual(reread.info.uniqueCameraModel, "Canon EOS 6D")
        if #available(macOS 12.0, *) {
            XCTAssertNotNil(CIRAWFilter(imageURL: url)?.previewImage, "埋め込みプレビューがmacOSに認識されること")
        }
    }

    // MARK: - アプリの合成処理から

    func testStackingControllerUsesBayerRouteAndExportsCFADNG() throws {
        let (a, pa) = try makeBayerDNG("light_a.dng") { x, y, _ in UInt16(900 + (x * 11 + y * 5) % 700) }
        let (b, pb) = try makeBayerDNG("light_b.dng") { x, y, _ in UInt16(900 + (x * 3 + y * 19) % 700) }
        let files = [ImageFile(url: a), ImageFile(url: b)]

        let state = StackingStateController()
        state.images = [.light: files, .dark: [], .flat: [], .bias: []]
        state.baseImage = files[0]
        state.stackMode = "Compare Bright"
        state.startStacking()
        let deadline = Date().addingTimeInterval(30)
        while state.isStacking && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(state.isStacking)
        let raw = try XCTUnwrap(state.stackedRawResult, state.stackingStatus)
        XCTAssertEqual(raw.kind, .bayer)
        XCTAssertNotNil(state.stackedResult)
        XCTAssertTrue(state.stackingStatus.contains("ベイヤー配列"), state.stackingStatus)
        XCTAssertEqual(raw.pixels, blockCompareBright([pa, pb]))

        let url = directory.appendingPathComponent("export.dng")
        try ImageExporter.write(image: try XCTUnwrap(state.stackedResult), format: .dng,
                                metadata: nil, embedLensProfile: false, rawResult: state.stackedRawResult, to: url)
        XCTAssertTrue(try RawDecoder.readInfo(from: url).isBayer, "DNG書き出しはベイヤー配列のまま")

        state.resetAll()
        XCTAssertNil(state.stackedRawResult)
    }

    func testStackedPreviewKeepsPixelsAfterBackgroundStackingFinishes() throws {
        // 実機と同じ2000万画素級のベイヤー配列DNG（小さい画像では遅延描画の不具合が再現しない）
        let width = 5496, height = 3670
        func largeBayerDNG(_ name: String, base: UInt16) throws -> URL {
            var row = [UInt16](repeating: 0, count: width)
            for x in 0..<width { row[x] = base + UInt16(x % 300) }
            var pixels = [UInt16](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBufferPointer { destination in
                row.withUnsafeBufferPointer { source in
                    for y in 0..<height {
                        destination.baseAddress!.advanced(by: y * width).update(from: source.baseAddress!, count: width)
                    }
                }
            }
            let url = directory.appendingPathComponent(name)
            try DNGWriter.writeBayer(
                pixels: pixels, width: width, height: height,
                mosaic: DNGWriter.BayerMosaic(pattern: pattern, blackLevels: [512, 512, 512, 512], whiteLevel: white),
                camera: testCamera(), previewSource: placeholder(), metadata: nil, embedLensProfile: false, to: url
            )
            return url
        }
        let files = [ImageFile(url: try largeBayerDNG("bright_a.dng", base: 4000)),
                     ImageFile(url: try largeBayerDNG("bright_b.dng", base: 4100))]

        let state = StackingStateController()
        state.images = [.light: files, .dark: [], .flat: [], .bias: []]
        state.baseImage = files[0]
        state.stackMode = "Compare Bright"
        state.startStacking()
        let deadline = Date().addingTimeInterval(300)
        while state.isStacking && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let raw = try XCTUnwrap(state.stackedRawResult, state.stackingStatus)

        // 合成処理の終了後（別スレッドの後片付けの後）に読んでも、表示用画像・プレビューが真っ黒にならないこと
        func meanBrightness(_ image: CGImage) -> Double {
            let rep = NSBitmapImageRep(cgImage: image)
            var sum = 0.0, count = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 16) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 16) {
                    let color = try! XCTUnwrap(rep.colorAt(x: x, y: y))
                    sum += Double(color.redComponent + color.greenComponent + color.blueComponent) / 3
                    count += 1
                }
            }
            return sum / Double(count)
        }
        let display = try XCTUnwrap(state.stackedResult?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(meanBrightness(display), 0.05, "表示用画像が真っ黒")
        XCTAssertGreaterThan(meanBrightness(raw.previewImage), 0.05, "プレビューが真っ黒")

        let url = directory.appendingPathComponent("bright.dng")
        try raw.writeDNG(metadata: nil, embedLensProfile: false, to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ] as CFDictionary))
        XCTAssertGreaterThan(meanBrightness(thumbnail), 0.05, "DNGのサムネイルが真っ黒")
    }

    // MARK: - 位置合わせあり（カメラ色空間RGB）

    func testCameraRGBRouteAlignsShiftedStarFields() throws {
        let width = 640, height = 480
        var stars: [(Int, Int, Int)] = []
        var seed: UInt64 = 7
        func random(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(upper))
        }
        for _ in 0..<400 { stars.append((20 + random(width - 40), 20 + random(height - 40), 3000 + random(9000))) }
        func field(shiftX: Int, shiftY: Int) -> (Int, Int, UInt8) -> UInt16 {
            // 星を先に描き込んだ配列を引くだけにして、テスト画像の生成を軽くする
            var canvas = [UInt16](repeating: 700, count: width * height)
            for (sx, sy, brightness) in stars {
                for dy in -3...3 {
                    for dx in -3...3 {
                        let d2 = dx * dx + dy * dy
                        let x = sx + shiftX + dx, y = sy + shiftY + dy
                        guard d2 <= 9, x >= 0, y >= 0, x < width, y < height else { continue }
                        let value = UInt16(700 + brightness / (1 + d2))
                        canvas[y * width + x] = max(canvas[y * width + x], value)
                    }
                }
            }
            return { x, y, _ in canvas[y * width + x] }
        }
        let (base, _) = try makeBayerDNG("base.dng", width: width, height: height, value: field(shiftX: 0, shiftY: 0))
        let (moved, _) = try makeBayerDNG("moved.dng", width: width, height: height, value: field(shiftX: 6, shiftY: 4))

        let result = try XCTUnwrap(RawStackPipeline.stack(input(lights: [base, moved], mode: .average, align: true)) { _, _ in })
        XCTAssertEqual(result.kind, .cameraRGB)
        XCTAssertEqual(result.width, width)

        // 基準画像の星の位置で、位置合わせ後も明るさが保たれている（ずれていれば平均で半分程度になる）
        let reference = try RawDecoder.demosaicCameraRGB(from: base)
        var alignedSum = 0.0, referenceSum = 0.0
        for (sx, sy, _) in stars.prefix(100) {
            let i = (sy * width + sx) * 3 + 1
            alignedSum += Double(result.pixels[i])
            referenceSum += Double(reference.pixels[i])
        }
        XCTAssertGreaterThan(alignedSum / referenceSum, 0.8, "位置合わせで星が重なっていません")

        let url = directory.appendingPathComponent("aligned.dng")
        try result.writeDNG(metadata: nil, embedLensProfile: false, to: url)
        let reread = try RawDecoder.readInfo(from: url)
        XCTAssertFalse(reread.isBayer, "位置合わせ結果はデモザイク済みのリニアDNG")
        if #available(macOS 12.0, *) {
            XCTAssertNotNil(CIRAWFilter(imageURL: url)?.previewImage)
        }
    }

    // MARK: - 古いmacOS向け（RAWは常にLibRawで読む）

    func testImageLoaderDecodesRAWWithLibRawAndAppliesOrientation() throws {
        let (landscape, _) = try makeBayerDNG("landscape.dng") { _, _, _ in 4000 }
        let (portrait, _) = try makeBayerDNG("portrait.dng", orientation: 6) { _, _, _ in 4000 }
        let a = try XCTUnwrap(ImageLoader.load(from: landscape)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual([a.width, a.height], [64, 48], "センサーと同じ大きさで現像されること（埋め込みプレビューではない）")
        let b = try XCTUnwrap(ImageLoader.load(from: portrait)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual([b.width, b.height], [48, 64], "撮影時の向き（90度回転）が反映されること")
    }

    func testOrientRotatesPixelsLikeEXIFOrientation() throws {
        // 3x2 の左上の画素だけ白い16bit画像
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 3, height: 2, bitsPerComponent: 16, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))  // 左下原点なので y=1 が上の行
        let image = try XCTUnwrap(context.makeImage())

        /// 白い画素の位置（左上原点）と画像の大きさ
        func whitePixel(_ image: CGImage?) throws -> [Int] {
            let image = try XCTUnwrap(image)
            let data = try XCTUnwrap(image.dataProvider?.data) as Data
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
                    let red = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
                    if red > 30000 { return [x, y, image.width, image.height] }
                }
            }
            return []
        }
        XCTAssertEqual(try whitePixel(image), [0, 0, 3, 2])
        XCTAssertEqual(try whitePixel(RawDecoder.orient(image, to: .right)), [1, 0, 2, 3], "時計回り: 左上→右上")
        XCTAssertEqual(try whitePixel(RawDecoder.orient(image, to: .left)), [0, 2, 2, 3], "反時計回り: 左上→左下")
        XCTAssertEqual(try whitePixel(RawDecoder.orient(image, to: .down)), [2, 1, 3, 2], "180度: 左上→右下")
    }

    func testLibRawShootingInfoReadsCameraFromRAW() throws {
        let (url, _) = try makeBayerDNG("meta.dng") { _, _, _ in 4000 }
        var info = LRShootingInfo()
        var message = [CChar](repeating: 0, count: 256)
        let code = url.withUnsafeFileSystemRepresentation { path in
            LRReadShootingInfo(path!, &info, &message, Int32(message.count))
        }
        XCTAssertEqual(code, 0, String(cString: message))
        let model = withUnsafeBytes(of: info.model) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        XCTAssertTrue(model.contains("6D"), "機種名: \(model)")
    }
}
