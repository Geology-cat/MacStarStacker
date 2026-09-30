import XCTest
@testable import OpenCVWrapper

/// 新星景モード（空は星に、地上は地上に合わせて合成）のテスト。
/// 不規則な稜線と細い木のシルエットがある星景を作り、星が上へ動く（東向き相当）場合と下へ動く（西向き相当）場合、
/// 地上が動く（追尾撮影）場合で、地平線付近に帯が出ないこと・星と稜線がくっきりすることを確かめる。
final class NightscapeTests: XCTestCase {
    private let width = 480
    private let height = 320
    private let frameCount = 8
    private let skyLevel: Float = 2000

    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// 稜線の高さ（この y より下が地上）
    private func ridge(_ x: Int) -> Double {
        200 + 25 * sin(Double(x) / 37) + 12 * sin(Double(x) / 11)
    }

    /// 木のシルエット（稜線から上に伸びる幅2pxの幹）
    private func isTree(_ x: Int, _ y: Int) -> Bool {
        for trunk in stride(from: 40, to: 480, by: 70) where x >= trunk && x < trunk + 2 {
            return Double(y) >= ridge(x) - 30
        }
        return false
    }

    private func isGround(_ x: Int, _ y: Int) -> Bool {
        Double(y) >= ridge(x) || isTree(x, y)
    }

    private lazy var stars: [(x: Double, y: Double, brightness: Double)] = {
        var random = Random(state: 17)
        return (0..<500).map { _ in (random.next() * Double(width + 200) - 100, random.next() * Double(height + 200) - 100,
                                     4000 + random.next() * 26000) }
    }()

    private lazy var groundTexture: [Float] = {
        var random = Random(state: 23)
        let coarse = 6
        let cw = width / coarse + 2, ch = height / coarse + 2
        let grid = (0..<(cw * ch)).map { _ in Float(random.next()) }
        return (0..<(width * height)).map { i in
            let x = i % width, y = i / width
            let gx = Float(x) / Float(coarse), gy = Float(y) / Float(coarse)
            let x0 = Int(gx), y0 = Int(gy), fx = gx - Float(x0), fy = gy - Float(y0)
            let v = grid[y0 * cw + x0] * (1 - fx) * (1 - fy) + grid[y0 * cw + x0 + 1] * fx * (1 - fy)
                + grid[(y0 + 1) * cw + x0] * (1 - fx) * fy + grid[(y0 + 1) * cw + x0 + 1] * fx * fy
            // 大きな明暗に、岩肌のような細かい凹凸（1〜2pxの粒）を重ねる
            let grain = Float((x * 7919 + y * 104729) % 97) / 97
            return 600 + 3000 * v + 1200 * grain
        }
    }()

