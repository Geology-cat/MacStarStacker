import Foundation
import AppKit
import CoreImage
import Accelerate
import OpenCVWrapper

/// RAWを現像せずに合成した結果。DNGにはセンサーのデータのまま書き出す。
struct RawStackResult {
    enum Kind {
        /// ベイヤー配列のまま合成（位置合わせなし・比較明）
        case bayer
        /// カメラ色空間のままデモザイクして位置合わせ・合成（案B）
        case cameraRGB
    }

    let kind: Kind
    let info: RawSensorInfo
    /// bayer: width*height（黒レベル込みの生の値） / cameraRGB: width*height*3（黒レベル除去済み）
    let pixels: [UInt16]
    let width: Int
    let height: Int
    /// cameraRGB のセンサー飽和値
    let whiteLevel: Double
    /// 機種ごとの露出基準（EV）
    let baselineExposure: Double
    /// DNGのサムネイル・プレビュー用の現像画像（センサーの向き）
    let previewImage: CGImage
    /// アプリ表示・TIFF/JPEG/FITS書き出し用の現像画像（撮影時の向き）
    let displayImage: NSImage

    var modeDescription: String {
        switch kind {
        case .bayer: return "RAW（ベイヤー配列）"
        case .cameraRGB: return "RAW（カメラ色空間RGB）"
        }
    }

    func writeDNG(metadata: RawMetadataInfo?, embedLensProfile: Bool, to url: URL) throws {
        let camera = info.cameraColorProfile(baselineExposure: baselineExposure)
        switch kind {
        case .bayer:
            try DNGWriter.writeBayer(
                pixels: pixels, width: width, height: height,
                mosaic: info.bayerMosaic, camera: camera,
                previewSource: previewImage, metadata: metadata,
                embedLensProfile: embedLensProfile, to: url
            )
        case .cameraRGB:
            try DNGWriter.writeCameraRGB(
                pixels: pixels, width: width, height: height, whiteLevel: whiteLevel,
                camera: camera, previewSource: previewImage, metadata: metadata,
                embedLensProfile: embedLensProfile, to: url
            )
        }
    }
}

/// LibRawでセンサーデータを読み、ベイヤー配列（位置合わせなし）またはカメラ色空間RGB（位置合わせあり）で合成する。
enum RawStackPipeline {
    enum Mode {
        case average
        case median
        case compareBright
    }

    struct Input {
        let lights: [URL]
        let baseIndex: Int
        let darks: [URL]
        let flats: [URL]
        let biases: [URL]
        let mode: Mode
        let align: Bool
        /// 空（青）と地上（緑）を塗り分けたマスク（表示中の画像の向き）
        let skyGroundMask: NSImage?
        let maskFeatherRadius: CGFloat
        /// 比較明の光跡除去: フレーム番号 → 光跡マスク（表示中の画像の向き）
        let trailMasks: [Int: [NSImage]]
    }

    struct PipelineError: LocalizedError {
        let message: String
        /// false の場合は現像済み画像での合成に切り替えても解決しない（メモリ不足など）
        var allowsFallback = true
        var errorDescription: String? { message }
    }

    typealias Progress = (_ fraction: Double, _ status: String) -> Void

    /// RAW経路で合成できる入力かを判定する。nil の場合は従来の現像済み画像での合成を使う。
    /// 全ファイルがベイヤー配列のRAWで、寸法・配列の位相・向きがそろっている必要がある。
    static func route(for input: Input) -> RawStackResult.Kind? {
        let urls = input.lights + input.darks + input.flats + input.biases
        guard !input.lights.isEmpty, urls.allSatisfy(RawDecoder.isRawFile) else { return nil }
        guard let first = try? RawDecoder.readInfo(from: input.lights[0]), first.isBayer else { return nil }
        for url in urls.dropFirst() {
            guard let info = try? RawDecoder.readInfo(from: url), info.isStackCompatible(with: first) else { return nil }
        }
        return input.align ? .cameraRGB : .bayer
    }

