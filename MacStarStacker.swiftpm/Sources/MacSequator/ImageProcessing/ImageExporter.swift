import Foundation
import AppKit
import UniformTypeIdentifiers

/// スタック後の画像を指定フォーマットで書き出すクラス
class ImageExporter {

    struct ExportError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case dng    = "RAW (DNG)"
        case tiff16 = "16bit TIFF"
        case fits32 = "32bit FITS"
        case jpeg   = "High Quality JPEG"
        var id: Self { self }

        var fileExtension: String {
            switch self {
            case .dng:    return "dng"
            case .tiff16: return "tiff"
            case .fits32: return "fits"
            case .jpeg:   return "jpg"
            }
        }
    }

    /// 保存ダイアログを表示して画像をエクスポートする
    static func export(
        image: NSImage,
        format: ExportFormat,
        metadata: RawMetadataInfo? = nil,
        embedLensProfile: Bool = true,
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            if let contentType = UTType(filenameExtension: format.fileExtension) {
                panel.allowedContentTypes = [contentType]
            }
            panel.nameFieldStringValue = "stacked_result.\(format.fileExtension)"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<URL, Error>
                    do {
                        try write(
                            image: image, format: format, metadata: metadata,
                            embedLensProfile: embedLensProfile, to: url
                        )
                        result = .success(url)
                    } catch {
                        result = .failure(error)
                    }
                    DispatchQueue.main.async {
                        completion?(result)
                        if completion == nil, case .failure(let error) = result {
                            let alert = NSAlert(error: error)
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }

    /// UIを介さず指定URLへ書き出す。自動テストと一括処理でも使用する。
    static func write(
        image: NSImage,
        format: ExportFormat,
        metadata: RawMetadataInfo? = nil,
        embedLensProfile: Bool = true,
        to url: URL
    ) throws {
        switch format {
        case .dng:
            try DNGWriter.write(image: image, metadata: metadata, embedLensProfile: embedLensProfile, to: url)
        case .tiff16:
            try save16bitTIFF(image: image, metadata: metadata, to: url)
        case .fits32:
            try save32bitFITS(image: image, to: url)
        case .jpeg:
            try saveJPEG(image: image, to: url)
        }
    }

    // MARK: - DNG (16-bit Linear DNG with Lens Profile)
    // MARK: - 16bit TIFF
    private static func save16bitTIFF(image: NSImage, metadata: RawMetadataInfo?, to url: URL) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError(message: "TIFF用画像を取得できませんでした")
        }

        let width = cgImage.width
        let height = cgImage.height

        // 16bpc RGBカラースペースで描画
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        let bytesPerRow = width * 8 // 4チャンネル * 2バイト

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue
        ) else { throw ExportError(message: "16bit TIFFの描画領域を作成できませんでした") }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rendered = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: rendered).representation(using: .tiff, properties: [:]) else {
            throw ExportError(message: "16bit TIFFデータを生成できませんでした")
        }
        try data.write(to: url, options: .atomic)

        // ExifToolが存在する場合はメタデータをTIFFにも同期
        if let meta = metadata, let src = meta.sourceURL, let exiftool = RawMetadataExtractor.findExiftool() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exiftool)
            process.arguments = ["-tagsFromFile", src.path, "-all:all>all:all", "-overwrite_original", url.path]
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - 32bit FITS
    /// Writes a minimal monochrome FITS file (grayscale luminance, float32 per pixel).
    private static func save32bitFITS(image: NSImage, to url: URL) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError(message: "FITS用画像を取得できませんでした")
        }
        let width = cgImage.width
        let height = cgImage.height

        // リニア32bit浮動小数点グレースケールへ直接描画し、16bit入力の階調を保持する。
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var gray = [Float](repeating: 0, count: width * height)
        let rendered = gray.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let ctx = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 32,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ExportError(message: "FITS用画素データを生成できませんでした") }

        // Build a minimal valid FITS header (36 header cards, each 80 bytes = 2880-byte block)
        let naxis1 = width
        let naxis2 = height
        var headerCards: [String] = [
            fitsCard("SIMPLE",  "T",                 "/ conforms to FITS standard"),
            fitsCard("BITPIX",  "-32",               "/ 32-bit float"),
            fitsCard("NAXIS",   "2",                 "/ 2D image"),
            fitsCard("NAXIS1",  String(naxis1),      "/ axis 1 length (width)"),
            fitsCard("NAXIS2",  String(naxis2),      "/ axis 2 length (height)"),
            fitsCard("BSCALE",  "1.0",               "/ data scale factor"),
            fitsCard("BZERO",   "0.0",               "/ data zero offset"),
            fitsCard("CREATOR", "'MacStarStacker'",  "/ software"),
            "END" + String(repeating: " ", count: 77)
        ]
        // Pad header to multiple of 2880 bytes
        while (headerCards.count * 80) % 2880 != 0 {
            headerCards.append(String(repeating: " ", count: 80))
        }

        var data = Data()
        for card in headerCards {
            data.append(contentsOf: Array(card.utf8))
        }

        // FITS pixels: big-endian Float32. FITS stores bottom-left first, so flip vertically.
        for row in stride(from: height - 1, through: 0, by: -1) {
            for col in 0..<width {
                let pixelValue = gray[row * width + col]
                var bigEndian = pixelValue.bitPattern.bigEndian
                withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
            }
        }

        // Pad data to multiple of 2880 bytes
        let remainder = data.count % 2880
        if remainder != 0 {
            data.append(contentsOf: [UInt8](repeating: 0, count: 2880 - remainder))
        }

        try data.write(to: url, options: .atomic)
    }

    // MARK: - JPEG
    private static func saveJPEG(image: NSImage, to url: URL) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError(message: "JPEG用画像を取得できませんでした")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
            throw ExportError(message: "JPEGデータを生成できませんでした")
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - FITS Helper
    private static func fitsCard(_ keyword: String, _ value: String, _ comment: String) -> String {
        let kw = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
        let entry = "\(kw)= \(value) \(comment)"
        return entry.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
