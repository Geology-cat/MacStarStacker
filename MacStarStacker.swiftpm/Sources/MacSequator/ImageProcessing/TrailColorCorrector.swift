import Foundation

/// 比較明合成の細部（星などの光跡）の偽色を抑える。
///
/// 星の像は画素1〜2個分と小さく、ベイヤー配列の R・G・B のどの画素に乗るかで色が決まってしまう（偽色）。
/// 光跡は画素の並びに対してわずかに斜めに進むため、乗る画素の種類がゆっくり入れ替わり、
/// 光跡の色が緑・マゼンタなどに周期的に変わる（EOS 6D・11mm の実データでは数十〜百数十画素の周期）。
/// 1枚ずつのRAWの時点で起きていて、合成の方法では避けられない（位置合わせありのRGB経路でも、各フレームの補間で同じになる）。
///
/// そこで細部だけを次のように直す（背景＝空・雲・街明かりなど動かないものには手を加えない）。
/// 1. 細部の明るさから光跡の向きを求め（構造テンソル）、光跡に沿って前後 length 画素の範囲で色を平均する。
///    色の入れ替わりの周期より長く平均すると、本来の星の色に近づく
/// 2. ベイヤー配列では、細部の明るさを [1, 2, 1] / 4 のフィルタ（縦横）で広げて R・G・B のどの画素にも行き渡らせ、
///    平均した色で値を付け直す。広げないと、星の光が乗っていない色の画素は値が無いままで、どの現像ソフトで補間しても同じ偽色になる。
///    このフィルタは2画素周期の縞（R の行と B の行、G の市松などで値が交互に変わる成分＝現像ソフトが色と取り違える成分）を
///    ちょうど0にし、広がりは標準偏差0.71画素と小さい
enum TrailColorCorrector {
    struct Options {
        /// 偽色を抑える
        var enabled = true
        /// 光跡に沿って色を平均する範囲（片側、画素）
        var length: Float = 80
    }