    /// RAWのまま合成する。RAW経路の対象外（route が nil）の入力では nil を返す。
    static func stack(_ input: Input, progress: Progress) throws -> RawStackResult? {
        guard let kind = route(for: input) else { return nil }
        let baseIndex = min(max(0, input.baseIndex), input.lights.count - 1)
        let firstInfo = try RawDecoder.readInfo(from: input.lights[0])
        try checkMemory(frameCount: input.lights.count, info: firstInfo, kind: kind,
                        mode: input.mode, hasSkyGroundMask: input.skyGroundMask != nil)

        progress(0.02, "キャリブレーションフレームを構築中...")
        let darkMaster = try buildMaster(input.darks)
        let flatMaster = try buildMaster(input.flats)
        let biasMaster = try buildMaster(input.biases)

        let baseFrame = try RawDecoder.readBayer(from: input.lights[baseIndex])
        let info = baseFrame.info
        let calibrator = BayerCalibrator(info: info, dark: darkMaster, bias: biasMaster, flat: flatMaster)
        let pixelCount = info.width * info.height

        let result: RawStackResult
        switch kind {
        case .bayer:
            result = try stackBayer(input: input, info: info, calibrator: calibrator, pixelCount: pixelCount, progress: progress)
        case .cameraRGB:
            result = try stackCameraRGB(input: input, baseIndex: baseIndex, info: info, calibrator: calibrator, progress: progress)
        }
        return result
    }

    /// 中央値合成は全フレームを保持するため、搭載メモリに収まるかを事前に確認する。
    static func checkMemory(
        frameCount: Int, info: RawSensorInfo, kind: RawStackResult.Kind, mode: Mode, hasSkyGroundMask: Bool,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) throws {
        guard mode == .median else { return }
        let samplesPerFrame = info.width * info.height * (kind == .cameraRGB ? 3 : 1)
        // 位置合わせありで空と地上を分けると、地上側（位置合わせ前）も別に中央値用に保持する
        let retainingStackers: UInt64 = (hasSkyGroundMask && kind == .cameraRGB) ? 2 : 1
        let required = UInt64(frameCount) * UInt64(samplesPerFrame) * 2 * retainingStackers
        let budget = physicalMemory / 2
        if required > budget {
            let gigabytes = String(format: "%.1f", Double(required) / 1_073_741_824)
            throw PipelineError(
                message: "中央値合成に約\(gigabytes)GBのメモリが必要なため実行できません。枚数を減らすか、平均で合成してください",
                allowsFallback: false
            )
        }
    }

    // MARK: - ベイヤー配列のまま合成

    private static func stackBayer(
        input: Input,
        info: RawSensorInfo,
        calibrator: BayerCalibrator,
        pixelCount: Int,
        progress: Progress
    ) throws -> RawStackResult {
        let total = input.lights.count
        let skyStacker = StreamingStacker(mode: input.mode, count: pixelCount,
                                          grouping: .bayerBlocks(width: info.width, height: info.height,
                                                                 weights: brightWeights(info, colors: info.cfaPattern)))
        // 地上側は固定構図のままノイズを減らす（比較明の場合は平均）
        let groundMode: Mode = input.mode == .median ? .median : .average
        let groundStacker = (input.skyGroundMask != nil && groundMode != input.mode)
            ? StreamingStacker(mode: groundMode, count: pixelCount) : nil

        for index in 0..<total {
            progress(0.05 + Double(index) / Double(total) * 0.75, "RAWを読み込み・補正中 (\(index + 1)/\(total))...")
            var frame = try RawDecoder.readBayer(from: input.lights[index])
            try requireCompatible(frame.info, info, url: input.lights[index])
            if input.mode == .compareBright, let masks = input.trailMasks[index], !masks.isEmpty {
                try removeTrails(from: &frame.pixels, info: info, masks: masks, index: index, lights: input.lights)
            }
            calibrator.apply(to: &frame.pixels)
            skyStacker.add(frame.pixels)
            groundStacker?.add(frame.pixels)
        }

        progress(0.82, "スタッキング中...")
        var pixels = skyStacker.result()
        if let mask = input.skyGroundMask {
            let ground = groundStacker?.result() ?? pixels
            let alpha = try groundAlpha(mask: mask, info: info, featherRadius: input.maskFeatherRadius)
            blend(sky: &pixels, ground: ground, alpha: alpha, samplesPerPixel: 1)
        }

        progress(0.92, "RAWを現像してプレビューを作成中...")
        let baseline = baselineExposure(for: input.lights[min(max(0, input.baseIndex), input.lights.count - 1)])
        let rendered = try render(kind: .bayer, pixels: pixels, info: info, width: info.width, height: info.height,
                                  whiteLevel: info.whiteLevel, baselineExposure: baseline)
        return RawStackResult(
            kind: .bayer, info: info, pixels: pixels, width: info.width, height: info.height,
            whiteLevel: info.whiteLevel, baselineExposure: baseline,
            previewImage: rendered.preview, displayImage: rendered.display
        )
    }

