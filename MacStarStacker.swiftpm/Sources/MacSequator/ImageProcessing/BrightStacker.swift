import Foundation

/// RAW経路の比較明合成。背景（空・雲）と細部（星・車などの光跡）を分けて合成する。
///
/// ブロック（ベイヤー配列の2x2、RGBなら画素）ごとに一番明るいフレームを1枚選ぶだけだと、
/// - 星の像は2x2より小さいため、星が R に乗ったフレームと B に乗ったフレームがブロックごとに入れ替わり、光跡が色の区切りになる
/// - 雲と青空のように明るさが近く色の違うフレームが、ノイズ次第でブロックごとに入れ替わってまだらになる。
/// 一方で値ごとに最大値を取ると、雲と青空の色が混ざって雲の範囲が紫になり、暗い所はノイズの底上げでマゼンタに転ぶ。
///
/// そこで次の2つを合わせる。
/// 1. 背景: ブロックの明るさ（ホワイトバランス係数の逆数で重み付けした合計）をまわりで平均してから比べ、
///    一番明るいフレームとの差がノイズ程度のフレームは重み exp((明るさ - 最大) / T) で混ぜる。
///    ブロックの値はすべて同じ重みで混ぜるので色の組み合わせは崩れず、明るさの近いフレームはまだらにならずなめらかに混ざる。
/// 2. 細部: フレームごとに、まわりより細く明るい部分（白トップハット）のうち1枚のノイズより十分明るい所を取り出し、
///    その値ごとの最大値を 1 に重ねる。光跡は値ごとにつながり、雲と空の色の差のように広がった差は重ねない。
///    フレームごとにそのフレームの背景からの明るさで比べるため、雲の上を通った星も星の色のまま重なる。
final class BrightStacker {
    struct Options {
        /// 明るさを比べる前に平均する範囲の半径（画素）
        var smoothingRadius = 4
        /// 細部として重ねる差の太さの半分の上限（画素）。これより広い差は背景として扱う
        var detailRadius = 8
        /// 混ぜる幅 T（平均した明るさのフレームごとのばらつきの倍数）
        var temperatureScale: Float = 1
        /// 細部を重ね始める差・すべて重ねる差（1枚あたりのノイズの標準偏差の倍数）
        var detailLower: Float = 4
        var detailUpper: Float = 7
    }

    enum Layout {
        /// ベイヤー配列（2x2のブロックが単位）
        case bayer(width: Int, height: Int)
        /// R・G・Bを並べた画素（画素が単位）
        case rgb(width: Int, height: Int)
    }

    /// ブロック・画素を単位にした格子。plane はブロックの中の位置（ベイヤー配列なら2x2の位置、RGBなら色）
    struct Grid {
        let unitsWide: Int
        let unitsHigh: Int
        let planes: Int
        /// 1単位の画素数（1辺）
        let unitSize: Int
        let width: Int
        let height: Int
        let isBayer: Bool

        init(_ layout: Layout) {
            switch layout {
            case .bayer(let width, let height):
                self.width = width; self.height = height
                unitsWide = width / 2; unitsHigh = height / 2; planes = 4; unitSize = 2; isBayer = true
            case .rgb(let width, let height):
                self.width = width; self.height = height
                unitsWide = width; unitsHigh = height; planes = 3; unitSize = 1; isBayer = false
            }
        }

        var unitCount: Int { unitsWide * unitsHigh }
        var sampleCount: Int { isBayer ? width * height : width * height * 3 }

        @inline(__always)
        func index(_ ux: Int, _ uy: Int, _ plane: Int) -> Int {
            isBayer ? (2 * uy + (plane >> 1)) * width + 2 * ux + (plane & 1) : (uy * width + ux) * 3 + plane
        }

        /// 画素の半径を単位の半径にする
        func unitRadius(_ pixels: Int) -> Int {
            pixels <= 0 ? 0 : max(1, (pixels + unitSize / 2) / unitSize)
        }
    }

