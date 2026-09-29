import AppKit
import CoreGraphics

/// 画像の明るさの分布から、表示用に暗部を持ち上げる（PixInsight の Screen Transfer Function と同じ考え方）。
///
/// 背景（中央値）がノイズの幅を残して黒になる位置を黒レベルにし、背景が目標の明るさになるように
/// 中間調だけを持ち上げる。ハイライトは飛ばさず、色合いを変えないよう R・G・B に同じ補正をかける。
/// すでに十分明るい画像は持ち上げない。
enum AutoStretch {
    struct Parameters: Equatable {
        /// この値以下を黒にする（0〜1）
        let shadows: Double
        /// 中間調のバランス（0〜0.5。小さいほど暗部を持ち上げる。0.5 で変化なし）
        let midtones: Double

        static let identity = Parameters(shadows: 0, midtones: 0.5)
    }

    /// 持ち上げた後の背景の明るさ（0〜1）
    static let targetBackground = 0.2
    /// 持ち上げの上限（中間調のバランスの下限）。ほぼ真っ黒な画像でノイズや色かぶりを強調しすぎない
    static let minimumMidtones = 0.05
    /// 黒レベルを背景の中央値からノイズ幅（MADの正規化値）の何倍下に置くか
    static let shadowsClipping = 2.8

    /// 画像の明るさの分布から補正量を決める
    static func parameters(for image: CGImage) -> Parameters {
        let samples = luminanceSamples(of: image)
        guard !samples.isEmpty else { return .identity }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        // 背景がすでに目標より明るい画像（薄明・昼間・月夜など）は何もしない
        guard median < targetBackground else { return .identity }
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = 1.4826 * deviations[deviations.count / 2]
        let shadows = max(0, min(median, median - shadowsClipping * mad))
        let normalizedMedian = (median - shadows) / max(1e-6, 1 - shadows)
        guard normalizedMedian > 0, normalizedMedian < targetBackground else {
            // 真っ黒な画像などは中間調を変えない
            return Parameters(shadows: shadows, midtones: 0.5)
        }
        let midtones = midtonesBalance(mapping: normalizedMedian, to: targetBackground)
        return Parameters(shadows: shadows, midtones: max(minimumMidtones, midtones))
    }

    /// 中間調変換関数（MTF）。x=0→0、x=1→1、x=m→0.5 となる曲線
    static func midtonesTransfer(_ x: Double, balance m: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        return (m - 1) * x / ((2 * m - 1) * x - m)
    }

    /// x を y に写す中間調のバランス
    static func midtonesBalance(mapping x: Double, to y: Double) -> Double {
        x * (y - 1) / (2 * x * y - y - x)
    }

    /// 補正を適用した 16bit の画像を返す
    static func apply(_ parameters: Parameters, to image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 16bit の値ごとの変換表
        var table = [UInt16](repeating: 0, count: 65536)
        let range = max(1e-6, 1 - parameters.shadows)
        for value in 0..<65536 {
            let x = (Double(value) / 65535 - parameters.shadows) / range
            table[value] = UInt16((midtonesTransfer(x, balance: parameters.midtones) * 65535).rounded())
        }
        let rowLength = context.bytesPerRow / 2
        let pixels = data.bindMemory(to: UInt16.self, capacity: rowLength * height)
        table.withUnsafeBufferPointer { lut in
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let row = pixels + y * rowLength
                for x in 0..<width {
                    let i = x * 4
                    row[i] = lut[Int(row[i])]
                    row[i + 1] = lut[Int(row[i + 1])]
                    row[i + 2] = lut[Int(row[i + 2])]
                }
            }
        }
        return context.makeImage()
    }

    /// 画像から補正量を決めて適用する
    static func stretch(_ image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let stretched = apply(parameters(for: cgImage), to: cgImage) else { return nil }
        return NSImage(cgImage: stretched, size: image.size)
    }

    /// 縮小した画像の輝度（R・G・Bの平均、0〜1）
    private static func luminanceSamples(of image: CGImage) -> [Double] {
        let scale = min(1.0, 512.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
              let data = context.data else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rowLength = context.bytesPerRow / 2
        let pixels = data.bindMemory(to: UInt16.self, capacity: rowLength * height)
        var samples: [Double] = []
        samples.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * rowLength + x * 4
                samples.append((Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / (3 * 65535))
            }
        }
        return samples
    }
}