    /// 星を starShift、地上を groundShift だけずらした画像（RGB16と輝度）。noise=false なら理想的な画像
    private func render(starShift: (Double, Double), groundShift: (Int, Int), seed: UInt64, noise: Bool = true)
        -> (rgb: Data, gray: Data) {
        var random = Random(state: seed)
        var image = [Float](repeating: skyLevel, count: width * height)
        if noise { for i in image.indices { image[i] += Float((random.next() - 0.5) * 200) } }
        for star in stars {
            let cx = star.x + starShift.0, cy = star.y + starShift.1
            let top = max(0, Int(cy) - 4), bottom = min(height - 1, Int(cy) + 4)
            let left = max(0, Int(cx) - 4), right = min(width - 1, Int(cx) + 4)
            guard top <= bottom, left <= right else { continue }
            for y in top...bottom {
                for x in left...right {
                    let d2 = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)
                    image[y * width + x] += Float(star.brightness * exp(-d2 / (2 * 1.2 * 1.2)))
                }
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let sx = x - groundShift.0, sy = y - groundShift.1
                guard (0..<width).contains(sx), (0..<height).contains(sy), isGround(sx, sy) else { continue }
                image[y * width + x] = groundTexture[sy * width + sx] + (noise ? Float((random.next() - 0.5) * 200) : 0)
            }
        }
        var rgb = [UInt16](repeating: 0, count: width * height * 3)
        for i in image.indices {
            // 空はやや青く、地上はやや暖色（実際の星景と同じく色でも見分けがつく）。緑は輝度そのもの
            let x = i % width, y = i / width
            let sx = x - groundShift.0, sy = y - groundShift.1
            let ground = (0..<width).contains(sx) && (0..<height).contains(sy) && isGround(sx, sy)
            let (r, b): (Float, Float) = ground ? (1.15, 0.8) : (0.85, 1.2)
            rgb[i * 3] = UInt16(max(0, min(65535, image[i] * r)))
            rgb[i * 3 + 1] = UInt16(max(0, min(65535, image[i])))
            rgb[i * 3 + 2] = UInt16(max(0, min(65535, image[i] * b)))
        }
        // 輝度はアプリと同じく R・G・B の平均にする（外れ値の判定は RGB から求めた輝度と比べるため）
        let gray = (0..<(width * height)).map { i in
            (Float(rgb[i * 3]) + Float(rgb[i * 3 + 1]) + Float(rgb[i * 3 + 2])) / 3
        }
        return (rgb.withUnsafeBufferPointer { Data(buffer: $0) }, gray.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private func translation(_ dx: Double, _ dy: Double) -> [NSNumber] {
        [1, 0, NSNumber(value: dx), 0, 1, NSNumber(value: dy), 0, 0, 1]
    }

    private func truthAlpha() -> Data {
        let alpha = (0..<(width * height)).map { i -> Float in isGround(i % width, i / width) ? 0 : 1 }
        return alpha.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func pixels(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: UInt16.self)
            return (0..<(width * height)).map { Float(values[$0 * 3 + 1]) }
        }
    }

    /// 稜線のすぐ上（1〜10px、木を除く）の平均と、理想的な基準画像の同じ場所の平均の差
    private func bandAboveRidgeError(_ output: [Float], _ ideal: [Float]) -> Float {
        var sum: Float = 0, count = 0
        for x in 0..<width where !(0..<width).contains(where: { abs($0 - x) < 4 && isTree($0, Int(ridge($0)) - 5) }) {
            for d in 1...10 {
                let y = Int(ridge(x)) - d
                guard y >= 0, !isGround(x, y) else { continue }
                sum += output[y * width + x] - ideal[y * width + x]
                count += 1
            }
        }
        return sum / Float(max(1, count))
    }

    /// 稜線のすぐ下（2〜8px）の、理想的な画像との差の二乗平均
    private func groundBelowRidgeError(_ output: [Float], _ ideal: [Float]) -> Float {
        var sum: Float = 0, count = 0
        for x in 0..<width {
            for d in 2...8 {
                let y = Int(ridge(x).rounded(.up)) + d
                guard y < height else { continue }
                sum += pow(output[y * width + x] - ideal[y * width + x], 2)
                count += 1
            }
        }
        return sqrt(sum / Float(max(1, count)))
    }

    /// 高い空（稜線より40px以上上）の、理想的な画像との差の二乗平均（星がにじむと大きくなる）
    private func skyError(_ output: [Float], _ ideal: [Float]) -> Float {
        var sum: Float = 0, count = 0
        for y in 0..<height {
            for x in 0..<width where Double(y) < ridge(x) - 40 {
                sum += pow(output[y * width + x] - ideal[y * width + x], 2)
                count += 1
            }
        }
        return sqrt(sum / Float(max(1, count)))
    }

