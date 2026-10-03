import Foundation
import AVFoundation
import AppKit
import CoreImage
import OpenCVWrapper

// MARK: - Timelapse Settings Model
struct TimelapseSettings {
    // ── Frame selection ───────────────────────────────────────────────
    var startFrame: Int = 0
    var endFrame: Int = 999         // updated to file count - 1 when files are loaded

    // ── Frame rate & duration ─────────────────────────────────────────
    var durationMode: DurationMode = .fps

    enum DurationMode: String, CaseIterable, Identifiable {
        case fps      = "FPS指定"
        case duration = "動画の長さ(秒)指定"
        var id: Self { self }
    }

    var fps: Double = 24.0
    var targetDuration: Double = 10.0       // Used when durationMode is .duration
    // ── Stabilization ─────────────────────────────────────────────────
    var alignment: FrameAlignment = .none

    /// 各フレームを何に合わせて位置合わせするか（どちらも最初のフレームに揃える）
    enum FrameAlignment: String, CaseIterable {
        case none   = "位置合わせなし"
        /// 地上の風景に合わせる。手ぶれ・三脚のずれ・追尾撮影で動く地上を止め、星は日周運動で動く
        case ground = "地上に合わせる（揺れ補正）"
        /// 星に合わせる。星空を止め、地上が回転する
        case stars  = "星に合わせる（星を固定）"
    }

    // ── Deflicker ─────────────────────────────────────────────────────
    var deflicker: Bool = false     // normalize per-frame luminance to reduce flicker

    // ── Tone / Stretch ────────────────────────────────────────────────
    /// 暗部を持ち上げる（補正量は最初のフレームの明るさの分布で決め、全フレームに同じ補正をかける）
    var autoStretch: Bool = false

    // ── Output resolution ─────────────────────────────────────────────
    var resolution: OutputResolution = .original

    enum OutputResolution: String, CaseIterable, Identifiable {
        case original  = "オリジナル"
        case r4k       = "4K (3840×2160)"
        case r1080p    = "1080p (1920×1080)"
        case r720p     = "720p (1280×720)"
        var id: Self { self }

        func size(for originalSize: CGSize) -> CGSize {
            switch self {
            case .original: return originalSize
            case .r4k:      return CGSize(width: 3840, height: 2160)
            case .r1080p:   return CGSize(width: 1920, height: 1080)
            case .r720p:    return CGSize(width: 1280, height: 720)
            }
        }
    }

    // ── Codec ─────────────────────────────────────────────────────────
    var codec: OutputCodec = .h264

    enum OutputCodec: String, CaseIterable, Identifiable {
        case h264  = "H.264 (.mp4)"
        case hevc  = "H.265/HEVC (.mp4)"
        var id: Self { self }

        var avCodec: AVVideoCodecType {
            switch self {
            // AVVideoCodecType.h264 / .hevc は macOS 10.13 以降のため、同じ値（avc1 / hvc1）を直接指定する
            case .h264: return AVVideoCodecType(rawValue: AVVideoCodecH264)
            case .hevc: return AVVideoCodecType(rawValue: "hvc1")
            }
        }

        /// このMacで書き出せるか。HEVCはハードウェアエンコーダーが必要で、2015年頃より前のMacでは使えない。
        var isAvailable: Bool {
            switch self {
            case .h264: return true
            case .hevc: return Self.isHEVCEncodingAvailable
            }
        }

        /// HEVC の書き出しは macOS 10.13 以降（さらにハードウェアエンコーダーが必要）
        private static let isHEVCEncodingAvailable: Bool = {
            guard #available(macOS 10.13, *) else { return false }
            return AVOutputSettingsAssistant.availableOutputSettingsPresets().contains(.hevc1920x1080)
        }()
    }

    // ── Computed helpers ──────────────────────────────────────────────
    var effectiveFrameCount: Int { max(1, endFrame - startFrame + 1) }

    var effectiveFps: Double {
        switch durationMode {
        case .fps: return min(120.0, max(1.0, fps))
        case .duration:
            return min(120.0, max(1.0, Double(effectiveFrameCount) / max(1.0, targetDuration)))
        }
    }

    var estimatedDuration: Double {
        Double(effectiveFrameCount) / effectiveFps
    }
}

// MARK: - TimelapseExporter (macOS 14+)
class TimelapseExporter {