    // MARK: - カメラ色空間RGBで位置合わせ・合成（案B）

    private static func stackCameraRGB(
        input: Input,
        baseIndex: Int,
        info: RawSensorInfo,
        calibrator: BayerCalibrator,
        progress: Progress
    ) throws -> RawStackResult {
        let total = input.lights.count

        func demosaic(_ index: Int) throws -> CameraRGBFrame {
            let url = input.lights[index]
            if calibrator.isIdentity {
                return try RawDecoder.demosaicCameraRGB(from: url)
            }
            var bayer = try RawDecoder.readBayer(from: url)
            try requireCompatible(bayer.info, info, url: url)
            calibrator.apply(to: &bayer.pixels)
            return try RawDecoder.demosaicCameraRGB(from: url, replacementBayer: bayer.pixels)
        }

        progress(0.05, "基準画像を現像中...")
        let base = try demosaic(baseIndex)
        let width = base.width, height = base.height
        let sampleCount = width * height * 3
        let grayScale = GrayConverter(base: base)
        let baseGray = grayScale.gray(base)

        let skyStacker = StreamingStacker(mode: input.mode, count: sampleCount,
                                          grouping: .rgbPixels(weights: brightWeights(info, colors: [0, 1, 2])))
        let groundMode: Mode = input.mode == .median ? .median : .average
        let groundStacker = input.skyGroundMask != nil ? StreamingStacker(mode: groundMode, count: sampleCount) : nil

        for index in 0..<total {
            progress(0.08 + Double(index) / Double(total) * 0.74, "RAWを現像・位置合わせ中 (\(index + 1)/\(total))...")
            let frame = index == baseIndex ? base : try demosaic(index)
            guard frame.width == width, frame.height == height else {
                throw PipelineError(message: "画像サイズが一致しません: \(input.lights[index].lastPathComponent)")
            }
            groundStacker?.add(frame.pixels)
            if index == baseIndex {
                skyStacker.add(frame.pixels)
                continue
            }
            let homography: [NSNumber]
            do {
                homography = try ImageAligner.homography(
                    fromGrayPixels: grayScale.gray(frame), toBaseGray: baseGray,
                    width: width, height: height
                )
            } catch {
                throw PipelineError(message: "星の位置合わせに失敗しました: \(input.lights[index].lastPathComponent)（\(error.localizedDescription)）")
            }
            let warped = NSMutableData(length: sampleCount * MemoryLayout<UInt16>.size)!
            frame.pixels.withUnsafeBytes { source in
                warped.replaceBytes(in: NSRange(location: 0, length: source.count), withBytes: source.baseAddress!)
            }
            try ImageAligner.warpRGB16Pixels(warped, width: width, height: height, homography: homography)
            var aligned = [UInt16](repeating: 0, count: sampleCount)
            aligned.withUnsafeMutableBytes { destination in
                destination.copyMemory(from: UnsafeRawBufferPointer(start: warped.bytes, count: warped.length))
            }
            skyStacker.add(aligned)
        }

        progress(0.84, "スタッキング中...")
        var pixels = skyStacker.result()
        if let mask = input.skyGroundMask, let ground = groundStacker?.result() {
            let alpha = try groundAlpha(mask: mask, info: info, featherRadius: input.maskFeatherRadius)
            blend(sky: &pixels, ground: ground, alpha: alpha, samplesPerPixel: 3)
        }

        progress(0.92, "RAWを現像してプレビューを作成中...")
        let baseline = baselineExposure(for: input.lights[baseIndex])
        let rendered = try render(kind: .cameraRGB, pixels: pixels, info: base.info, width: width, height: height,
                                  whiteLevel: base.whiteLevel, baselineExposure: baseline)
        return RawStackResult(
            kind: .cameraRGB, info: base.info, pixels: pixels, width: width, height: height,
            whiteLevel: base.whiteLevel, baselineExposure: baseline,
            previewImage: rendered.preview, displayImage: rendered.display
        )
    }