    /// 星が毎フレーム starStep、地上が毎フレーム groundStep 動く連続写真を合成する（基準はフレーム0）
    private func compose(starStep: (Double, Double), groundStep: (Int, Int), mask: NightscapeMask) throws -> [Float] {
        var frames: [(image: (rgb: Data, gray: Data), star: [NSNumber], ground: [NSNumber])] = []
        for i in 0..<frameCount {
            let t = Double(i)
            let image = render(starShift: (starStep.0 * t, starStep.1 * t),
                               groundShift: (groundStep.0 * i, groundStep.1 * i), seed: UInt64(100 + i))
            let star = translation(-starStep.0 * t, -starStep.1 * t)
            let ground = translation(Double(-groundStep.0 * i), Double(-groundStep.1 * i))
            frames.append((image, star, ground))
        }
        // 画素ごとの中央値（外れ値を除く基準）のために輝度を記録してから合成する
        let samples = NightscapeSamples(width: width, height: height)
        for frame in frames {
            try samples.addFrameGray(frame.image.gray, starHomography: frame.star, groundHomography: frame.ground)
        }
        let accumulator = NightscapeAccumulator(mask: mask, samples: samples)
        for frame in frames {
            try accumulator.addFrameRGB(frame.image.rgb, starHomography: frame.star, groundHomography: frame.ground)
        }
        return pixels(try accumulator.compose())
    }

    private func check(starStep: (Double, Double), groundStep: (Int, Int), label: String) throws {
        let mask = NightscapeMask(skyAlpha: truthAlpha(), width: width, height: height)
        let output = try compose(starStep: starStep, groundStep: groundStep, mask: mask)
        let ideal = pixels(render(starShift: (0, 0), groundShift: (0, 0), seed: 1, noise: false).rgb)
        let single = pixels(render(starShift: (0, 0), groundShift: (0, 0), seed: 100).rgb)

        let band = bandAboveRidgeError(output, ideal)
        XCTAssertLessThan(abs(band), 60, "\(label): 稜線のすぐ上に暗い帯・明るい帯が出ないこと（差 \(band)）")
        XCTAssertLessThan(groundBelowRidgeError(output, ideal), groundBelowRidgeError(single, ideal),
                          "\(label): 稜線の下は1枚より滑らかで、にじまないこと")
        XCTAssertLessThan(skyError(output, ideal), skyError(single, ideal),
                          "\(label): 星は1枚よりノイズが少なく、にじまないこと")
    }

    func testStarsRisingOverFixedGround() throws {
        // 東向き相当: 星が上へ動く
        try check(starStep: (2, -3), groundStep: (0, 0), label: "星が上へ動く")
    }

    func testStarsSettingBehindFixedGround() throws {
        // 西向き相当: 星が下へ動いて稜線の向こうに沈む
        try check(starStep: (2, 3), groundStep: (0, 0), label: "星が下へ動く")
    }

    func testTrackedStarsWithMovingGround() throws {
        // 追尾撮影: 星は止まり、地上が動く
        try check(starStep: (0, 0), groundStep: (-2, 2), label: "追尾撮影")
    }

    func testSmallRelativeShiftLeavesNoStarGhostsNearTheHorizon() throws {
        // 星と地上の動きの差が小さい（8枚で合計3.5px）と、地上に合わせた星のない空にも星が短い線として残る。
        // それを地平線付近に比較明で重ねても、星の横に伸びた像・二重の像が出ないこと
        let starStep = (0.5, 0.0)
        let mask = NightscapeMask(skyAlpha: truthAlpha(), width: width, height: height)
        let output = try compose(starStep: starStep, groundStep: (0, 0), mask: mask)
        let ideal = pixels(render(starShift: (0, 0), groundShift: (0, 0), seed: 1, noise: false).rgb)
        var ghostPixels = 0, count = 0
        for x in 0..<width where !(0..<width).contains(where: { abs($0 - x) < 4 && isTree($0, Int(ridge($0)) - 5) }) {
            for d in 3...60 {
                let y = Int(ridge(x)) - d
                guard y >= 0, !isGround(x, y) else { continue }
                count += 1
                if output[y * width + x] - ideal[y * width + x] > 500 { ghostPixels += 1 }
            }
        }
        XCTAssertLessThan(Double(ghostPixels) / Double(max(1, count)), 0.002,
                          "地平線付近の空に星の横に伸びた像が出ないこと（\(ghostPixels)/\(count) 画素）")
    }