    let grid: Grid
    private let weights: [Float]
    private let options: Options
    /// 単位ごとの、これまでで最も明るい（平均した）明るさ
    private var bestScore: [Float] = []
    /// 単位ごとの重みの合計
    private var weightSum: [Float] = []
    /// 重みを掛けて積算した値（元の並び）
    private var accumulated: [Float] = []
    /// フレームごとの細部（ノイズより明るい細い部分）の値ごとの最大値（元の並び）
    private var detailMaximum: [Float] = []
    /// ノイズが求まる2枚目まで、1枚目の細部を取り出すのを待つ
    private var firstFrame: [UInt16]?
    /// 2x2に収まらない奇数の端の列・行の位置と、そこの値ごとの最大値
    private let edgeIndices: [Int]
    private var edgeMaximum: [UInt16] = []
    /// 混ぜる幅。0 なら一番明るいフレームを1枚選ぶ
    private(set) var temperature: Float = 0
    /// 1枚あたりのノイズ（2枚目で求める）
    private(set) var noise: FrameNoiseModel?
    private var added = 0

    init(layout: Layout, weights: [Float], options: Options = Options()) {
        grid = Grid(layout)
        precondition(weights.count == grid.planes, "重みの数が一致しません")
        self.weights = weights
        self.options = options
        var edges: [Int] = []
        if grid.isBayer {
            for y in 0..<grid.height {
                for x in 0..<grid.width where x >= grid.unitsWide * 2 || y >= grid.unitsHigh * 2 {
                    edges.append(y * grid.width + x)
                }
            }
        }
        edgeIndices = edges
    }

    func add(_ frame: [UInt16]) {
        precondition(frame.count == grid.sampleCount, "合成するフレームの画素数が一致しません")
        added += 1
        let scores = smoothedScores(frame)
        if added == 1 {
            bestScore = scores
            weightSum = [Float](repeating: 1, count: grid.unitCount)
            accumulated = frame.map(Float.init)
            detailMaximum = [Float](repeating: 0, count: grid.sampleCount)
            edgeMaximum = edgeIndices.map { frame[$0] }
            firstFrame = frame
            return
        }
        if added == 2, let first = firstFrame {
            let model = FrameNoiseModel(first: first, second: frame, grid: grid)
            noise = model
            temperature = Self.scoreSpread(bestScore, scores) * options.temperatureScale
            addDetail(first, noise: model)
            firstFrame = nil
        }
        accumulate(frame, scores: scores)
        if let noise { addDetail(frame, noise: noise) }
        for (k, i) in edgeIndices.enumerated() where frame[i] > edgeMaximum[k] { edgeMaximum[k] = frame[i] }
    }

    func result() -> [UInt16] {
        let count = grid.sampleCount
        guard added > 0 else { return [UInt16](repeating: 0, count: count) }
        let g = grid
        // 1. 背景（重み付きで混ぜた値）
        var background = [Float](repeating: 0, count: count)
        background.withUnsafeMutableBufferPointer { output in
            accumulated.withUnsafeBufferPointer { sums in
                weightSum.withUnsafeBufferPointer { totals in
                    DispatchQueue.concurrentPerform(iterations: g.unitsHigh) { uy in
                        for ux in 0..<g.unitsWide {
                            let total = totals[uy * g.unitsWide + ux]
                            for plane in 0..<g.planes {
                                let i = g.index(ux, uy, plane)
                                output[i] = sums[i] / total
                            }
                        }
                    }
                }
            }
        }
        // 2. 細部: 背景にすでに含まれている細部（混ぜた分）より明るい分だけを重ねる
        if noise != nil {
            let radius = g.unitRadius(options.detailRadius)
            for plane in 0..<g.planes {
                let values = extract(plane: plane, from: background)
                let opened = Self.opening(values, g.unitsWide, g.unitsHigh, radius)
                background.withUnsafeMutableBufferPointer { output in
                    detailMaximum.withUnsafeBufferPointer { details in
                        DispatchQueue.concurrentPerform(iterations: g.unitsHigh) { uy in
                            for ux in 0..<g.unitsWide {
                                let u = uy * g.unitsWide + ux
                                let i = g.index(ux, uy, plane)
                                let extra = details[i] - (values[u] - opened[u])
                                if extra > 0 { output[i] += extra }
                            }
                        }
                    }
                }
            }
        }
        // 2x2に収まらない奇数の端の列・行は値ごとの最大値
        for (k, i) in edgeIndices.enumerated() { background[i] = Float(edgeMaximum[k]) }
        return background.map { UInt16(max(0, min(65535, $0.rounded()))) }
    }