    /// 比較明合成で明るさを比べるときの色ごとの重み（撮影時ホワイトバランス係数の逆数）。
    /// センサー値のまま色ごとに最大値を取ると、ノイズの最大値による底上げがR・G・Bで同じ量になり、
    /// 現像時にホワイトバランスでR・Bだけ増幅されて暗部がマゼンタに転ぶ。
    /// 逆数で重み付けした明るさでフレームを選ぶと、底上げ量がホワイトバランス後に揃い無彩色になる。
    private static func brightWeights(_ info: RawSensorInfo, colors: [UInt8]) -> [Float] {
        colors.map { color in
            let index = Int(color)
            guard index < info.cameraMultipliers.count, info.cameraMultipliers[index] > 0 else { return 1 }
            return Float(1.0 / info.cameraMultipliers[index])
        }
    }

    // MARK: - キャリブレーション

    private static func buildMaster(_ urls: [URL]) throws -> [UInt16]? {
        guard !urls.isEmpty else { return nil }
        let frames = try urls.map { try RawDecoder.readBayer(from: $0).pixels }
        guard frames.count > 1 else { return frames[0] }
        let stacker = StreamingStacker(mode: .median, count: frames[0].count)
        frames.forEach(stacker.add)
        return stacker.result()
    }

    private static func requireCompatible(_ info: RawSensorInfo, _ base: RawSensorInfo, url: URL) throws {
        guard info.isStackCompatible(with: base) else {
            throw PipelineError(message: "センサーの配置が基準画像と一致しません: \(url.lastPathComponent)")
        }
    }

    // MARK: - 光跡除去（ベイヤー配列上で前後フレームと置き換え）

