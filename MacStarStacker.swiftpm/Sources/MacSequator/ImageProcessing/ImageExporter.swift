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
        rawResult: RawStackResult? = nil,
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
                            embedLensProfile: embedLensProfile, rawResult: rawResult, to: url
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
        rawResult: RawStackResult? = nil,
        to url: URL
    ) throws {
        switch format {
        case .dng:
            if let rawResult {
                // RAWのまま合成した結果は、センサーデータ（ベイヤー配列／カメラ色空間RGB）のままDNGにする
                try rawResult.writeDNG(metadata: metadata, embedLensProfile: embedLensProfile, to: url)
            } else {
                try DNGWriter.write(image: image, metadata: metadata, embedLensProfile: embedLensProfile, to: url)
            }
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

        // ExifToolが存在する場合は撮影情報をTIFFにも同期（Orientation等の構造タグはコピーしない）
        if let src = metadata?.sourceURL {
            RawMetadataExtractor.copyShootingMetadata(from: src, to: url, extraArguments: ["-EXIF:Make", "-EXIF:Model"])
        }
    }

    // MARK: - 32bit FITS
    /// RGBカラーの32bit浮動小数点FITSを書き出す（NAXIS=3, NAXIS3=3）。
    /// 画素はリニアsRGBの0〜1で、R・G・B各プレーンを順に格納する（Siril / PixInsight 等と同じ並び）。
    private static func save32bitFITS(image: NSImage, to url: URL) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError(message: "FITS用画像を取得できませんでした")
        }
        let width = cgImage.width
        let height = cgImage.height
        let planePixels = width * height

        // リニア32bit浮動小数点RGBへ直接描画し、16bit入力の階調とカラーを保持する。
        // FITS読み込み側（ImageLoader）もリニアsRGBとして解釈するため、往復で値が変わらない。
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        var rgba = [Float](repeating: 0, count: planePixels * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let ctx = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 32,
                    bytesPerRow: width * 16,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ExportError(message: "FITS用画素データを生成できませんでした") }

        // FITSヘッダ（80バイトのカードを2880バイト単位のブロックに詰める）
        var headerCards: [String] = [
            fitsCard("SIMPLE",   "T",                 "/ conforms to FITS standard"),
            fitsCard("BITPIX",   "-32",               "/ 32-bit float"),
            fitsCard("NAXIS",    "3",                 "/ RGB color cube"),
            fitsCard("NAXIS1",   String(width),       "/ axis 1 length (width)"),
            fitsCard("NAXIS2",   String(height),      "/ axis 2 length (height)"),
            fitsCard("NAXIS3",   "3",                 "/ color planes (R, G, B)"),
            fitsCard("BSCALE",   "1.0",               "/ data scale factor"),
            fitsCard("BZERO",    "0.0",               "/ data zero offset"),
            fitsCard("DATAMIN",  "0.0",               "/ minimum data value"),
            fitsCard("DATAMAX",  "1.0",               "/ maximum data value"),
            fitsCard("CTYPE3",   "'RGB     '",        "/ plane order: red, green, blue"),
            fitsCard("ROWORDER", "'BOTTOM-UP'",       "/ first row is the bottom of the image"),
            fitsCard("CREATOR",  "'MacStarStacker'",  "/ software"),
            "END" + String(repeating: " ", count: 77)
        ]
        while (headerCards.count * 80) % 2880 != 0 {
            headerCards.append(String(repeating: " ", count: 80))
        }

        var data = Data()
        data.reserveCapacity(headerCards.count * 80 + planePixels * 3 * 4 + 2880)
        for card in headerCards {
            data.append(contentsOf: Array(card.utf8))
        }

        // 画素はビッグエンディアンFloat32。FITSは左下原点なので各プレーン内で上下反転する。
        var plane = [UInt8](repeating: 0, count: planePixels * 4)
        for channel in 0..<3 {
            var outputIndex = 0
            for row in stride(from: height - 1, through: 0, by: -1) {
                let rowStart = row * width
                for col in 0..<width {
                    let value = min(1, max(0, rgba[(rowStart + col) * 4 + channel]))
                    let bits = value.bitPattern
                    plane[outputIndex]     = UInt8(truncatingIfNeeded: bits >> 24)
                    plane[outputIndex + 1] = UInt8(truncatingIfNeeded: bits >> 16)
                    plane[outputIndex + 2] = UInt8(truncatingIfNeeded: bits >> 8)
                    plane[outputIndex + 3] = UInt8(truncatingIfNeeded: bits)
                    outputIndex += 4
                }
            }
            data.append(contentsOf: plane)
        }

        // データ部も2880バイト単位にパディング
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
        // FITS固定書式: 文字列は11桁目から、数値・論理値は30桁目に右詰めで書く。
        let formattedValue = value.hasPrefix("'")
            ? value.padding(toLength: max(20, value.count), withPad: " ", startingAt: 0)
            : String(repeating: " ", count: max(0, 20 - value.count)) + value
        let entry = "\(kw)= \(formattedValue) \(comment)"
        return entry.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