    /// detail: 細部（背景に重ねる分、0以上）。grid の並び（ベイヤー配列なら元の並び、RGBなら画素ごとにR・G・B）。
    /// colors: ブロックの中の位置（plane）ごとの色（0=R, 1=G, 2=B）。whiteBalance: plane ごとのホワイトバランス係数。
    /// threshold: 光跡として扱う明るさの下限（ホワイトバランス後の値）
    static func correct(_ detail: inout [Float], grid g: BrightStacker.Grid, colors: [Int], whiteBalance: [Float],
                        threshold: Float, options: Options) {
        guard options.enabled, g.unitsWide > 4, g.unitsHigh > 4, colors.count == g.planes, whiteBalance.count == g.planes,
              threshold > 0, detail.count == g.sampleCount else { return }
        let units = g.unitCount
        let uw = g.unitsWide, uh = g.unitsHigh

        // 1. 単位ごとの色（ホワイトバランス後）と明るさ
        var colorCount = [Float](repeating: 0, count: 3)
        for c in colors { colorCount[c] += 1 }
        guard colorCount.allSatisfy({ $0 > 0 }) else { return }
        var channels = (0..<3).map { _ in [Float](repeating: 0, count: units) }
        for c in 0..<3 {
            channels[c].withUnsafeMutableBufferPointer { output in
                detail.withUnsafeBufferPointer { input in
                    DispatchQueue.concurrentPerform(iterations: uh) { uy in
                        for ux in 0..<uw {
                            var sum: Float = 0
                            for plane in 0..<g.planes where colors[plane] == c {
                                sum += input[g.index(ux, uy, plane)] * whiteBalance[plane]
                            }
                            output[uy * uw + ux] = sum / colorCount[c]
                        }
                    }
                }
            }
            channels[c] = BrightStacker.boxMean(channels[c], uw, uh, 1)
        }
        var luminance = [Float](repeating: 0, count: units)
        for u in 0..<units { luminance[u] = (channels[0][u] + channels[1][u] + channels[2][u]) / 3 }
        // 光跡が無ければ何もしない
        guard luminance.contains(where: { $0 >= threshold }) else { return }
        let channel = channels

        // 2. 光跡の向き（構造テンソルの、明るさの変化が小さい方向）と、線らしさ（0〜1）
        let (directionX, directionY, coherence) = orientation(luminance, uw, uh, radius: g.unitRadius(3))

        // 3. 光跡に沿って色を平均する（明るさで重み付け）
        let steps = max(1, Int((options.length / Float(g.unitSize)).rounded()))
        var chromaR = [Float](repeating: 1, count: units), chromaG = chromaR, chromaB = chromaR
        var weight = [Float](repeating: 0, count: units)
        var gate = [Float](repeating: 0, count: units)
        chromaR.withUnsafeMutableBufferPointer { c0 in
            chromaG.withUnsafeMutableBufferPointer { c1 in
                chromaB.withUnsafeMutableBufferPointer { c2 in
                    weight.withUnsafeMutableBufferPointer { weights in
                        gate.withUnsafeMutableBufferPointer { gates in
                            DispatchQueue.concurrentPerform(iterations: uh) { uy in
                                for ux in 0..<uw {
                                    let u = uy * uw + ux
                                    guard luminance[u] >= threshold else { continue }
                                    var sums: (Float, Float, Float) = (0, 0, 0)
                                    for sign: Float in [1, -1] {
                                        var px = Float(ux) + 0.5, py = Float(uy) + 0.5
                                        var dx = directionX[u] * sign, dy = directionY[u] * sign
                                        var dark = 0
                                        for step in 0...steps {
                                            let ix = Int(px), iy = Int(py)
                                            guard px >= 0, py >= 0, ix < uw, iy < uh else { break }
                                            let v = iy * uw + ix
                                            let w = luminance[v]
                                            // 出発点は片側だけで数える
                                            if step > 0 || sign > 0 {
                                                sums.0 += channel[0][v] * w
                                                sums.1 += channel[1][v] * w
                                                sums.2 += channel[2][v] * w
                                            }
                                            // 光跡から外れて暗い所が続いたらやめる（隣の光跡の色を混ぜない）
                                            dark = w < threshold * 0.25 ? dark + 1 : 0
                                            if dark >= 3 { break }
                                            // 向きを読み直す（曲がった光跡に沿う）。向きの符号は進んできた方にそろえる
                                            var nx = directionX[v], ny = directionY[v]
                                            if nx * dx + ny * dy < 0 { nx = -nx; ny = -ny }
                                            dx = nx; dy = ny
                                            px += dx; py += dy
                                            // 光跡の中心（明るさの尾根）へ寄せる。向きのわずかなずれで光跡から外れていかないようにする
                                            let here = sample(luminance, uw, uh, px, py)
                                            let left = sample(luminance, uw, uh, px - dy, py + dx)
                                            let right = sample(luminance, uw, uh, px + dy, py - dx)
                                            if left > here && left >= right {
                                                px -= dy * 0.5; py += dx * 0.5
                                            } else if right > here {
                                                px += dy * 0.5; py -= dx * 0.5
                                            }
                                        }
                                    }
                                    let mean = (sums.0 + sums.1 + sums.2) / 3
                                    guard mean > 0 else { continue }
                                    c0[u] = sums.0 / mean
                                    c1[u] = sums.1 / mean
                                    c2[u] = sums.2 / mean
                                    weights[u] = luminance[u]
                                    // 線らしくない所（点・交差）はそのままにする
                                    gates[u] = min(1, max(0, (coherence[u] - 0.3) / 0.3))
                                }
                            }
                        }
                    }
                }
            }
        }

        let chroma = [chromaR, chromaG, chromaB]

        // 4. 色と置き換える割合を、まわり（細部を広げる先）にも広げる
        let wide = 1
        let weightSum = BrightStacker.boxMean(weight, uw, uh, wide)
        var factors = (0..<3).map { c -> [Float] in
            var weighted = [Float](repeating: 0, count: units)
            for u in 0..<units { weighted[u] = chroma[c][u] * weight[u] }
            return BrightStacker.boxMean(weighted, uw, uh, wide)
        }
        var gatedWeight = [Float](repeating: 0, count: units)
        for u in 0..<units { gatedWeight[u] = gate[u] * weight[u] }
        let gateSum = BrightStacker.boxMean(gatedWeight, uw, uh, wide)
        let luminanceWide = BrightStacker.boxMean(luminance, uw, uh, wide)
        var alpha = [Float](repeating: 0, count: units)
        for u in 0..<units {
            let total = weightSum[u]
            guard total > 0 else {
                for c in 0..<3 { factors[c][u] = 1 }
                continue
            }
            for c in 0..<3 { factors[c][u] /= total }
            alpha[u] = min(1, max(0, (luminanceWide[u] - threshold) / threshold)) * (gateSum[u] / total)
        }

        // 5. 明るさを（ベイヤー配列では広げて）、平均した色で付け直す
        if g.isBayer {
            // 値ごとの明るさ（その色の比で割る）
            var light = [Float](repeating: 0, count: g.width * g.height)
            light.withUnsafeMutableBufferPointer { output in
                detail.withUnsafeBufferPointer { input in
                    DispatchQueue.concurrentPerform(iterations: uh) { uy in
                        for ux in 0..<uw {
                            let u = uy * uw + ux
                            for plane in 0..<g.planes {
                                let i = g.index(ux, uy, plane)
                                let k = factors[colors[plane]][u]
                                let value = input[i] * whiteBalance[plane]
                                output[i] = k > 0.05 ? value / k : value
                            }
                        }
                    }
                }
            }
            let spread = binomialBlur(light, g.width, g.height)
            detail.withUnsafeMutableBufferPointer { output in
                DispatchQueue.concurrentPerform(iterations: uh) { uy in
                    for ux in 0..<uw {
                        let u = uy * uw + ux
                        let a = alpha[u]
                        guard a > 0 else { continue }
                        for plane in 0..<g.planes {
                            let i = g.index(ux, uy, plane)
                            let corrected = spread[i] * factors[colors[plane]][u] / whiteBalance[plane]
                            output[i] = a * corrected + (1 - a) * output[i]
                        }
                    }
                }
            }
        } else {
            detail.withUnsafeMutableBufferPointer { output in
                DispatchQueue.concurrentPerform(iterations: uh) { uy in
                    for ux in 0..<uw {
                        let u = uy * uw + ux
                        let a = alpha[u]
                        guard a > 0 else { continue }
                        var light: Float = 0
                        for plane in 0..<g.planes { light += output[g.index(ux, uy, plane)] * whiteBalance[plane] }
                        light /= Float(g.planes)
                        for plane in 0..<g.planes {
                            let i = g.index(ux, uy, plane)
                            let corrected = light * factors[colors[plane]][u] / whiteBalance[plane]
                            output[i] = a * corrected + (1 - a) * output[i]
                        }
                    }
                }
            }
        }
    }