    // MARK: - 細部

    /// フレームの細部（白トップハットのうちノイズより十分明るい所）で、細部の値ごとの最大値を更新する。
    /// 明るさはオープニングからの差（広がった明るさを含まない）で測るが、ノイズより明るいかは
    /// まわりの平均からの差で判定する（オープニングはノイズの谷に沿うため、ノイズだけの所でも差が大きく出る）
    private func addDetail(_ frame: [UInt16], noise: FrameNoiseModel) {
        let g = grid
        let radius = g.unitRadius(options.detailRadius)
        let lower = options.detailLower
        let span = max(1e-3, options.detailUpper - options.detailLower)
        for plane in 0..<g.planes {
            let values = extract(plane: plane, from: frame)
            let opened = Self.opening(values, g.unitsWide, g.unitsHigh, radius)
            let mean = Self.boxMean(values, g.unitsWide, g.unitsHigh, radius)
            detailMaximum.withUnsafeMutableBufferPointer { details in
                DispatchQueue.concurrentPerform(iterations: g.unitsHigh) { uy in
                    for ux in 0..<g.unitsWide {
                        let u = uy * g.unitsWide + ux
                        let excess = values[u] - opened[u]
                        guard excess > 0 else { continue }
                        let i = g.index(ux, uy, plane)
                        guard excess > details[i] else { continue }
                        let sigma = noise.sigma(plane: plane, level: mean[u])
                        let t = min(1, max(0, ((values[u] - mean[u]) / sigma - lower) / span))
                        let detail = excess * t
                        if detail > details[i] { details[i] = detail }
                    }
                }
            }
        }
    }

    /// ブロックの中の位置 plane の値を、単位の格子に並べて取り出す
    private func extract<T: BinaryInteger>(plane: Int, from samples: [T]) -> [Float] {
        let g = grid
        var values = [Float](repeating: 0, count: g.unitCount)
        values.withUnsafeMutableBufferPointer { output in
            samples.withUnsafeBufferPointer { input in
                DispatchQueue.concurrentPerform(iterations: g.unitsHigh) { uy in
                    for ux in 0..<g.unitsWide { output[uy * g.unitsWide + ux] = Float(input[g.index(ux, uy, plane)]) }
                }
            }
        }
        return values
    }

    private func extract(plane: Int, from samples: [Float]) -> [Float] {
        let g = grid
        var values = [Float](repeating: 0, count: g.unitCount)
        values.withUnsafeMutableBufferPointer { output in
            samples.withUnsafeBufferPointer { input in
                DispatchQueue.concurrentPerform(iterations: g.unitsHigh) { uy in
                    for ux in 0..<g.unitsWide { output[uy * g.unitsWide + ux] = input[g.index(ux, uy, plane)] }
                }
            }
        }
        return values
    }

    // MARK: - 背景

    /// 単位ごとの重み付きの明るさを、smoothingRadius の範囲で平均する
    private func smoothedScores(_ frame: [UInt16]) -> [Float] {
        let g = grid
        var scores = [Float](repeating: 0, count: g.unitCount)
        let w = weights
        scores.withUnsafeMutableBufferPointer { output in
            frame.withUnsafeBufferPointer { input in
                DispatchQueue.concurrentPerform(iterations: g.unitsHigh) { uy in
                    for ux in 0..<g.unitsWide {
                        var score: Float = 0
                        for plane in 0..<g.planes { score += w[plane] * Float(input[g.index(ux, uy, plane)]) }
                        output[uy * g.unitsWide + ux] = score
                    }
                }
            }
        }
        return Self.boxMean(scores, g.unitsWide, g.unitsHigh, g.unitRadius(options.smoothingRadius))
    }