    /// 光跡マスク部分を前後フレームの平均で置き換える。同じセンサー位置同士なので配列の色は崩れない。
    private static func removeTrails(
        from pixels: inout [UInt16],
        info: RawSensorInfo,
        masks: [NSImage],
        index: Int,
        lights: [URL]
    ) throws {
        let previous = index > 0 ? try? RawDecoder.readBayer(from: lights[index - 1]) : nil
        let next = index + 1 < lights.count ? try? RawDecoder.readBayer(from: lights[index + 1]) : nil
        let references = [previous, next].compactMap { $0 }.filter { $0.info.isStackCompatible(with: info) }
        // 前後フレームが無い場合は周囲から補間できない（配列の色が混ざる）ため、このフレームは除去しない。
        guard !references.isEmpty else { return }
        let alpha = try trailAlpha(masks: masks, info: info)
        let width = info.width
        pixels.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: info.height) { y in
                for x in 0..<width {
                    let i = y * width + x
                    let a = alpha[i]
                    guard a > 0 else { continue }
                    var reference: Float = 0
                    for frame in references { reference += Float(frame.pixels[i]) }
                    reference /= Float(references.count)
                    let blended = Float(output[i]) * (1 - a) + reference * a
                    output[i] = UInt16(max(0, min(65535, blended.rounded())))
                }
            }
        }
    }

    // MARK: - マスク（表示の向き → センサーの向き・解像度）

    /// 撮影時の向きで描かれたマスクを、センサーの向き・解像度の CIImage に変換する。
    private static func sensorAlignedMask(_ mask: NSImage, info: RawSensorInfo) throws -> CIImage {
        guard let cg = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PipelineError(message: "マスク画像を読み込めませんでした")
        }
        var image = CIImage(cgImage: cg)
        let inverse: CGImagePropertyOrientation
        switch info.orientation {
        case 3: inverse = .down
        case 6: inverse = .left
        case 8: inverse = .right
        default: inverse = .up
        }
        image = image.oriented(inverse)
        let extent = image.extent
        let target = CGRect(x: 0, y: 0, width: info.width, height: info.height)
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / extent.width, y: target.height / extent.height))
            .cropped(to: target)
    }

    /// CIImage の赤チャンネルを 0〜1 の Float 配列（上の行から）として取り出す。
    private static func renderAlpha(_ image: CIImage, width: Int, height: Int) throws -> [Float] {
        var rgba = [Float](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        rgba.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: nil)
        }
        // render(toBitmap:) は画像の上端の行から書き込むので、そのまま上の行から並べる
        var alpha = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            alpha[i] = min(1, max(0, rgba[i * 4]))
        }
        return alpha
    }

    private static func trailAlpha(masks: [NSImage], info: RawSensorInfo) throws -> [Float] {
        var combined: CIImage?
        for mask in masks {
            let aligned = try sensorAlignedMask(mask, info: info)
            combined = combined.map { aligned.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? aligned
        }
        guard var image = combined else { return [Float](repeating: 0, count: info.width * info.height) }
        // 従来処理と同様に境界だけをわずかにぼかす
        image = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
            .cropped(to: CGRect(x: 0, y: 0, width: info.width, height: info.height))
        return try renderAlpha(image, width: info.width, height: info.height)
    }

    /// 緑（地上）を1、青（空）と未塗装を0とする合成比率。従来の blendSkyGround と同じ規則。
    private static func groundAlpha(mask: NSImage, info: RawSensorInfo, featherRadius: CGFloat) throws -> [Float] {
        let target = CGRect(x: 0, y: 0, width: info.width, height: info.height)
        let aligned = try sensorAlignedMask(mask, info: info)
        let groundVector = CIVector(x: 0, y: 1, z: -1, w: 0)
        var image = aligned
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": groundVector, "inputGVector": groundVector, "inputBVector": groundVector,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            .cropped(to: target)
        let radius = min(100.0, max(0.0, featherRadius))
        if radius > 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: target)
        }
        return try renderAlpha(image, width: info.width, height: info.height)
    }

    private static func blend(sky: inout [UInt16], ground: [UInt16], alpha: [Float], samplesPerPixel: Int) {
        let pixelCount = alpha.count
        let rows = max(1, pixelCount / max(1, 4096))
        sky.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: rows) { chunk in
                let start = chunk * (pixelCount / rows)
                let end = chunk == rows - 1 ? pixelCount : start + pixelCount / rows
                for pixel in start..<end {
                    let a = alpha[pixel]
                    guard a > 0 else { continue }
                    for sample in 0..<samplesPerPixel {
                        let i = pixel * samplesPerPixel + sample
                        let value = Float(output[i]) * (1 - a) + Float(ground[i]) * a
                        output[i] = UInt16(max(0, min(65535, value.rounded())))
                    }
                }
            }
        }
    }

    // MARK: - 現像（表示・プレビュー用）

    /// macOSのRAWエンジンの露出基準は、Camera Rawが同じ機種に使う値より 0.25EV 大きい
    /// （Canon EOS 6D: 0.25 → 0、EOS 6D Mark II: 0.5 → 0.25。Camera Rawで元RAWと並べて確認）。
    static let appleBaselineExposureOffset = 0.25

    /// 機種ごとの露出基準（DNGのBaselineExposure）。Adobeの機種別の値は取得できないため、
    /// macOSのRAWエンジンの値から推定する。DNGはファイル内の値がそのまま返るので補正しない。
    static func baselineExposure(for url: URL) -> Double {
        guard let filter = CIRAWFilter(imageURL: url) else { return 0 }
        let value = Double(filter.baselineExposure)
        return url.pathExtension.lowercased() == "dng" ? value : value - appleBaselineExposureOffset
    }

    /// 合成結果を一時DNGに書き、macOSのRAWエンジンで現像して表示用・プレビュー用の画像を作る。
    private static func render(
        kind: RawStackResult.Kind,
        pixels: [UInt16],
        info: RawSensorInfo,
        width: Int,
        height: Int,
        whiteLevel: Double,
        baselineExposure: Double
    ) throws -> (preview: CGImage, display: NSImage) {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStarStacker_render_\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let placeholder = try placeholderImage()
        let camera = info.cameraColorProfile(baselineExposure: baselineExposure)
        switch kind {
        case .bayer:
            try DNGWriter.writeBayer(pixels: pixels, width: width, height: height, mosaic: info.bayerMosaic,
                                     camera: camera, previewSource: placeholder, metadata: nil,
                                     embedLensProfile: false, to: temporaryURL)
        case .cameraRGB:
            try DNGWriter.writeCameraRGB(pixels: pixels, width: width, height: height, whiteLevel: whiteLevel,
                                         camera: camera, previewSource: placeholder, metadata: nil,
                                         embedLensProfile: false, to: temporaryURL)
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])
        let preview: CGImage
        if let filter = CIRAWFilter(imageURL: temporaryURL) {
            // プレビューはDNGの向き指定と二重に回転しないよう、センサーの向きのまま作る
            filter.orientation = .up
            if let sensorImage = filter.outputImage,
               Int(sensorImage.extent.width) == width, Int(sensorImage.extent.height) == height,
               let rendered = materialize(sensorImage, context: context, colorSpace: colorSpace) {
                preview = rendered
            } else {
                // macOSのRAWエンジンが本画像を現像できない場合（未対応機種など）はLibRawで現像する
                preview = try RawDecoder.renderSRGB(from: temporaryURL, exposure: baselineExposure)
            }
        } else {
            preview = try RawDecoder.renderSRGB(from: temporaryURL, exposure: baselineExposure)
        }

        let displayOrientation = CGImagePropertyOrientation(rawValue: UInt32(info.orientation)) ?? .up
        let oriented = CIImage(cgImage: preview).oriented(displayOrientation)
        let orientedExtent = oriented.extent
        guard let display = displayOrientation == .up ? preview
                : materialize(oriented, context: context, colorSpace: colorSpace) else {
            throw PipelineError(message: "表示用画像を作成できませんでした")
        }
        return (preview, NSImage(cgImage: display, size: NSSize(width: display.width, height: display.height)))
    }

    /// CIImage を今ここで16bit RGBAの画素に描画し、画素データを保持した CGImage にする。
    /// CIContext.createCGImage の結果は画素を読むときまで描画が遅延され、合成処理（バックグラウンド）が終わって
    /// RAWフィルタ等が解放された後に表示・書き出しで読むと真っ黒になるため使わない。
    private static func materialize(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace) -> CGImage? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 8, bounds: extent,
                           format: .RGBA16, colorSpace: colorSpace)
        }
        guard let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static func placeholderImage() throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else {
            throw PipelineError(message: "一時画像を作成できませんでした")
        }
        return image
    }
}