    /// (x, y) を含む単位の値（範囲外は0）
    @inline(__always)
    private static func sample(_ values: [Float], _ width: Int, _ height: Int, _ x: Float, _ y: Float) -> Float {
        guard x >= 0, y >= 0 else { return 0 }
        let ix = Int(x), iy = Int(y)
        guard ix < width, iy < height else { return 0 }
        return values[iy * width + ix]
    }

    /// 構造テンソルから、明るさの変化が小さい方向（光跡の向き、単位ベクトル）と線らしさを求める
    static func orientation(_ values: [Float], _ width: Int, _ height: Int, radius: Int)
        -> (x: [Float], y: [Float], coherence: [Float]) {
        let count = width * height
        var xx = [Float](repeating: 0, count: count), yy = xx, xy = xx
        xx.withUnsafeMutableBufferPointer { jxx in
            yy.withUnsafeMutableBufferPointer { jyy in
                xy.withUnsafeMutableBufferPointer { jxy in
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        for x in 0..<width {
                            let gx = (values[y * width + min(width - 1, x + 1)] - values[y * width + max(0, x - 1)]) / 2
                            let gy = (values[min(height - 1, y + 1) * width + x] - values[max(0, y - 1) * width + x]) / 2
                            let i = y * width + x
                            jxx[i] = gx * gx; jyy[i] = gy * gy; jxy[i] = gx * gy
                        }
                    }
                }
            }
        }
        xx = BrightStacker.boxMean(xx, width, height, radius)
        yy = BrightStacker.boxMean(yy, width, height, radius)
        xy = BrightStacker.boxMean(xy, width, height, radius)
        var directionX = [Float](repeating: 1, count: count), directionY = [Float](repeating: 0, count: count)
        var coherence = [Float](repeating: 0, count: count)
        for i in 0..<count {
            // 明るさの変化が最も大きい方向（勾配の向き）に直交する向き
            let angle = 0.5 * atan2(2 * xy[i], xx[i] - yy[i]) + Float.pi / 2
            directionX[i] = cos(angle)
            directionY[i] = sin(angle)
            let trace = xx[i] + yy[i]
            if trace > 0 {
                let difference = ((xx[i] - yy[i]) * (xx[i] - yy[i]) + 4 * xy[i] * xy[i]).squareRoot()
                coherence[i] = difference / trace
            }
        }
        return (directionX, directionY, coherence)
    }

    /// [1, 2, 1] / 4 を縦横に掛ける（端は範囲内だけで正規化する）。2画素周期の縞を0にする
    static func binomialBlur(_ values: [Float], _ width: Int, _ height: Int) -> [Float] {
        guard width > 1, height > 1, values.count == width * height else { return values }
        var horizontal = [Float](repeating: 0, count: values.count)
        horizontal.withUnsafeMutableBufferPointer { output in
            values.withUnsafeBufferPointer { input in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let row = y * width
                    output[row] = (2 * input[row] + input[row + 1]) / 3
                    for x in 1..<(width - 1) {
                        output[row + x] = (input[row + x - 1] + 2 * input[row + x] + input[row + x + 1]) / 4
                    }
                    output[row + width - 1] = (input[row + width - 2] + 2 * input[row + width - 1]) / 3
                }
            }
        }
        var output = [Float](repeating: 0, count: values.count)
        output.withUnsafeMutableBufferPointer { result in
            horizontal.withUnsafeBufferPointer { input in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let row = y * width
                    let above = y > 0 ? row - width : -1, below = y < height - 1 ? row + width : -1
                    let total: Float = 2 + (above >= 0 ? 1 : 0) + (below >= 0 ? 1 : 0)
                    for x in 0..<width {
                        var sum = 2 * input[row + x]
                        if above >= 0 { sum += input[above + x] }
                        if below >= 0 { sum += input[below + x] }
                        result[row + x] = sum / total
                    }
                }
            }
        }
        return output
    }
}