    private func accumulate(_ frame: [UInt16], scores: [Float]) {
        let g = grid
        let temperature = self.temperature
        accumulated.withUnsafeMutableBufferPointer { sums in
            weightSum.withUnsafeMutableBufferPointer { totals in
                bestScore.withUnsafeMutableBufferPointer { best in
                    frame.withUnsafeBufferPointer { input in
                        DispatchQueue.concurrentPerform(iterations: g.unitsHigh) { uy in
                            for ux in 0..<g.unitsWide {
                                let u = uy * g.unitsWide + ux
                                let score = scores[u]
                                if temperature <= 0 {
                                    // 混ぜる幅が求められないときは、一番明るいフレームを1枚選ぶ
                                    guard score > best[u] else { continue }
                                    best[u] = score
                                    for plane in 0..<g.planes {
                                        let i = g.index(ux, uy, plane)
                                        sums[i] = Float(input[i])
                                    }
                                } else if score > best[u] {
                                    // より明るいフレーム: それまでの積算を縮めて、このフレームを重み1で加える
                                    let factor = exp((best[u] - score) / temperature)
                                    best[u] = score
                                    totals[u] = totals[u] * factor + 1
                                    for plane in 0..<g.planes {
                                        let i = g.index(ux, uy, plane)
                                        sums[i] = sums[i] * factor + Float(input[i])
                                    }
                                } else {
                                    let z = (score - best[u]) / temperature
                                    guard z > -20 else { continue }
                                    let weight = exp(z)
                                    totals[u] += weight
                                    for plane in 0..<g.planes {
                                        let i = g.index(ux, uy, plane)
                                        sums[i] += weight * Float(input[i])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 2枚の（平均した）明るさの差から、1枚あたりのばらつき（標準偏差）を求める。
    /// 空が全体に明るくなった分は中央値を引いて除き、星や雲の動きで大きく違う所は中央値からのずれの中央値で除く
    static func scoreSpread(_ first: [Float], _ second: [Float]) -> Float {
        let count = min(first.count, second.count)
        guard count >= 64 else { return 0 }
        let step = max(1, count / 200_000)
        var differences: [Float] = []
        differences.reserveCapacity(count / step + 1)
        for i in stride(from: 0, to: count, by: step) { differences.append(first[i] - second[i]) }
        differences.sort()
        let median = differences[differences.count / 2]
        var deviations = differences.map { abs($0 - median) }
        deviations.sort()
        // 正規分布では 標準偏差 = 1.4826 × 中央値からのずれの中央値。差の標準偏差は1枚の √2 倍
        return 1.4826 * deviations[deviations.count / 2] / Float(2).squareRoot()
    }

    // MARK: - フィルタ（単位の格子の上、端は範囲内だけを使う）
    //
    // どれも窓の大きさに依らない手間で計算する（平均は累積和、最小・最大は van Herk / Gil-Werman の方法）。
    // 縦方向は、列をまとめて受け持ち、行の順に読み書きする（メモリを飛び飛びに読まない）。

    /// 縦方向で1つの処理が受け持つ列の数
    private static let columnChunk = 256

    /// (2r+1)×(2r+1) の範囲の平均
    static func boxMean(_ values: [Float], _ width: Int, _ height: Int, _ radius: Int) -> [Float] {
        guard radius > 0, width > 0, height > 0, values.count == width * height else { return values }
        var horizontal = [Float](repeating: 0, count: values.count)
        horizontal.withUnsafeMutableBufferPointer { output in
            values.withUnsafeBufferPointer { input in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let row = y * width
                    var sum: Float = 0
                    for x in 0..<min(width, radius) { sum += input[row + x] }
                    for x in 0..<width {
                        if x + radius < width { sum += input[row + x + radius] }
                        if x - radius - 1 >= 0 { sum -= input[row + x - radius - 1] }
                        let cells = min(width - 1, x + radius) - max(0, x - radius) + 1
                        output[row + x] = sum / Float(cells)
                    }
                }
            }
        }
        var output = [Float](repeating: 0, count: values.count)
        output.withUnsafeMutableBufferPointer { result in
            horizontal.withUnsafeBufferPointer { input in
                let chunks = (width + columnChunk - 1) / columnChunk
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let x0 = chunk * columnChunk, x1 = min(width, x0 + columnChunk)
                    var sums = [Float](repeating: 0, count: x1 - x0)
                    for y in 0..<min(height, radius) {
                        for x in x0..<x1 { sums[x - x0] += input[y * width + x] }
                    }
                    for y in 0..<height {
                        if y + radius < height {
                            let row = (y + radius) * width
                            for x in x0..<x1 { sums[x - x0] += input[row + x] }
                        }
                        if y - radius - 1 >= 0 {
                            let row = (y - radius - 1) * width
                            for x in x0..<x1 { sums[x - x0] -= input[row + x] }
                        }
                        let scale = 1 / Float(min(height - 1, y + radius) - max(0, y - radius) + 1)
                        let row = y * width
                        for x in x0..<x1 { result[row + x] = sums[x - x0] * scale }
                    }
                }
            }
        }
        return output
    }

    /// オープニング（最小フィルタのあと最大フィルタ）。窓より細い明るい部分が取り除かれる
    static func opening(_ values: [Float], _ width: Int, _ height: Int, _ radius: Int) -> [Float] {
        filter(filter(values, width, height, radius, minimum: true), width, height, radius, minimum: false)
    }

    /// (2r+1)×(2r+1) の範囲の最小値（minimum）・最大値
    static func filter(_ values: [Float], _ width: Int, _ height: Int, _ radius: Int, minimum: Bool) -> [Float] {
        guard radius > 0, width > 0, height > 0, values.count == width * height else { return values }
        let window = 2 * radius + 1
        @inline(__always) func pick(_ a: Float, _ b: Float) -> Float { minimum ? min(a, b) : max(a, b) }

        // 横方向: 行ごとに、窓の幅で区切った区間の前からの累積（forward）と後ろからの累積（backward）を作る
        var horizontal = [Float](repeating: 0, count: values.count)
        horizontal.withUnsafeMutableBufferPointer { output in
            values.withUnsafeBufferPointer { input in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let row = y * width
                    var forward = [Float](repeating: 0, count: width)
                    var backward = [Float](repeating: 0, count: width)
                    for x in 0..<width {
                        forward[x] = x % window == 0 ? input[row + x] : pick(forward[x - 1], input[row + x])
                    }
                    for x in stride(from: width - 1, through: 0, by: -1) {
                        backward[x] = (x % window == window - 1 || x == width - 1)
                            ? input[row + x] : pick(backward[x + 1], input[row + x])
                    }
                    for x in 0..<width {
                        output[row + x] = combine(forward, backward, max(0, x - radius), min(width - 1, x + radius), window, pick)
                    }
                }
            }
        }
        // 縦方向: 列をまとめて、同じ方法を行の順に行う
        var forward = [Float](repeating: 0, count: values.count)
        var backward = [Float](repeating: 0, count: values.count)
        var output = [Float](repeating: 0, count: values.count)
        output.withUnsafeMutableBufferPointer { result in
            forward.withUnsafeMutableBufferPointer { front in
                backward.withUnsafeMutableBufferPointer { back in
                    horizontal.withUnsafeBufferPointer { input in
                        let chunks = (width + columnChunk - 1) / columnChunk
                        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                            let x0 = chunk * columnChunk, x1 = min(width, x0 + columnChunk)
                            for y in 0..<height {
                                let row = y * width
                                if y % window == 0 {
                                    for x in x0..<x1 { front[row + x] = input[row + x] }
                                } else {
                                    for x in x0..<x1 { front[row + x] = pick(front[row - width + x], input[row + x]) }
                                }
                            }
                            for y in stride(from: height - 1, through: 0, by: -1) {
                                let row = y * width
                                if y % window == window - 1 || y == height - 1 {
                                    for x in x0..<x1 { back[row + x] = input[row + x] }
                                } else {
                                    for x in x0..<x1 { back[row + x] = pick(back[row + width + x], input[row + x]) }
                                }
                            }
                            for y in 0..<height {
                                let a = max(0, y - radius), b = min(height - 1, y + radius)
                                let row = y * width
                                if a / window != b / window {
                                    for x in x0..<x1 { result[row + x] = pick(back[a * width + x], front[b * width + x]) }
                                } else if a % window == 0 {
                                    for x in x0..<x1 { result[row + x] = front[b * width + x] }
                                } else {
                                    for x in x0..<x1 { result[row + x] = back[a * width + x] }
                                }
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    /// 区間 [a, b]（長さは窓以下）の最小・最大を、区切りごとの累積から求める。
    /// a と b が別の区切りなら backward[a] と forward[b]、同じ区切りなら区切りの先頭から（forward）か末尾まで（backward）
    @inline(__always)
    private static func combine(_ forward: [Float], _ backward: [Float], _ a: Int, _ b: Int, _ window: Int,
                                _ pick: (Float, Float) -> Float) -> Float {
        if a / window != b / window { return pick(backward[a], forward[b]) }
        return a % window == 0 ? forward[b] : backward[a]
    }
}

/// 1枚あたりのノイズの標準偏差（ブロックの中の位置ごと・明るさごと）。同じ構図の2枚の差から求める。
/// 空が全体に明るくなった分は差の中央値を引いて除き、星や雲の動きで差が大きい所は中央値からのずれの中央値で除く。
struct FrameNoiseModel {
    /// 明るさの刻み（値の平方根で刻む。光のノイズは明るさの平方根に比例するため）
    static let binWidth: Float = 2
    static let binCount = 129
    /// 差の数え上げの範囲（±histogramHalf）
    private static let histogramHalf = 2048
    /// 1つの刻みでノイズを求めるのに必要な値の数
    private static let minimumSamples = 64

    let planes: Int
    /// plane * binCount + bin
    private let sigmas: [Float]

    init(first: [UInt16], second: [UInt16], grid: BrightStacker.Grid) {
        planes = grid.planes
        let bins = Self.binCount, half = Self.histogramHalf, size = half * 2
        let cells = planes * bins
        var histogram = [UInt32](repeating: 0, count: cells * size)
        var totals = [Int](repeating: 0, count: cells)
        // 単位を3つおきに数える
        for u in stride(from: 0, to: grid.unitCount, by: 3) {
            let ux = u % grid.unitsWide, uy = u / grid.unitsWide
            for plane in 0..<planes {
                let i = grid.index(ux, uy, plane)
                let a = Int(first[i]), b = Int(second[i])
                let cell = plane * bins + Self.bin(of: Float(a + b) / 2)
                histogram[cell * size + max(0, min(size - 1, a - b + half))] += 1
                totals[cell] += 1
            }
        }
        var sigmas = [Float](repeating: -1, count: cells)
        var deviations = [UInt32](repeating: 0, count: size)
        for cell in 0..<cells where totals[cell] >= Self.minimumSamples {
            let base = cell * size
            let half = (totals[cell] + 1) / 2
            // 差の中央値
            var seen = 0, median = 0
            for value in 0..<size {
                seen += Int(histogram[base + value])
                if seen >= half { median = value; break }
            }
            // 中央値からのずれの中央値
            for value in 0..<size { deviations[value] = 0 }
            for value in 0..<size where histogram[base + value] > 0 {
                deviations[abs(value - median)] += histogram[base + value]
            }
            seen = 0
            var mad = 0
            for value in 0..<size {
                seen += Int(deviations[value])
                if seen >= half { mad = value; break }
            }
            // 正規分布では 標準偏差 = 1.4826 × MAD。差の標準偏差は1枚の √2 倍。
            // 値は整数なので、MAD が0になるほど小さいノイズも 0.5 とみなす
            sigmas[cell] = 1.4826 * max(0.5, Float(mad)) / Float(2).squareRoot()
        }
        // 数が足りない刻みは、同じ位置の近い刻みの値を使う
        for plane in 0..<planes {
            let base = plane * bins
            let known = (0..<bins).filter { sigmas[base + $0] > 0 }
            for bin in 0..<bins where sigmas[base + bin] <= 0 {
                if let nearest = known.min(by: { abs($0 - bin) < abs($1 - bin) }) {
                    sigmas[base + bin] = sigmas[base + nearest]
                } else {
                    // ノイズを見積もれない（画像が小さすぎる）ときは、細部を重ねない
                    sigmas[base + bin] = .greatestFiniteMagnitude
                }
            }
        }
        self.sigmas = sigmas
    }

    private static func bin(of level: Float) -> Int {
        min(binCount - 1, Int(max(0, level).squareRoot() / binWidth))
    }

    /// plane の位置の値（level）での1枚あたりのノイズの標準偏差
    func sigma(plane: Int, level: Float) -> Float {
        sigmas[plane * Self.binCount + Self.bin(of: level)]
    }
}
