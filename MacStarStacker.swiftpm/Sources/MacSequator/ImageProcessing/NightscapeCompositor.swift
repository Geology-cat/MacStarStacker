import Foundation
import AppKit
import OpenCVWrapper

/// 新星景モード: 空は星に、地上は地上に合わせて合成し、自動で判定した空と地上の境界で重ね合わせる。
///
/// 1. 解析（`analyze`）: 各フレームで、星に合わせる変換（StarAligner）と地上に合わせる変換（GroundAligner）を求め、
///    空と地上の判定用の縮小画像と、外れ値を除く基準（画素ごとの中央値）用の輝度を集め、空と地上を自動で判定する
/// 2. 合成（`compose(analysis:)`）: 塗った手がかりで判定し直し、もう一度各フレームを読んで空と地上をそれぞれ合わせて合成する
///
/// 解析の結果は、ブラシで直してから合成し直すときに使い回せる（位置合わせと判定用のデータ集めをやり直さない）。
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

    /// 解析を途中で取りやめた（入力が変わった・合成を始めた）
    struct Cancelled: Error {}

    /// 解析の結果（位置合わせ・判定用のデータ・自動判定）。合成のたびに使い回す
    final class Analysis {
        let frameCount: Int
        let baseIndex: Int
        let width: Int
        let height: Int
        let starHomographies: [[NSNumber]]
        let groundHomographies: [[NSNumber]]
        let groundFallbackCount: Int
        /// 分けて合成する必要が無い・できない理由（nil なら分けて合成できる）
        let notNeededReason: String?
        /// 解析したときの自動判定（空の割合、判定結果の表示用）。分けて合成しない場合は nil
        let detectedSkyAlpha: [Float]?
        fileprivate let analyzer: NightscapeAnalyzer?
        fileprivate let samples: NightscapeSamples?
        /// メモリに余裕があるときに保持する現像済みのフレーム（合成で読み直さない）。基準フレームは常に保持する
        fileprivate private(set) var frames: [Int: [UInt16]]

        /// 保持している現像済みのフレームを手放す（基準フレームだけ残す）。
        /// ブラシで直している間など、解析を持ち続けるときのメモリを減らす
        func releaseFrames() {
            frames = frames.filter { $0.key == baseIndex }
        }

        fileprivate init(frameCount: Int, baseIndex: Int, width: Int, height: Int, starHomographies: [[NSNumber]],
                         groundHomographies: [[NSNumber]], groundFallbackCount: Int, notNeededReason: String?,
                         detectedSkyAlpha: [Float]?, analyzer: NightscapeAnalyzer?, samples: NightscapeSamples?,
                         frames: [Int: [UInt16]]) {
            self.frameCount = frameCount
            self.baseIndex = baseIndex
            self.width = width
            self.height = height
            self.starHomographies = starHomographies
            self.groundHomographies = groundHomographies
            self.groundFallbackCount = groundFallbackCount
            self.notNeededReason = notNeededReason
            self.detectedSkyAlpha = detectedSkyAlpha
            self.analyzer = analyzer
            self.samples = samples
            self.frames = frames
        }

        /// 基準画像から外側へ順に処理する順番（隣のフレームの結果を初期値にする）
        fileprivate var order: [Int] {
            [baseIndex] + Array((baseIndex + 1)..<frameCount) + Array((0..<baseIndex).reversed())
        }
    }

    /// 星と地上の動きの差がこれ未満（px）なら、分けて合成する必要が無い
    static let minimumRelativeShift = 2.0

    /// 解析と合成を続けて行う
    static func compose(
        frameCount: Int,
        baseIndex: Int,
        width: Int,
        height: Int,
        hints: Data?,
        featherRadius: Double = 0,
        cacheFrames: Bool = false,
        loadFrame: (Int) throws -> [UInt16],
        progress: (Double, String) -> Void
    ) throws -> Outcome {
        let analysis = try analyze(frameCount: frameCount, baseIndex: baseIndex, width: width, height: height,
                                   hints: nil, cacheFrames: cacheFrames, loadFrame: loadFrame,
                                   progress: { fraction, status in progress(fraction * 0.5, status) })
        return try compose(analysis: analysis, hints: hints, featherRadius: featherRadius, loadFrame: loadFrame,
                           progress: { fraction, status in progress(0.5 + fraction * 0.5, status) })
    }

    /// 解析: 全フレームを星と地上にそれぞれ位置合わせし、空と地上を自動で判定する（hints は利用者のブラシの手がかり）
    static func analyze(
        frameCount: Int,
        baseIndex: Int,
        width: Int,
        height: Int,
        hints: Data?,
        cacheFrames: Bool = false,
        isCancelled: () -> Bool = { false },
        loadFrame: (Int) throws -> [UInt16],
        progress: (Double, String) -> Void
    ) throws -> Analysis {
        let identity: [NSNumber] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        progress(0.02, "新星景モード: 基準画像を解析中...")
        let base = try loadFrame(baseIndex)
        guard frameCount >= 2 else {
            return Analysis(frameCount: frameCount, baseIndex: baseIndex, width: width, height: height,
                            starHomographies: [identity], groundHomographies: [identity], groundFallbackCount: 0,
                            notNeededReason: "フレームが1枚のため、空と地上を分けずに合成しました", detectedSkyAlpha: nil,
                            analyzer: nil, samples: nil, frames: [baseIndex: base])
        }
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
        var frames: [Int: [UInt16]] = [baseIndex: base]
        let order = [baseIndex] + Array((baseIndex + 1)..<frameCount) + Array((0..<baseIndex).reversed())
        for (step, index) in order.enumerated() {
            if isCancelled() { throw Cancelled() }
            progress(0.02 + 0.88 * Double(step) / Double(frameCount),
                     "新星景モード: 星と地上の位置合わせ・判定用の解析中 (\(step + 1)/\(frameCount))...")
            let rgb = index == baseIndex ? base : try loadFrame(index)
            if cacheFrames && index != baseIndex { frames[index] = rgb }
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

        var reason: String?
        var detectedSkyAlpha: [Float]?
        if analyzer.maximumRelativeShift < minimumRelativeShift {
            reason = "星と地上の動きの差が小さいため（最大\(String(format: "%.1f", analyzer.maximumRelativeShift))px）、空と地上を分けずに合成しました"
        } else {
            progress(0.92, "新星景モード: 空と地上を判定中...")
            let detected = try analyzer.segment(withHints: hints)
            if detected.hasBothRegions {
                detectedSkyAlpha = detected.skyAlpha.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else {
                reason = "空と地上をはっきり見分けられなかったため、空と地上を分けずに合成しました"
            }
        }
        return Analysis(frameCount: frameCount, baseIndex: baseIndex, width: width, height: height,
                        starHomographies: starH, groundHomographies: groundH, groundFallbackCount: groundFallbackCount,
                        notNeededReason: reason, detectedSkyAlpha: detectedSkyAlpha, analyzer: analyzer, samples: samples,
                        frames: frames)
    }

    /// 合成: 解析の結果を使い、塗った手がかりで空と地上を判定し直して合成する
    static func compose(
        analysis: Analysis,
        hints: Data?,
        featherRadius: Double = 0,
        loadFrame: (Int) throws -> [UInt16],
        progress: (Double, String) -> Void
    ) throws -> Outcome {
        if let reason = analysis.notNeededReason { return .notNeeded(reason) }
        guard let analyzer = analysis.analyzer, let samples = analysis.samples else {
            return .notNeeded("空と地上を分けずに合成しました")
        }
        progress(0.02, "新星景モード: 空と地上を判定中...")
        let detected = try analyzer.segment(withHints: hints)
        guard detected.hasBothRegions else {
            return .notNeeded("空と地上をはっきり見分けられなかったため、空と地上を分けずに合成しました")
        }
        // 境界ぼかし（px）を指定したときは、自動で決めた境界をさらにぼかして重ね合わせる
        let mask = featherRadius > 0 ? detected.feathered(radius: featherRadius) : detected

        let accumulator = NightscapeAccumulator(mask: mask, samples: samples)
        let count = analysis.frameCount
        for (step, index) in analysis.order.enumerated() {
            progress(0.1 + 0.8 * Double(step) / Double(count), "新星景モード: 空と地上を合成中 (\(step + 1)/\(count))...")
            let rgb = try analysis.frames[index] ?? loadFrame(index)
            try accumulator.addFrameRGB(rgb.withUnsafeBufferPointer { Data(buffer: $0) },
                                        starHomography: analysis.starHomographies[index],
                                        groundHomography: analysis.groundHomographies[index])
        }
        progress(0.92, "新星景モード: 仕上げ中...")
        // 解析は合成し直すときのために持ち続けるので、保持していたフレームは手放す
        analysis.releaseFrames()
        let output = try accumulator.compose()
        let pixels: [UInt16] = output.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        let skyAlpha: [Float] = mask.skyAlpha.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return .composited(Result(pixels: pixels, skyAlpha: skyAlpha, groundFallbackCount: analysis.groundFallbackCount))
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

    /// 自動判定の結果をマスクに塗るときの不透明度。ブラシ（255）と見た目は同じで、ブラシで塗り直した所と区別できる
    static let detectedOverlayAlpha: UInt8 = 250

    /// 塗った空・地上のマスク（空=青、地上=緑、基準画像と同じ大きさのRGBA 8bit、アルファ乗算済み）を手がかりにする。
    /// ブラシで塗った所（不透明）は 1=空・2=地上、前回の自動判定の結果（detectedOverlayAlpha）は 3=空・4=地上、
    /// 塗っていない所は 0。半透明に塗った所も、色の差を不透明度に比べて判断する
    static func hints(fromRGBA pixels: [UInt8], count: Int) -> Data? {
        var hints = [UInt8](repeating: 0, count: count)
        var painted = false
        let userAlpha = Int(detectedOverlayAlpha) + 3
        for i in 0..<count {
            let green = Int(pixels[i * 4 + 1]), blue = Int(pixels[i * 4 + 2]), alpha = Int(pixels[i * 4 + 3])
            guard alpha >= 32 else { continue }
            let margin = alpha / 4
            let byUser = alpha >= userAlpha
            if blue > green + margin { hints[i] = byUser ? 1 : 3; painted = true }
            else if green > blue + margin { hints[i] = byUser ? 2 : 4; painted = true }
        }
        return painted ? Data(hints) : nil
    }

    /// マスクのうち、ブラシで塗った所（不透明）だけを残す（前回の自動判定の結果は除く）。何も残らなければ nil
    static func userStrokesOnly(_ mask: NSImage?) -> NSImage? {
        guard let mask, let cg = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let userAlpha = UInt8(Int(detectedOverlayAlpha) + 3)
        var kept = false
        for i in 0..<(width * height) {
            if bytes[i * 4 + 3] >= userAlpha { kept = true } else { for c in 0..<4 { bytes[i * 4 + c] = 0 } }
        }
        guard kept, let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: image, size: mask.size)
    }

    /// 手がかりのうち、利用者のブラシ（1・2）だけを残す（前回の自動判定の結果 3・4 は除く）
    static func userHints(_ hints: Data) -> Data? {
        var painted = false
        let user = Data(hints.map { value -> UInt8 in
            guard value == 1 || value == 2 else { return 0 }
            painted = true
            return value
        })
        return painted ? user : nil
    }

    /// 自動判定の結果のマスク（overlay）に、これまでのマスクのブラシで塗った所（不透明）を重ねる。
    /// 判定し直してもブラシで直した所が消えないようにする
    static func mergingUserStrokes(from previous: NSImage?, onto overlay: NSImage) -> NSImage {
        guard let previous,
              let previousCG = previous.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let overlayCG = overlay.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return overlay }
        let width = overlayCG.width, height = overlayCG.height
        func render(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return drawn ? bytes : nil
        }
        guard var merged = render(overlayCG), let strokes = render(previousCG) else { return overlay }
        let userAlpha = UInt8(Int(detectedOverlayAlpha) + 3)
        var changed = false
        for i in 0..<(width * height) where strokes[i * 4 + 3] >= userAlpha {
            for c in 0..<4 { merged[i * 4 + c] = strokes[i * 4 + c] }
            changed = true
        }
        guard changed, let provider = CGDataProvider(data: Data(merged) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return overlay }
        return NSImage(cgImage: image, size: overlay.size)
    }

    /// マスク画像を width x height のRGBA 8bit（アルファ乗算済み、上の行から）に描いて手がかりにする
    static func hints(from mask: NSImage, width: Int, height: Int) -> Data? {
        guard let cg = mask.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return hints(fromRGBA: pixels, count: width * height)
    }

    /// 自動判定の結果を、ブラシで直せるマスク画像（空=青、地上=緑。ブラシと同じ色・不透明度で塗り、
    /// 表示のときに半透明にする。上から塗り直しても色が変わらない）にする。
    /// 境界の近くは塗らずに残し、もう一度合成するときも境界は自動で決まるようにする。
    /// 塗った所は次の合成で手がかりとして優先される
    static func hintOverlay(skyAlpha: [Float], width: Int, height: Int, maxSide: Int = 1500) -> CGImage? {
        guard width > 0, height > 0, skyAlpha.count >= width * height else { return nil }
        let scale = min(1.0, Double(maxSide) / Double(max(width, height)))
        let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
        var sky = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let sy = min(height - 1, Int(Double(y) / scale))
            for x in 0..<w {
                let sx = min(width - 1, Int(Double(x) / scale))
                sky[y * w + x] = skyAlpha[sy * width + sx] >= 0.5
            }
        }
        // 反対側までの距離（市街地距離、2回の走査）。境界から band 以内は塗らない
        let band = max(2, Int((Double(max(w, h)) * 0.004).rounded()))
        let far = Int32(w + h)
        var distance = [Int32](repeating: far, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if (x > 0 && sky[i - 1] != sky[i]) || (y > 0 && sky[i - w] != sky[i]) { distance[i] = 0; continue }
                if x > 0 { distance[i] = min(distance[i], distance[i - 1] + 1) }
                if y > 0 { distance[i] = min(distance[i], distance[i - w] + 1) }
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                if (x < w - 1 && sky[i + 1] != sky[i]) || (y < h - 1 && sky[i + w] != sky[i]) { distance[i] = 0; continue }
                if x < w - 1 { distance[i] = min(distance[i], distance[i + 1] + 1) }
                if y < h - 1 { distance[i] = min(distance[i], distance[i + w] + 1) }
            }
        }
        // ブラシと同じ色（空: 0,0.2,1 / 地上: 0,1,0）を、見た目は同じでブラシと区別できる不透明度で塗る
        let alpha = Float(detectedOverlayAlpha) / 255
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where distance[i] > band {
            let color: (Float, Float, Float) = sky[i] ? (0, 0.2, 1) : (0, 1, 0)
            rgba[i * 4] = UInt8(color.0 * alpha * 255)
            rgba[i * 4 + 1] = UInt8(color.1 * alpha * 255)
            rgba[i * 4 + 2] = UInt8(color.2 * alpha * 255)
            rgba[i * 4 + 3] = UInt8(alpha * 255)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - 現像済み画像（NSImage）との変換

    /// 16bit RGB の画素（R・G・Bの順、上の行から）と、その色空間
    struct RGB16Image {
        let pixels: [UInt16]
        let width: Int
        let height: Int
        let colorSpace: CGColorSpace
    }

    static func rgb16(from image: NSImage) -> RGB16Image? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        let colorSpace = (cg.colorSpace?.model == .rgb ? cg.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt16](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var pixels = [UInt16](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            pixels[i * 3] = rgba[i * 4]
            pixels[i * 3 + 1] = rgba[i * 4 + 1]
            pixels[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return RGB16Image(pixels: pixels, width: width, height: height, colorSpace: colorSpace)
    }

    static func image(from rgb: RGB16Image) -> NSImage? {
        let data = rgb.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: rgb.width, height: rgb.height, bitsPerComponent: 16, bitsPerPixel: 48,
                               bytesPerRow: rgb.width * 6, space: rgb.colorSpace,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: rgb.width, height: rgb.height))
    }
}