// MARK: - 補助型

/// 16bitのセンサー値のキャリブレーション（ダーク・バイアス減算、色ごとに正規化したフラット除算）。
/// 黒レベル（ペデスタル）は常に保持する: ダーク減算後に黒レベルを足し戻すので、黒付近のノイズが切り捨てられない。
struct BayerCalibrator {
    private let dark: [UInt16]?
    private let bias: [UInt16]?
    private let flatGain: [Float]?
    private let blacks: [Float]
    private let width: Int
    private let height: Int

    init(info: RawSensorInfo, dark: [UInt16]?, bias: [UInt16]?, flat: [UInt16]?) {
        self.dark = dark
        self.bias = bias
        self.blacks = info.blackLevels.map(Float.init)
        self.width = info.width
        self.height = info.height

        if let flat {
            // フラットはバイアス（無ければ黒レベル）を引き、センサーの色ごとの平均で正規化する
            var sums = [Double](repeating: 0, count: 3)
            var counts = [Int](repeating: 0, count: 3)
            var signal = [Float](repeating: 0, count: flat.count)
            for y in 0..<info.height {
                for x in 0..<info.width {
                    let i = y * info.width + x
                    let position = (y & 1) << 1 | (x & 1)
                    let offset = bias.map { Float($0[i]) } ?? Float(info.blackLevels[position])
                    let value = Float(flat[i]) - offset
                    signal[i] = value
                    if value > 0 {
                        let color = Int(info.cfaPattern[position])
                        sums[color] += Double(value)
                        counts[color] += 1
                    }
                }
            }
            let means = (0..<3).map { counts[$0] > 0 ? Float(sums[$0] / Double(counts[$0])) : 1 }
            for y in 0..<info.height {
                for x in 0..<info.width {
                    let i = y * info.width + x
                    let color = Int(info.cfaPattern[(y & 1) << 1 | (x & 1)])
                    let gain = signal[i] / means[color]
                    signal[i] = gain > 0.000_001 ? gain : 1
                }
            }
            flatGain = signal
        } else {
            flatGain = nil
        }
    }

    var isIdentity: Bool { dark == nil && bias == nil && flatGain == nil }

    func apply(to pixels: inout [UInt16]) {
        guard !isIdentity else { return }
        let width = self.width
        pixels.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let i = y * width + x
                    let black = blacks[(y & 1) << 1 | (x & 1)]
                    var value = Float(output[i])
                    if let dark {
                        value = value - Float(dark[i]) + black
                    } else if let bias {
                        value = value - Float(bias[i]) + black
                    }
                    if let flatGain {
                        value = (value - black) / flatGain[i] + black
                    }
                    output[i] = UInt16(max(0, min(65535, value.rounded())))
                }
            }
        }
    }
}

