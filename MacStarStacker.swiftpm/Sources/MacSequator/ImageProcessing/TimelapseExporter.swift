import Foundation
import AVFoundation
import AppKit
import CoreImage
import OpenCVWrapper
import UniformTypeIdentifiers

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
    var alignFrames: Bool = false           // align each frame to base for stabilization

    // ── Deflicker ─────────────────────────────────────────────────────
    var deflicker: Bool = false     // normalize per-frame luminance to reduce flicker

    // ── Tone / Stretch ────────────────────────────────────────────────
    var autoStretch: Bool = false   // apply gamma + exposure to each frame for preview-quality output
    var gamma: Double = 0.45
    var exposure: Double = 1.0      // EV boost

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
            case .h264: return .h264
            case .hevc:
                if #available(macOS 10.13, *) {
                    return .hevc
                } else {
                    return .h264
                }
            }
        }
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
        baseFile: ImageFile?,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
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
                            baseFile: baseFile,
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
        baseFile: ImageFile?,
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

        var baseReferenceURL: URL?
        if settings.alignFrames, let baseFile = baseFile {
            guard let baseImage = ImageLoader.load(from: baseFile.url),
                  let tempURL = writeTemporaryTIFF(baseImage, prefix: "timelapse_base") else {
                throw ExportError(message: "位置合わせの基準画像を準備できませんでした")
            }
            baseReferenceURL = tempURL
        }
        defer {
            if let baseReferenceURL = baseReferenceURL {
                try? FileManager.default.removeItem(at: baseReferenceURL)
            }
        }

        for (idx, file) in selectedFiles.enumerated() {
            DispatchQueue.main.async {
                progress(Double(idx) / Double(total), "フレームを処理中 (\(idx+1)/\(total))...")
            }

            guard var nsImage = ImageLoader.load(from: file.url) else {
                throw ExportError(message: "画像を読み込めませんでした: \(file.name)")
            }

            if settings.deflicker, let ref = refLuminance {
                let lum = averageLuminance(of: nsImage)
                if lum > 0.001 {
                    nsImage = scaleLuminance(image: nsImage, factor: ref / lum) ?? nsImage
                }
            }

            if settings.autoStretch {
                nsImage = applyStretch(to: nsImage, gamma: settings.gamma, ev: settings.exposure) ?? nsImage
            }

            if settings.alignFrames,
               let base = baseFile,
               let referenceURL = baseReferenceURL,
               file.url != base.url {
                guard let targetURL = writeTemporaryTIFF(nsImage, prefix: "timelapse_align") else {
                    throw ExportError(message: "位置合わせ用画像を準備できませんでした: \(file.name)")
                }
                defer { try? FileManager.default.removeItem(at: targetURL) }
                let aligned = try ImageAligner.alignImage(at: targetURL, toBaseImageAt: referenceURL)
                nsImage = aligned
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

        DispatchQueue.main.async {
            progress(1.0, "✅ タイムラプス書き出し完了！")
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

    private static func applyStretch(to image: NSImage, gamma: Double, ev: Double) -> NSImage? {
        guard let ci = CIImage(data: image.tiffRepresentation ?? Data()) else { return nil }
        guard let g = CIFilter(name: "CIGammaAdjust") else { return nil }
        g.setValue(ci, forKey: kCIInputImageKey)
        g.setValue(Float(gamma), forKey: "inputPower")
        guard let gOut = g.outputImage else { return nil }
        
        guard let e = CIFilter(name: "CIExposureAdjust") else { return nil }
        e.setValue(gOut, forKey: kCIInputImageKey)
        e.setValue(Float(ev), forKey: "inputEV")
        guard let out = e.outputImage else { return nil }
        
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