    struct ExportError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func export(
        imageFiles: [ImageFile],
        settings: TimelapseSettings,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedFileTypes = ["mp4"]
            panel.nameFieldStringValue = "MacStarStacker_Timelapse.mp4"
            panel.begin { response in
                guard response == .OK, let url = panel.url else {
                    completion(.failure(ExportError(message: "キャンセルされました")))
                    return
                }
                
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try renderTimelapse(
                            imageFiles: imageFiles,
                            settings: settings,
                            outputURL: url,
                            progress: progress
                        )
                        DispatchQueue.main.async {
                            completion(.success(url))
                        }
                    } catch {
                        DispatchQueue.main.async {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Core render function
    static func renderTimelapse(
        imageFiles: [ImageFile],
        settings: TimelapseSettings,
        outputURL: URL,
        progress: @escaping (Double, String) -> Void
    ) throws {
        let start = max(0, settings.startFrame)
        let end   = min(imageFiles.count - 1, settings.endFrame)
        guard start <= end else {
            throw ExportError(message: "フレーム範囲が無効です")
        }

        let selectedFiles = Array(imageFiles[start...end])
        let total = selectedFiles.count

        var refLuminance: Double? = nil
        if settings.deflicker,
           let firstImg = ImageLoader.load(from: selectedFiles[0].url) {
            refLuminance = averageLuminance(of: firstImg)
        }

        guard let firstNS = ImageLoader.load(from: selectedFiles[0].url),
              let firstCG = firstNS.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError(message: "最初の画像を読み込めませんでした")
        }
        let origSize = CGSize(width: firstCG.width, height: firstCG.height)
        let outSize  = settings.resolution.size(for: origSize)
        // H.264 / HEVC が要求する偶数サイズへ丸める。
        let outWidth  = max(2, Int(outSize.width).isMultiple(of: 2) ? Int(outSize.width) : Int(outSize.width) - 1)
        let outHeight = max(2, Int(outSize.height).isMultiple(of: 2) ? Int(outSize.height) : Int(outSize.height) - 1)
        guard settings.codec.isAvailable else {
            throw ExportError(message: "このMacはHEVCの書き出しに対応していません。H.264を選択してください")
        }
        if settings.codec == .hevc, outWidth < 320 || outHeight < 240 {
            throw ExportError(message: "HEVC書き出しには320×240以上の解像度が必要です")
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec.avCodec.rawValue,
            AVVideoWidthKey:  outWidth,
            AVVideoHeightKey: outHeight
        ]
        if settings.codec == .h264 {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(1_000_000, outWidth * outHeight * 4),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:  outWidth,
                kCVPixelBufferHeightKey as String: outHeight
            ]
        )
        guard writer.canAdd(input) else {
            throw ExportError(message: "選択したコーデックをこのMacで利用できません")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ExportError(message: "動画エンコーダーを開始できませんでした")
        }
        writer.startSession(atSourceTime: .zero)
        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }

        let tFps = max(1.0, settings.effectiveFps)
        let frameDuration = CMTime(seconds: 1.0 / tFps, preferredTimescale: 60_000)

        // 隣り合うフレームを順に合わせて、最初のフレームに揃える
        let stabilizer: TimelapseFrameAligner?
        switch settings.alignment {
        case .none:   stabilizer = nil
        case .ground: stabilizer = TimelapseStabilizer()
        case .stars:  stabilizer = StarTimelapseAligner()
        }
        let identity: [NSNumber] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        var stretchParameters: AutoStretch.Parameters?

        for (idx, file) in selectedFiles.enumerated() {
            DispatchQueue.main.async {
                progress(Double(idx) / Double(total), "フレームを処理中 (\(idx+1)/\(total))...")
            }

            guard var nsImage = ImageLoader.load(from: file.url) else {
                throw ExportError(message: "画像を読み込めませんでした: \(file.name)")
            }

            // フリッカー除去の明るさは、位置合わせで画像の端が黒くなる前の元画像で測る
            var deflickerFactor: Double?
            if settings.deflicker, let ref = refLuminance {
                let lum = averageLuminance(of: nsImage)
                if lum > 0.001 { deflickerFactor = ref / lum }
            }

            // 位置合わせは明るさを持ち上げる前の元画像で行う（オートストレッチ後は夜空のノイズが強まり、
            // 地上の模様の中の点を星と取り違えやすくなるため）
            if let stabilizer {
                guard let targetURL = writeTemporaryTIFF(nsImage, prefix: "timelapse_align") else {
                    throw ExportError(message: "位置合わせ用画像を準備できませんでした: \(file.name)")
                }
                defer { try? FileManager.default.removeItem(at: targetURL) }
                let homography = try stabilizer.homographyForImage(at: targetURL)
                if homography != identity {
                    nsImage = try ImageAligner.warpImage(at: targetURL, homography: homography)
                }
            }

            if let deflickerFactor {
                nsImage = scaleLuminance(image: nsImage, factor: deflickerFactor) ?? nsImage
            }

            if settings.autoStretch, let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // フレームごとに補正量を変えると明るさがちらつくため、最初のフレームで決めた補正を使い続ける
                let parameters = stretchParameters ?? AutoStretch.parameters(for: cgImage)
                stretchParameters = parameters
                if let stretched = AutoStretch.apply(parameters, to: cgImage) {
                    nsImage = NSImage(cgImage: stretched, size: nsImage.size)
                }
            }

            guard let pixelBuffer = pixelBuffer(
                from: nsImage, width: outWidth, height: outHeight
            ) else {
                throw ExportError(message: "動画フレームを生成できませんでした: \(file.name)")
            }

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(idx))