/// フレームを1枚ずつ受け取って合成する（平均・比較明はメモリを増やさない）。
final class StreamingStacker {
    /// 比較明合成で「どの単位でフレームを選ぶか」
    enum BrightGrouping {
        /// 値ごとに最大値を取る
        case samples
        /// ベイヤー配列の2x2ブロック（R・G・G・B）ごとに、重み付きの合計が最大のフレームのブロックをそのまま使う。
        /// weights は2x2の (0,0) (0,1) (1,0) (1,1) の位置の重み。
        case bayerBlocks(width: Int, height: Int, weights: [Float])
        /// RGBを並べた画素ごとに、重み付きの合計が最大のフレームの画素をそのまま使う
        case rgbPixels(weights: [Float])
    }

    private let mode: RawStackPipeline.Mode
    private let count: Int
    private let grouping: BrightGrouping
    /// ブロック・画素ごとの採用中フレームの明るさ
    private var bestScore: [Float] = []
    /// 16bit値を整数のまま積算する（Floatでは数百枚を超えると丸め誤差が出るため）
    private var sum: [UInt32] = []
    private var maximum: [UInt16] = []
    private var frames: [[UInt16]] = []
    private var added = 0

    init(mode: RawStackPipeline.Mode, count: Int, grouping: BrightGrouping = .samples) {
        self.mode = mode
        self.count = count
        self.grouping = grouping
    }

    func add(_ frame: [UInt16]) {
        precondition(frame.count == count, "合成するフレームの画素数が一致しません")
        added += 1
        switch mode {
        case .average:
            if sum.isEmpty { sum = [UInt32](repeating: 0, count: count) }
            let chunk = max(1, count / 64)
            sum.withUnsafeMutableBufferPointer { output in
                frame.withUnsafeBufferPointer { input in
                    DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { part in
                        let end = min(count, (part + 1) * chunk)
                        for i in (part * chunk)..<end {
                            output[i] &+= UInt32(input[i])
                        }
                    }
                }
            }
        case .compareBright:
            if case .bayerBlocks(let width, let height, let weights) = grouping {
                addBrightBayerBlocks(frame, width: width, height: height, weights: weights)
            } else if case .rgbPixels(let weights) = grouping {
                addBrightRGBPixels(frame, weights: weights)
            } else if maximum.isEmpty {
                maximum = frame
            } else {
                let chunk = max(1, count / 64)
                maximum.withUnsafeMutableBufferPointer { output in
                    frame.withUnsafeBufferPointer { input in
                        DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { part in
                            let end = min(count, (part + 1) * chunk)
                            for i in (part * chunk)..<end where input[i] > output[i] {
                                output[i] = input[i]
                            }
                        }
                    }
                }
            }
        case .median:
            frames.append(frame)
        }
    }

    func result() -> [UInt16] {
        guard added > 0 else { return [UInt16](repeating: 0, count: count) }
        switch mode {
        case .average:
            let divisor = UInt64(added)
            return sum.map { UInt16(min(65535, (UInt64($0) + divisor / 2) / divisor)) }
        case .compareBright:
            return maximum
        case .median:
            return median()
        }
    }

    private func addBrightBayerBlocks(_ frame: [UInt16], width: Int, height: Int, weights: [Float]) {
        precondition(width * height == count && weights.count == 4, "ベイヤー配列の寸法が一致しません")
        let blocksWide = width / 2, blocksHigh = height / 2
        let first = maximum.isEmpty
        if first {
            maximum = frame
            bestScore = [Float](repeating: -.greatestFiniteMagnitude, count: max(1, blocksWide * blocksHigh))
        }
        let w0 = weights[0], w1 = weights[1], w2 = weights[2], w3 = weights[3]
        maximum.withUnsafeMutableBufferPointer { output in
            bestScore.withUnsafeMutableBufferPointer { scores in
                frame.withUnsafeBufferPointer { input in
                    DispatchQueue.concurrentPerform(iterations: blocksHigh) { by in
                        let top = by * 2 * width, bottom = top + width
                        for bx in 0..<blocksWide {
                            let x = bx * 2
                            let score = w0 * Float(input[top + x]) + w1 * Float(input[top + x + 1])
                                + w2 * Float(input[bottom + x]) + w3 * Float(input[bottom + x + 1])
                            let blockIndex = by * blocksWide + bx
                            if first || score > scores[blockIndex] {
                                scores[blockIndex] = score
                                if !first {
                                    output[top + x] = input[top + x]
                                    output[top + x + 1] = input[top + x + 1]
                                    output[bottom + x] = input[bottom + x]
                                    output[bottom + x + 1] = input[bottom + x + 1]
                                }
                            }
                        }
                    }
                    // 奇数幅・奇数高さの端の列・行は2x2に収まらないため値ごとの最大値にする
                    guard !first else { return }
                    for y in 0..<height {
                        for x in 0..<width where (x >= blocksWide * 2 || y >= blocksHigh * 2) && input[y * width + x] > output[y * width + x] {
                            output[y * width + x] = input[y * width + x]
                        }
                    }
                }
            }
        }
    }

