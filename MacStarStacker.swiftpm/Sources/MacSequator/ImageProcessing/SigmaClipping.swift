import Foundation

/// シグマクリッピング（中央値基準の反復）: 画素ごとに、外れ値（飛行機・人工衛星の光跡、ホットピクセル、宇宙線など）を
/// 除いてから平均する。
///
/// 1. 中央値とMAD（中央値からのずれの中央値 × 1.4826 = 標準偏差の推定）を基準に、下側 low σ・上側 high σ を
///    超えて離れた値を除く（はじめの平均が明るい光跡に引っ張られないよう、中央値から始める）
/// 2. 残りの値の平均と標準偏差で範囲を求め直して除く、を範囲が変わらなくなるまで（最大 maximumIterations 回）繰り返す
/// 3. 残りの値の平均を結果にする
struct SigmaClipping: Equatable {
    /// 下側（暗い側）の κ
    var low: Float = 3
    /// 上側（明るい側）の κ
    var high: Float = 3

    static let maximumIterations = 3
    /// 外れ値を判断できる最少の枚数（これ未満は単純平均）
    static let minimumFrames = 3
    /// κ の入力範囲
    static let range: ClosedRange<Float> = 1...10

    /// values の先頭 count 個（並べ替えて使う）から外れ値を除いた平均。
    /// - Parameters:
    ///   - scratch: count 個以上の作業領域
    ///   - floor: 標準偏差の下限（整数の値では量子化の幅。ばらつきが0でも同じ値以外をすべて外れ値にしない）
    func clippedMean(_ values: UnsafeMutablePointer<Float>, count: Int,
                     scratch: UnsafeMutablePointer<Float>, floor: Float) -> Float {
        guard count >= Self.minimumFrames else {
            var sum: Float = 0
            for i in 0..<count { sum += values[i] }
            return count > 0 ? sum / Float(count) : 0
        }
        Self.insertionSort(values, count: count)
        let median = count % 2 == 1 ? values[count / 2] : (values[count / 2 - 1] + values[count / 2]) / 2
        for i in 0..<count { scratch[i] = abs(values[i] - median) }
        Self.insertionSort(scratch, count: count)
        let mad = count % 2 == 1 ? scratch[count / 2] : (scratch[count / 2 - 1] + scratch[count / 2]) / 2
        let sigma = max(1.4826 * mad, floor)
        var lower = median - low * sigma, upper = median + high * sigma
        // 並べてあるので、残る値は連続した範囲 [start, end) になる
        var start = 0, end = count
        for _ in 0..<Self.maximumIterations {
            let newStart = firstIndex(in: values, count: count) { $0 >= lower }
            let newEnd = firstIndex(in: values, count: count) { $0 > upper }
            // 残りが少なすぎるときは、前の範囲のままにする
            guard newEnd - newStart >= Self.minimumFrames else { break }
            if newStart == start && newEnd == end { break }
            start = newStart
            end = newEnd
            var sum: Float = 0
            for i in start..<end { sum += values[i] }
            let mean = sum / Float(end - start)
            var squares: Float = 0
            for i in start..<end { squares += (values[i] - mean) * (values[i] - mean) }
            let deviation = max((squares / Float(end - start - 1)).squareRoot(), floor)
            lower = mean - low * deviation
            upper = mean + high * deviation
        }
        var sum: Float = 0
        for i in start..<end { sum += values[i] }
        return sum / Float(end - start)
    }

    /// 少ない値（フレーム数）を並べる。数十個まではこれが最も速い
    @inline(__always)
    private static func insertionSort(_ values: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 1 else { return }
        for i in 1..<count {
            let value = values[i]
            var j = i - 1
            while j >= 0 && values[j] > value {
                values[j + 1] = values[j]
                j -= 1
            }
            values[j + 1] = value
        }
    }

    /// 並べた values で、predicate を満たす最初の位置（二分探索）
    private func firstIndex(in values: UnsafeMutablePointer<Float>, count: Int, where predicate: (Float) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(values[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// 同じ大きさのフレーム（16bit）を、値ごとにシグマクリッピングして平均する
    func stack(_ frames: [[UInt16]]) -> [UInt16] {
        guard let first = frames.first else { return [] }
        let count = first.count, frameCount = frames.count
        var output = [UInt16](repeating: 0, count: count)
        // 各フレームの先頭を指すポインタ（配列の配列を画素ごとにたどると遅い）
        let pointers = UnsafeMutablePointer<UnsafePointer<UInt16>>.allocate(capacity: frameCount)
        defer { pointers.deallocate() }
        let chunk = max(1, count / 256)
        // frames はこの間変更しないので、各フレームの画素の位置は変わらない（コピーしてメモリを倍にしない）
        withExtendedLifetime(frames) {
            for (f, frame) in frames.enumerated() {
                frame.withUnsafeBufferPointer { pointers[f] = $0.baseAddress! }
            }
            output.withUnsafeMutableBufferPointer { destination in
                DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { part in
                    let values = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
                    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
                    defer { values.deallocate(); scratch.deallocate() }
                    let end = min(count, (part + 1) * chunk)
                    for i in (part * chunk)..<end {
                        for f in 0..<frameCount { values[f] = Float(pointers[f][i]) }
                        let mean = clippedMean(values, count: frameCount, scratch: scratch, floor: 1)
                        destination[i] = UInt16(max(0, min(65535, mean.rounded())))
                    }
                }
            }
        }
        return output
    }
}
