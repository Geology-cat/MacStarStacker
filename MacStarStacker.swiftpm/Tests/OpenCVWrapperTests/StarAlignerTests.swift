import XCTest
@testable import OpenCVWrapper

/// 星だけで位置合わせできることのテスト。
/// 画像には星より特徴点の多い「岩肌」を入れ、地上に引きずられないこと（固定撮影・追尾撮影の両方）を確かめる。
final class StarAlignerTests: XCTestCase {
    private let width = 900
    private let height = 600

    /// 再現できる疑似乱数（線形合同法）
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private struct Scene {
        var stars: [(x: Double, y: Double, brightness: Double)] = []
        /// 地上の模様（左側の崖と下側の地面）。値は明るさ
        var ground: [Float] = []
        var groundMask: [Bool] = []
    }

    private func makeScene() -> Scene {
        var random = Random(state: 42)
        var scene = Scene()
        scene.ground = [Float](repeating: 0, count: width * height)
        scene.groundMask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // 左 30% の崖（上端まで）と、下 25% の地面
                let isGround = x < width * 3 / 10 || y > height * 3 / 4
                guard isGround else { continue }
                scene.groundMask[y * width + x] = true
                // 細かく強い模様（明るい点も多く含む）
                scene.ground[y * width + x] = Float(80 + random.next() * 120)
            }
        }
        // 岩肌の明るい斑点（星に似た点）を星より多く入れる
        for _ in 0..<600 {
            let x = Int(random.next() * Double(width)), y = Int(random.next() * Double(height))
            guard scene.groundMask[y * width + x] else { continue }
            for dy in -1...1 {
                for dx in -1...1 where (0..<width).contains(x + dx) && (0..<height).contains(y + dy) {
                    scene.ground[(y + dy) * width + x + dx] += 400
                }
            }
        }
        for _ in 0..<350 {
            scene.stars.append((x: random.next() * Double(width), y: random.next() * Double(height),
                                brightness: 300 * pow(10, random.next() * 1.3)))
        }
        return scene
    }

    /// 星を (starShift) だけ、地上を (groundShift) だけずらした画像を描く
    private func render(_ scene: Scene, starShift: (Double, Double), groundShift: (Int, Int), seed: UInt64) -> Data {
        var random = Random(state: seed)
        var image = [Float](repeating: 0, count: width * height)
        for i in 0..<image.count { image[i] = Float(100 + (random.next() - 0.5) * 10) }
        for star in scene.stars {
            let cx = star.x + starShift.0, cy = star.y + starShift.1
            let top = max(0, Int(cy) - 4), bottom = min(height - 1, Int(cy) + 4)
            let left = max(0, Int(cx) - 4), right = min(width - 1, Int(cx) + 4)
            guard top <= bottom, left <= right else { continue }  // 画像の外に出た星
            for y in top...bottom {
                for x in left...right {
                    let d2 = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)
                    image[y * width + x] += Float(star.brightness * exp(-d2 / (2 * 1.3 * 1.3)))
                }
            }
        }
        // 地上は星を隠す（手前にある）
        for y in 0..<height {
            for x in 0..<width {
                let sx = x - groundShift.0, sy = y - groundShift.1
                guard (0..<width).contains(sx), (0..<height).contains(sy), scene.groundMask[sy * width + sx] else { continue }
                image[y * width + x] = scene.ground[sy * width + sx]
            }
        }
        return image.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 変換で写した点の、期待する位置からのずれ
    private func error(_ h: [NSNumber], mapping point: (Double, Double), to expected: (Double, Double)) -> Double {
        let m = h.map(\.doubleValue)
        let w = m[6] * point.0 + m[7] * point.1 + m[8]
        let x = (m[0] * point.0 + m[1] * point.1 + m[2]) / w
        let y = (m[3] * point.0 + m[4] * point.1 + m[5]) / w
        return hypot(x - expected.0, y - expected.1)
    }

    func testFollowsStarsWhenGroundIsFixed() throws {
        // 固定撮影: 星が動き、地上は動かない
        let scene = makeScene()
        let base = render(scene, starShift: (0, 0), groundShift: (0, 0), seed: 1)
        let target = render(scene, starShift: (14.3, -6.6), groundShift: (0, 0), seed: 2)
        let aligner = try StarAligner(baseGray: base, width: width, height: height, skyMask: nil)
        let h = try aligner.homography(fromGray: target, initialGuess: nil)
        // 対象画像の星の位置 (x+14.3, y-6.6) は基準の (x, y) に写る
        for point in [(500.0, 100.0), (700.0, 300.0), (850.0, 50.0)] {
            XCTAssertLessThan(error(h, mapping: (point.0 + 14.3, point.1 - 6.6), to: point), 0.3,
                              "星の動きに合わせること（地上に合わせて恒等変換にならない）")
        }
    }

    func testFollowsStarsWhenGroundMoves() throws {
        // 追尾撮影: 星は動かず、地上が動く
        let scene = makeScene()
        let base = render(scene, starShift: (0, 0), groundShift: (0, 0), seed: 1)
        let target = render(scene, starShift: (0.4, 0.2), groundShift: (25, 11), seed: 3)
        let aligner = try StarAligner(baseGray: base, width: width, height: height, skyMask: nil)
        let h = try aligner.homography(fromGray: target, initialGuess: nil)
        for point in [(500.0, 100.0), (700.0, 300.0), (850.0, 50.0)] {
            XCTAssertLessThan(error(h, mapping: (point.0 + 0.4, point.1 + 0.2), to: point), 0.3,
                              "動いた地上ではなく、ほぼ動かない星に合わせること")
        }
    }

    func testUsesInitialGuessForLargeMotion() throws {
        // 基準から遠いフレーム（大きな動き）でも、隣のフレームの結果を初期値にして合わせられる
        let scene = makeScene()
        let base = render(scene, starShift: (0, 0), groundShift: (0, 0), seed: 1)
        let near = render(scene, starShift: (30, 12), groundShift: (0, 0), seed: 4)
        let far = render(scene, starShift: (36, 14), groundShift: (0, 0), seed: 5)
        let aligner = try StarAligner(baseGray: base, width: width, height: height, skyMask: nil)
        let guess = try aligner.homography(fromGray: near, initialGuess: nil)
        let h = try aligner.homography(fromGray: far, initialGuess: guess)
        XCTAssertLessThan(error(h, mapping: (636, 214), to: (600, 200)), 0.3)
    }

    func testReportsErrorWhenNoStars() {
        // 星の無い画像（曇天など）では、地上に合わせずにエラーにする
        var scene = makeScene()
        scene.stars = []
        let base = render(scene, starShift: (0, 0), groundShift: (0, 0), seed: 1)
        // 空・地上マスクで空だけを指定すると、岩肌の斑点を星と取り違えない
        let skyMask = Data(scene.groundMask.map { $0 ? 0 : 255 })
        XCTAssertThrowsError(try StarAligner(baseGray: base, width: width, height: height, skyMask: skyMask))
    }
}
