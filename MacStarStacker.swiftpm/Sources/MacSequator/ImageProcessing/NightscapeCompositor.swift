import Foundation
import OpenCVWrapper

/// 新星景モード: 空は星に、地上は地上に合わせて合成し、自動で判定した空と地上の境界で重ね合わせる。
///
/// 1. 各フレームで、星に合わせる変換（StarAligner）と地上に合わせる変換（GroundAligner）を求め、
///    空と地上の判定用の縮小画像と、外れ値を除く基準（画素ごとの中央値）用の輝度を集める
/// 2. 空と地上を自動で判定する（塗った手がかりがあれば優先する）
/// 3. もう一度各フレームを読み、空と地上をそれぞれ合わせて合成する
///
/// フレームは RAW でも現像済みの画像でもよく、`loadFrame` が基準画像と同じ向き・大きさの16bit RGBを返す。
enum NightscapeCompositor {
    struct Result {
        /// 合成結果（16bit RGB、width * height * 3）
        let pixels: [UInt16]
        /// 自動判定した空の割合（1=空。判定結果の表示用）
        let skyAlpha: [Float]
        /// 地上の位置合わせができず「動きなし」として扱ったフレームの数
        let groundFallbackCount: Int
    }

    enum Outcome {
        case composited(Result)
        /// 分けて合成する必要が無い・できない（理由）。呼び出し側は通常の合成を行う
        case notNeeded(String)
    }

    struct CompositorError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 星と地上の動きの差がこれ未満（px）なら、分けて合成する必要が無い
    static let minimumRelativeShift = 2.0