    /// 海の星景: 水平線（y=200）の下はなだらかな海（模様が無く星も写らない）、上は地平線付近ほど明るい光害と星。
    /// 左右に岩肌の崖がある。海と光害は地上に対して動かず、星だけが動く（固定撮影）
    private func renderSeascape(starShift: (Double, Double), seed: UInt64) -> (rgb: Data, gray: Data) {
        var random = Random(state: seed)
        let horizon = 200
        func isCliff(_ x: Int, _ y: Int) -> Bool { (x < 70 && y >= 40 + x) || (x >= 420 && y >= 150 - (x - 420)) }
        var image = [Float](repeating: 0, count: width * height)
        var kind = [UInt8](repeating: 0, count: width * height)  // 0=空 1=海 2=崖
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if isCliff(x, y) {
                    image[i] = groundTexture[i]; kind[i] = 2
                } else if y >= horizon {
                    image[i] = 1300; kind[i] = 1
                } else {
                    // 地平線に近いほど明るい光害（地上に対して動かない）
                    image[i] = skyLevel + 4000 * Float(exp(-Double(horizon - y) / 25))
                }
                image[i] += Float((random.next() - 0.5) * 200)
            }
        }
        for star in stars {
            let cx = star.x + starShift.0, cy = star.y + starShift.1
            let top = max(0, Int(cy) - 4), bottom = min(height - 1, Int(cy) + 4)
            let left = max(0, Int(cx) - 4), right = min(width - 1, Int(cx) + 4)
            guard top <= bottom, left <= right else { continue }
            for y in top...bottom {
                for x in left...right where kind[y * width + x] == 0 {
                    let d2 = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)
                    image[y * width + x] += Float(star.brightness * exp(-d2 / (2 * 1.2 * 1.2)))
                }
            }
        }
        var rgb = [UInt16](repeating: 0, count: width * height * 3)
        for i in image.indices {
            // 空は青み、海は空より暗く色が浅い、崖は暖色
            let (r, b): (Float, Float) = kind[i] == 2 ? (1.15, 0.8) : (kind[i] == 1 ? (0.95, 1.05) : (0.85, 1.2))
            rgb[i * 3] = UInt16(max(0, min(65535, image[i] * r)))
            rgb[i * 3 + 1] = UInt16(max(0, min(65535, image[i])))
            rgb[i * 3 + 2] = UInt16(max(0, min(65535, image[i] * b)))
        }
        let gray = (0..<(width * height)).map { i in
            (Float(rgb[i * 3]) + Float(rgb[i * 3 + 1]) + Float(rgb[i * 3 + 2])) / 3
        }
        return (rgb.withUnsafeBufferPointer { Data(buffer: $0) }, gray.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    func testSmoothSeaIsGroundAndHorizonGlowIsSky() throws {
        // 地平線付近の光害は地上に対して動かないため、明るさのばらつきだけで判定すると地上と取り違え、
        // 光害の中の星が消える。模様の無い海は手がかりが無く、空と同じ扱いになると水平線がぼける
        let analyzer = NightscapeAnalyzer(width: width, height: height)
        let starStep = (2.5, -1.0)
        for i in 0..<frameCount {
            let frame = renderSeascape(starShift: (starStep.0 * Double(i), starStep.1 * Double(i)), seed: UInt64(300 + i))
            try analyzer.addFrameGray(frame.gray, rgb: frame.rgb,
                                      starHomography: translation(-starStep.0 * Double(i), -starStep.1 * Double(i)),
                                      groundHomography: translation(0, 0))
        }
        let mask = try analyzer.segment(withHints: nil)
        XCTAssertTrue(mask.hasBothRegions)
        let alpha: [Float] = mask.skyAlpha.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var seaAsGround = 0, seaCount = 0, glowAsSky = 0, glowCount = 0
        for y in 0..<height {
            for x in 100..<380 {
                if y >= 210 && y < 300 {
                    seaCount += 1
                    if alpha[y * width + x] < 0.5 { seaAsGround += 1 }
                } else if y >= 165 && y < 195 {
                    glowCount += 1
                    if alpha[y * width + x] >= 0.5 { glowAsSky += 1 }
                }
            }
        }
        XCTAssertGreaterThan(Double(seaAsGround) / Double(seaCount), 0.9, "水平線の下の海は地上")
        XCTAssertGreaterThan(Double(glowAsSky) / Double(glowCount), 0.9, "水平線の上の光害（星が写る）は空")
    }

    func testFeatheringSoftensOnlyTheBlendRatio() throws {
        // 左半分が地上、右半分が空。10px ぼかすと境界がなだらかになるが、空・地上を合成する範囲は変わらない
        let alpha = (0..<(width * height)).map { i -> Float in i % width < 240 ? 0 : 1 }
        let mask = NightscapeMask(skyAlpha: alpha.withUnsafeBufferPointer { Data(buffer: $0) }, width: width, height: height)
        let feathered = mask.feathered(radius: 10)
        let soft: [Float] = feathered.skyAlpha.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let row = 160 * width
        XCTAssertEqual(soft[row + 240], 0.52, accuracy: 0.06, "境界はほぼ半分")
        XCTAssertEqual(soft[row + 250], 0.84, accuracy: 0.06, "標準偏差（10px）離れると約84%")
        XCTAssertEqual(soft[row + 200], 0, accuracy: 0.01)
        XCTAssertEqual(feathered.certainSky, mask.certainSky)
        XCTAssertEqual(feathered.certainGround, mask.certainGround)
        XCTAssertTrue(mask.feathered(radius: 0) === mask)
        // 大きな半径（縮小してぼかす）でも同じ形になる
        let wide: [Float] = mask.feathered(radius: 30).skyAlpha.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(wide[row + 270], 0.84, accuracy: 0.06)
    }

    func testAutomaticSegmentationMatchesTheScene() throws {
        let analyzer = NightscapeAnalyzer(width: width, height: height)
        let starStep = (2.0, 3.0)
        for i in 0..<frameCount {
            let frame = render(starShift: (starStep.0 * Double(i), starStep.1 * Double(i)), groundShift: (0, 0),
                               seed: UInt64(100 + i))
            try analyzer.addFrameGray(frame.gray, rgb: frame.rgb,
                                      starHomography: translation(-starStep.0 * Double(i), -starStep.1 * Double(i)),
                                      groundHomography: translation(0, 0))
        }
        let mask = try analyzer.segment(withHints: nil)
        XCTAssertTrue(mask.hasBothRegions)
        let alpha: [Float] = mask.skyAlpha.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var intersection = 0, union = 0
        for i in alpha.indices {
            let predicted = alpha[i] >= 0.5, truth = !isGround(i % width, i / width)
            if predicted && truth { intersection += 1 }
            if predicted || truth { union += 1 }
        }
        let iou = Double(intersection) / Double(max(1, union))
        XCTAssertGreaterThan(iou, 0.95, "自動判定の空の範囲が正解とほぼ一致すること（IoU \(iou)）")

        // 自動判定のマスクで合成しても、稜線のすぐ上に帯が出ない
        let output = try compose(starStep: starStep, groundStep: (0, 0), mask: mask)
        let ideal = pixels(render(starShift: (0, 0), groundShift: (0, 0), seed: 1, noise: false).rgb)
        XCTAssertLessThan(abs(bandAboveRidgeError(output, ideal)), 60, "自動判定でも稜線の上に帯・稜線の影が出ないこと")
    }
}