    private func addBrightRGBPixels(_ frame: [UInt16], weights: [Float]) {
        precondition(count % 3 == 0 && weights.count == 3, "RGBの画素数が一致しません")
        let pixelCount = count / 3
        let first = maximum.isEmpty
        if first {
            maximum = frame
            bestScore = [Float](repeating: -.greatestFiniteMagnitude, count: pixelCount)
        }
        let wr = weights[0], wg = weights[1], wb = weights[2]
        let chunk = max(1, pixelCount / 64)
        maximum.withUnsafeMutableBufferPointer { output in
            bestScore.withUnsafeMutableBufferPointer { scores in
                frame.withUnsafeBufferPointer { input in
                    DispatchQueue.concurrentPerform(iterations: (pixelCount + chunk - 1) / chunk) { part in
                        let end = min(pixelCount, (part + 1) * chunk)
                        for p in (part * chunk)..<end {
                            let i = p * 3
                            let score = wr * Float(input[i]) + wg * Float(input[i + 1]) + wb * Float(input[i + 2])
                            if first || score > scores[p] {
                                scores[p] = score
                                if !first {
                                    output[i] = input[i]
                                    output[i + 1] = input[i + 1]
                                    output[i + 2] = input[i + 2]
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func median() -> [UInt16] {
        let frameCount = frames.count
        guard frameCount > 1 else { return frames.first ?? [] }
        var output = [UInt16](repeating: 0, count: count)
        let chunk = max(1, count / 256)
        output.withUnsafeMutableBufferPointer { destination in
            DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { part in
                var values = [UInt16](repeating: 0, count: frameCount)
                let end = min(count, (part + 1) * chunk)
                for i in (part * chunk)..<end {
                    for f in 0..<frameCount { values[f] = frames[f][i] }
                    values.sort()
                    if frameCount % 2 == 0 {
                        destination[i] = UInt16((UInt32(values[frameCount / 2 - 1]) + UInt32(values[frameCount / 2]) + 1) / 2)
                    } else {
                        destination[i] = values[frameCount / 2]
                    }
                }
            }
        }
        return output
    }
}

/// 位置合わせの特徴点検出用に、カメラRGBを8bitの輝度画像へ変換する（全フレームで同じ明るさの基準を使う）。
struct GrayConverter {
    private let scale: Float

    init(base: CameraRGBFrame) {
        // 基準画像の明るい側（99.9%点）を白にし、暗い星空でも特徴点が拾えるよう持ち上げる
        let pixelCount = base.width * base.height
        let step = max(1, pixelCount / 200_000)
        var samples: [Float] = []
        samples.reserveCapacity(pixelCount / step + 1)
        var index = 0
        while index < pixelCount {
            let i = index * 3
            samples.append((Float(base.pixels[i]) + Float(base.pixels[i + 1]) + Float(base.pixels[i + 2])) / 3)
            index += step
        }
        samples.sort()
        let high = samples.isEmpty ? 65535 : samples[min(samples.count - 1, Int(Float(samples.count) * 0.999))]
        scale = 1 / max(high, 64)
    }

    func gray(_ frame: CameraRGBFrame) -> Data {
        let pixelCount = frame.width * frame.height
        var data = Data(count: pixelCount)
        let scale = self.scale
        data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            let out = output.bindMemory(to: UInt8.self)
            frame.pixels.withUnsafeBufferPointer { input in
                DispatchQueue.concurrentPerform(iterations: frame.height) { y in
                    for x in 0..<frame.width {
                        let p = y * frame.width + x
                        let luminance = (Float(input[p * 3]) + Float(input[p * 3 + 1]) + Float(input[p * 3 + 2])) / 3 * scale
                        // ガンマ 1/2.2 で暗部を持ち上げる
                        out[p] = UInt8(max(0, min(255, (pow(min(1, luminance), 1 / 2.2) * 255).rounded())))
                    }
                }
            }
        }
        return data
    }
}