    static func compose(
        frameCount: Int,
        baseIndex: Int,
        width: Int,
        height: Int,
        hints: Data?,
        cacheFrames: Bool = false,
        loadFrame: (Int) throws -> [UInt16],
        progress: (Double, String) -> Void
    ) throws -> Outcome {
        guard frameCount >= 2 else { return .notNeeded("フレームが1枚のため、空と地上を分けずに合成しました") }
        let identity: [NSNumber] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

        // 1. 位置合わせと判定用のデータ集め（基準フレームから外側へ順に、隣のフレームの結果を初期値にする）
        progress(0.05, "新星景モード: 基準画像を解析中...")
        let base = try loadFrame(baseIndex)
        let baseGray = gray(of: base, count: width * height)
        let starAligner: StarAligner
        do {
            starAligner = try StarAligner(baseGray: baseGray, width: width, height: height, skyMask: nil)
        } catch {
            throw CompositorError(message: "星の位置合わせを準備できませんでした（\(error.localizedDescription)）")
        }
        // 地上に特徴の無い（真っ暗な）構図では地上の位置合わせができないため、固定撮影として扱う
        let groundAligner = try? GroundAligner(baseGray: baseGray, width: width, height: height)
        let analyzer = NightscapeAnalyzer(width: width, height: height)
        let samples = NightscapeSamples(width: width, height: height)

        var starH = [[NSNumber]](repeating: identity, count: frameCount)
        var groundH = [[NSNumber]](repeating: identity, count: frameCount)
        var groundFallbackCount = groundAligner == nil ? frameCount - 1 : 0
        // cacheFrames なら、合成のときに読み直さないよう読み込んだフレームを保持する
        var cache: [Int: [UInt16]] = [:]
        let order = [baseIndex] + Array((baseIndex + 1)..<frameCount) + Array((0..<baseIndex).reversed())
        for (step, index) in order.enumerated() {
            progress(0.05 + 0.4 * Double(step) / Double(frameCount),
                     "新星景モード: 星と地上の位置合わせ・判定用の解析中 (\(step + 1)/\(frameCount))...")
            let rgb = index == baseIndex ? base : try loadFrame(index)
            if cacheFrames && index != baseIndex { cache[index] = rgb }
            let frameGray = index == baseIndex ? baseGray : gray(of: rgb, count: width * height)
            if index != baseIndex {
                let neighbor = index > baseIndex ? index - 1 : index + 1
                do {
                    starH[index] = try starAligner.homography(fromGray: frameGray, initialGuess: starH[neighbor])
                } catch {
                    throw CompositorError(message: "星の位置合わせに失敗しました（フレーム\(index + 1)：\(error.localizedDescription)）")
                }
                if let groundAligner,
                   let h = try? groundAligner.homography(fromGray: frameGray, initialGuess: groundH[neighbor]) {
                    groundH[index] = h
                } else {
                    // 地上が合わせられないフレームは、隣のフレームと同じ動きとして扱う
                    groundH[index] = groundH[neighbor]
                    if groundAligner != nil { groundFallbackCount += 1 }
                }
            }
            let rgbData = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
            try analyzer.addFrameGray(frameGray, rgb: rgbData, starHomography: starH[index], groundHomography: groundH[index])
            try samples.addFrameGray(frameGray, starHomography: starH[index], groundHomography: groundH[index])
        }

        if analyzer.maximumRelativeShift < minimumRelativeShift {
            return .notNeeded("星と地上の動きの差が小さいため（最大\(String(format: "%.1f", analyzer.maximumRelativeShift))px）、空と地上を分けずに合成しました")
        }

        // 2. 空と地上の判定
        progress(0.47, "新星景モード: 空と地上を判定中...")
        let mask = try analyzer.segment(withHints: hints)
        guard mask.hasBothRegions else {
            return .notNeeded("空と地上をはっきり見分けられなかったため、空と地上を分けずに合成しました")
        }

        // 3. 合成（もう一度各フレームを読む）
        let accumulator = NightscapeAccumulator(mask: mask, samples: samples)
        for (step, index) in order.enumerated() {
            progress(0.5 + 0.4 * Double(step) / Double(frameCount), "新星景モード: 空と地上を合成中 (\(step + 1)/\(frameCount))...")
            let rgb = index == baseIndex ? base : try cache.removeValue(forKey: index) ?? loadFrame(index)
            try accumulator.addFrameRGB(rgb.withUnsafeBufferPointer { Data(buffer: $0) },
                                        starHomography: starH[index], groundHomography: groundH[index])
        }
        progress(0.9, "新星景モード: 仕上げ中...")
        let output = try accumulator.compose()
        let pixels: [UInt16] = output.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        let skyAlpha: [Float] = mask.skyAlpha.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return .composited(Result(pixels: pixels, skyAlpha: skyAlpha, groundFallbackCount: groundFallbackCount))
    }

    /// 16bit RGB の輝度（R・G・Bの平均、float32）
    static func gray(of rgb: [UInt16], count: Int) -> Data {
        var data = Data(count: count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: Float.self)
            rgb.withUnsafeBufferPointer { input in
                DispatchQueue.concurrentPerform(iterations: max(1, count / 65536 + 1)) { chunk in
                    let start = chunk * 65536, end = min(count, start + 65536)
                    guard start < end else { return }
                    for i in start..<end {
                        output[i] = (Float(input[i * 3]) + Float(input[i * 3 + 1]) + Float(input[i * 3 + 2])) / 3
                    }
                }
            }
        }
        return data
    }

    /// 塗った空・地上のマスク（空=青、地上=緑、基準画像と同じ大きさのRGBA 8bit）を手がかり（1=空、2=地上、0=自動）にする
    static func hints(fromRGBA pixels: [UInt8], count: Int) -> Data? {
        var hints = [UInt8](repeating: 0, count: count)
        var painted = false
        for i in 0..<count {
            let green = Int(pixels[i * 4 + 1]), blue = Int(pixels[i * 4 + 2])
            if blue > green + 64 { hints[i] = 1; painted = true }
            else if green > blue + 64 { hints[i] = 2; painted = true }
        }
        return painted ? Data(hints) : nil
    }
}