            let readyDeadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < readyDeadline {
                Thread.sleep(forTimeInterval: 0.005) // 5ms
            }
            guard writer.status == .writing, input.isReadyForMoreMediaData else {
                throw writer.error ?? ExportError(message: "動画エンコーダーが応答しませんでした")
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? ExportError(message: "動画フレームの追加に失敗しました")
            }
        }

        input.markAsFinished()
        
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 120) == .success else {
            throw ExportError(message: "動画の完了処理がタイムアウトしました")
        }

        if writer.status != .completed {
            throw writer.error ?? ExportError(message: "書き出しに失敗しました")
        }

        let failed = stabilizer?.failedFrameCount ?? 0
        DispatchQueue.main.async {
            progress(1.0, failed > 0
                ? "✅ タイムラプス書き出し完了（\(failed)フレームは位置合わせできず、そのまま使用）"
                : "✅ タイムラプス書き出し完了！")
        }
    }

    // MARK: - Image processing helpers

    private static func averageLuminance(of image: NSImage) -> Double {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0.5 }
        let w = min(cg.width, 256), h = min(cg.height, 256)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum: Double = 0
        let count = w * h
        for i in 0..<count {
            let r = Double(pixels[i*4])
            let g = Double(pixels[i*4+1])
            let b = Double(pixels[i*4+2])
            sum += (0.299*r + 0.587*g + 0.114*b) / 255.0
        }
        return sum / Double(count)
    }

    private static func scaleLuminance(image: NSImage, factor: Double) -> NSImage? {
        guard let ci = CIImage(data: image.tiffRepresentation ?? Data()) else { return nil }
        guard let filter = CIFilter(name: "CIExposureAdjust") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        let clampedFactor = min(max(factor, 0.25), 4.0)
        filter.setValue(log2(clampedFactor), forKey: kCIInputEVKey)
        guard let out = filter.outputImage else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: image.size)
    }


    private static func pixelBuffer(from image: NSImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: base, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = ctx else { return nil }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(cg.width), CGFloat(height) / CGFloat(cg.height))
        let drawSize = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let drawRect = CGRect(
            x: (CGFloat(width) - drawSize.width) / 2,
            y: (CGFloat(height) - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        ctx.draw(cg, in: drawRect)
        return buffer
    }

    private static func writeTemporaryTIFF(_ image: NSImage, prefix: String) -> URL? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .tiff, properties: [:]) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStarStacker_\(prefix)_\(UUID().uuidString).tiff")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - フレームの位置合わせ

/// タイムラプスの各フレームを、最初のフレームに揃える変換を順に求める
protocol TimelapseFrameAligner: AnyObject {
    /// 次のフレームを最初のフレームに揃える 3x3 ホモグラフィ（行優先9要素）
    func homographyForImage(at url: URL) throws -> [NSNumber]
    /// 位置合わせできず、前のフレームと同じ変換にしたフレームの数
    var failedFrameCount: Int { get }
}

/// 地上の風景に合わせる（星の周りを除いた特徴点で、隣のフレームと順に合わせる）
extension TimelapseStabilizer: TimelapseFrameAligner {}

/// 星に合わせる。直前に星が見つかったフレームとの星の対応を順に積み重ねて、最初のフレームの星の位置に揃える。
/// 数時間で星空が大きく回っても、隣のフレームとの差は小さいため合わせられる。
final class StarTimelapseAligner: TimelapseFrameAligner {
    /// 星が見つかった直前のフレームと、そのフレームを最初のフレームに揃える変換
    private var reference: (aligner: StarAligner, homography: [Double])?
    /// 直前の隣り合うフレーム間の変換（次のフレームの初期値にする）
    private var lastStep: [NSNumber]?
    private(set) var failedFrameCount = 0

    func homographyForImage(at url: URL) throws -> [NSNumber] {
        // 雲や薄明で星が見つからないフレームは基準にしない（次のフレームは、その前の星のあるフレームに合わせる）
        let aligner = try? StarAligner(baseImageAt: url, skyMask: nil)
        var current: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        if let reference {
            current = reference.homography
            if let step = try? reference.aligner.homographyForImage(at: url, initialGuess: lastStep) {
                current = Self.multiply(reference.homography, step.map(\.doubleValue))
                lastStep = step
            } else {
                failedFrameCount += 1
            }
        }
        if let aligner {
            reference = (aligner, current)
        }
        return current.map { NSNumber(value: $0) }
    }

    /// 行優先の 3x3 行列の積 a * b（b を先に適用する）
    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for col in 0..<3 {
                var sum = 0.0
                for k in 0..<3 {
                    sum += a[row * 3 + k] * b[k * 3 + col]
                }
                result[row * 3 + col] = sum
            }
        }
        return result
    }
}
