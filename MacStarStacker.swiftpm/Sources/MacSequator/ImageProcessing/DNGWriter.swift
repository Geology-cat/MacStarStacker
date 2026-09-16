import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// DNG 1.4互換の16-bitリニアDNG (Linear RAW) を書き出すライター
///
/// ファイル構成はAdobe製のリニアDNG（Lightroomの「強化」出力等）に合わせる。
/// - IFD0: 256px 8bit sRGBサムネイル + カメラプロファイル等のDNG共通タグ
/// - SubIFD[0]: 主画像（16bit LinearRaw, NewSubFileType=0）
/// - SubIFD[1]: 長辺1024pxのJPEGプレビュー（NewSubFileType=1, PreviewColorSpace=sRGB）
///
/// スタック結果はデモザイク・トーン処理済みの画像なので、Camera Raw / Lightroom で開いたときに
/// アプリ上の表示と同じ色調・階調になるよう、無変換（sRGB原色・リニアトーン）のカメラプロファイルを埋め込む。
public enum DNGWriter {

    /// 埋め込みカメラプロファイル名（Camera Raw / Lightroom のプロファイル欄に表示される）
    static let embeddedProfileName = "MacStarStacker Linear sRGB"
    /// Adobeのカメラ別プロファイル（実センサー用の色変換）が選ばれないよう、実在カメラと重ならない名前にする。
    /// 実カメラ名はMake/Modelタグに残すので、レンズプロファイルの照合や撮影情報の表示には影響しない。
    static let uniqueCameraModel = "MacStarStacker Linear sRGB"
    static let thumbnailMaxSide = 256
    static let previewMaxSide = 1024
    /// 1ストリップあたりの目安サイズ。巨大な単一ストリップは一部の読み込み側で扱えないため分割する。
    private static let targetStripBytes = 8 * 1024 * 1024

    /// 16-bit リニアDNGを生成してファイルに保存する
    /// - Parameters:
    ///   - image: 保存対象のNSImage
    ///   - metadata: RAW画像から抽出されたメタデータおよびレンズ情報
    ///   - embedLensProfile: レンズプロファイル（XMP / EXIFタグ / 補正フラグ）を埋め込むかどうか
    ///   - url: 出力先URL
    public static func write(
        image: NSImage,
        metadata: RawMetadataInfo?,
        embedLensProfile: Bool = true,
        to url: URL
    ) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw writerError(1, "CGImageの取得に失敗しました")
        }

        // 主画像（16bitリニアsRGB）、サムネイル（8bit sRGB）、プレビュー（JPEG）を用意する。
        let main = MainImage(
            kind: .linearSRGB,
            data: try renderLinearRGB16(cgImage),
            width: cgImage.width,
            height: cgImage.height
        )
        try writeDNG(main: main, previewSource: cgImage, metadata: metadata, embedLensProfile: embedLensProfile, to: url)
    }

    /// RAWを現像せずにベイヤー配列のまま合成した結果をDNGに書き出す。
    /// - Parameters:
    ///   - pixels: 有効画素領域の生の値（黒レベル込み、width * height 要素）
    ///   - previewSource: サムネイル・プレビュー用の現像済み画像（センサーの向きのまま、回転しない）
    static func writeBayer(
        pixels: [UInt16],
        width: Int,
        height: Int,
        mosaic: BayerMosaic,
        camera: CameraColorProfile,
        previewSource: CGImage,
        metadata: RawMetadataInfo?,
        embedLensProfile: Bool = true,
        to url: URL
    ) throws {
        precondition(pixels.count == width * height, "ベイヤー配列の画素数が一致しません")
        let main = MainImage(kind: .bayer(mosaic, camera), data: littleEndianData(pixels), width: width, height: height)
        try writeDNG(main: main, previewSource: previewSource, metadata: metadata, embedLensProfile: embedLensProfile, to: url)
    }

    /// カメラ色空間のままデモザイクして合成した16bitリニアRGBをDNGに書き出す。
    /// - Parameters:
    ///   - pixels: RGBインターリーブ（黒レベル除去済み、ホワイトバランスなし、width * height * 3 要素）
    ///   - whiteLevel: センサーの飽和に相当する値（LibRawの出力は65535より低くなる）
    ///   - previewSource: サムネイル・プレビュー用の現像済み画像（センサーの向きのまま、回転しない）
    static func writeCameraRGB(
        pixels: [UInt16],
        width: Int,
        height: Int,
        whiteLevel: Double = 65535,
        camera: CameraColorProfile,
        previewSource: CGImage,
        metadata: RawMetadataInfo?,
        embedLensProfile: Bool = true,
        to url: URL
    ) throws {
        precondition(pixels.count == width * height * 3, "カメラRGBの画素数が一致しません")
        let main = MainImage(kind: .cameraRGB(camera, whiteLevel: whiteLevel), data: littleEndianData(pixels), width: width, height: height)
        try writeDNG(main: main, previewSource: previewSource, metadata: metadata, embedLensProfile: embedLensProfile, to: url)
    }

    private static func writeDNG(
        main: MainImage,
        previewSource: CGImage,
        metadata: RawMetadataInfo?,
        embedLensProfile: Bool,
        to url: URL
    ) throws {
        let meta = metadata ?? RawMetadataInfo()
        let thumbnail = try renderSRGB8(previewSource, maxSide: thumbnailMaxSide)
        let preview = try renderJPEGPreview(previewSource, maxSide: previewMaxSide)

        let dngData = buildDNGData(
            main: main,
            thumbnail: thumbnail,
            preview: preview,
            metadata: meta,
            embedLensProfile: embedLensProfile
        )
        try dngData.write(to: url, options: .atomic)

        // ExifToolと元RAWがある場合は、撮影情報タグだけを追加でコピーする。
        if embedLensProfile, let sourceURL = meta.sourceURL {
            RawMetadataExtractor.copyShootingMetadata(
                from: sourceURL,
                to: url,
                extraArguments: lensOverrideArguments(metadata: meta)
            )
        }
    }

    private static func littleEndianData(_ values: [UInt16]) -> Data {
        var data = Data(count: values.count * 2)
        data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            let out = output.bindMemory(to: UInt16.self)
            for index in values.indices { out[index] = values[index].littleEndian }
        }
        return data
    }

    private static func writerError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "MacStarStacker.DNGWriter", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - 主画像とカメラプロファイル

    /// ベイヤー配列の並びとレベル（生の値）
    struct BayerMosaic {
        /// 左上 (0,0) (0,1) (1,0) (1,1) の色。0=R, 1=G, 2=B
        let pattern: [UInt8]
        /// pattern と同じ並びの黒レベル
        let blackLevels: [Double]
        let whiteLevel: Double
    }

    /// 実カメラの色情報。Adobeのカメラ別プロファイルがそのまま適用されるよう実カメラ名で書き出す。
    struct CameraColorProfile {
        let make: String
        let model: String
        /// Adobeのプロファイルと照合される名前（例: "Canon EOS 6D"）
        let uniqueCameraModel: String
        /// XYZ → カメラRGB
        let colorMatrix1: [Double]
        let illuminant1: Int
        let colorMatrix2: [Double]?
        let illuminant2: Int
        let asShotNeutral: [Double]
        let orientation: UInt16
        /// 機種ごとの露出基準の補正（EV）。Adobe製DNGと同じくIFD0のBaselineExposureに書く。
        var baselineExposure: Double = 0
    }

    private enum MainImageKind {
        /// 現像済みのリニアsRGB（無変換プロファイルでアプリ表示と同じ見た目にする）
        case linearSRGB
        /// ベイヤー配列の生データ
        case bayer(BayerMosaic, CameraColorProfile)
        /// カメラ色空間のままデモザイクしたリニアRGB
        case cameraRGB(CameraColorProfile, whiteLevel: Double)

        var samplesPerPixel: Int {
            if case .bayer = self { return 1 }
            return 3
        }

        var camera: CameraColorProfile? {
            switch self {
            case .linearSRGB: return nil
            case .bayer(_, let camera), .cameraRGB(let camera, _): return camera
            }
        }
    }

    private struct MainImage {
        let kind: MainImageKind
        /// リトルエンディアン16bit
        let data: Data
        let width: Int
        let height: Int
    }

    // MARK: - 画素データの生成

    private struct RGB8Image {
        let pixels: Data
        let width: Int
        let height: Int
    }

    private struct JPEGPreview {
        let data: Data
        let width: Int
        let height: Int
        let subsampling: (horizontal: UInt16, vertical: UInt16)
    }

    /// リニアsRGBへ色変換して16bit RGB（リトルエンディアン、アルファなし）を取り出す。
    /// アプリ内のスタック結果もリニアsRGBで保持しているため、通常は無変換で値がそのまま入る。
    private static func renderLinearRGB16(_ cgImage: CGImage) throws -> Data {
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        var rgba = [UInt16](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 16,
                    bytesPerRow: width * 8,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                  ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw writerError(2, "CGContextの生成に失敗しました") }

        var rgb = Data(count: width * height * 6)
        rgb.withUnsafeMutableBytes { output in
            let out = output.bindMemory(to: UInt16.self)
            rgba.withUnsafeBufferPointer { input in
                for pixel in 0..<(width * height) {
                    out[pixel * 3] = input[pixel * 4].littleEndian
                    out[pixel * 3 + 1] = input[pixel * 4 + 1].littleEndian
                    out[pixel * 3 + 2] = input[pixel * 4 + 2].littleEndian
                }
            }
        }
        return rgb
    }

    private static func scaledSize(width: Int, height: Int, maxSide: Int) -> (Int, Int) {
        let scale = min(1.0, Double(maxSide) / Double(max(width, height)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// 縮小してsRGB 8bitに描画したCGImageを作る（アプリ上の見た目と同じ色になる）。
    private static func renderSRGBImage(_ cgImage: CGImage, maxSide: Int) throws -> CGImage {
        let (width, height) = scaledSize(width: cgImage.width, height: cgImage.height, maxSide: maxSide)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw writerError(3, "プレビュー用の描画領域を作成できませんでした") }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw writerError(3, "プレビュー画像を生成できませんでした") }
        return image
    }

    private static func renderSRGB8(_ cgImage: CGImage, maxSide: Int) throws -> RGB8Image {
        let image = try renderSRGBImage(cgImage, maxSide: maxSide)
        guard let bytes = image.dataProvider?.data as Data? else {
            throw writerError(4, "サムネイル画素を取得できませんでした")
        }
        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel / 8
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    let rowStart = y * image.bytesPerRow
                    for x in 0..<width {
                        let source = rowStart + x * bytesPerPixel
                        let destination = (y * width + x) * 3
                        output[destination] = input[source]
                        output[destination + 1] = input[source + 1]
                        output[destination + 2] = input[source + 2]
                    }
                }
            }
        }
        return RGB8Image(pixels: rgb, width: width, height: height)
    }

    private static func renderJPEGPreview(_ cgImage: CGImage, maxSide: Int) throws -> JPEGPreview {
        let image = try renderSRGBImage(cgImage, maxSide: maxSide)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw writerError(5, "JPEGプレビューを生成できませんでした")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw writerError(5, "JPEGプレビューを生成できませんでした")
        }
        let data = output as Data
        return JPEGPreview(
            data: data,
            width: image.width,
            height: image.height,
            subsampling: jpegLumaSampling(data)
        )
    }

    /// JPEGのSOFマーカーから輝度成分のサンプリング係数を読み、TIFFのYCbCrSubSamplingとして返す。
    static func jpegLumaSampling(_ data: Data) -> (horizontal: UInt16, vertical: UInt16) {
        let bytes = [UInt8](data)
        var index = 2 // SOI の直後
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else { index += 1; continue }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }
            if marker == 0x01 || (0xD0...0xD9).contains(marker) { index += 2; continue }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let isStartOfFrame = (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            // SOF: 長さ(2) 精度(1) 高さ(2) 幅(2) 成分数(1) の後に 成分ID(1) サンプリング係数(1) …
            if isStartOfFrame, index + 11 < bytes.count, bytes[index + 9] >= 1 {
                let factors = bytes[index + 11]
                let horizontal = UInt16(factors >> 4)
                let vertical = UInt16(factors & 0x0F)
                if horizontal > 0 && vertical > 0 { return (horizontal, vertical) }
                break
            }
            index += 2 + length
        }
        return (2, 2)
    }

    // MARK: - DNG バイナリ構築

    private struct TIFFTag {
        let tag: UInt16
        let type: UInt16 // 1=BYTE, 2=ASCII, 3=SHORT, 4=LONG, 5=RATIONAL, 10=SRATIONAL, 11=FLOAT
        let count: UInt32
        let valueOrData: TagValue
    }

    private enum TagValue {
        case inline(UInt32)
        case ascii(String)
        case bytes([UInt8])
        case shorts([UInt16])
        case longs([UInt32])
        case rationals([(UInt32, UInt32)])
        case srationals([(Int32, Int32)])
        case floats([Float])
    }

    private static func asciiTag(_ tag: UInt16, _ value: String) -> TIFFTag {
        let terminated = value + "\0"
        return TIFFTag(tag: tag, type: 2, count: UInt32(terminated.utf8.count), valueOrData: .ascii(terminated))
    }

    private static func longTag(_ tag: UInt16, _ value: UInt32) -> TIFFTag {
        TIFFTag(tag: tag, type: 4, count: 1, valueOrData: .inline(value))
    }

    private static func shortTag(_ tag: UInt16, _ values: [UInt16]) -> TIFFTag {
        TIFFTag(tag: tag, type: 3, count: UInt32(values.count), valueOrData: .shorts(values))
    }

    private static func srationalMatrixTag(_ tag: UInt16, _ values: [Double]) -> TIFFTag {
        let rationals = values.map { (Int32(($0 * 10000.0).rounded()), Int32(10000)) }
        return TIFFTag(tag: tag, type: 10, count: UInt32(rationals.count), valueOrData: .srationals(rationals))
    }

    /// XYZ(D65) → リニアsRGB。カメラ色空間＝リニアsRGBとして宣言する（白色点 D65 で R=G=B が白）。
    private static let xyzD65ToLinearSRGB: [Double] = [
         3.2404542, -1.5371385, -0.4985314,
        -0.9692660,  1.8760108,  0.0415560,
         0.0556434, -0.2040259,  1.0572252
    ]
    /// リニアsRGB → XYZ(D50)（Bradford順応済みの標準行列）。DNGのForwardMatrixはD50基準。
    private static let linearSRGBToXYZD50: [Double] = [
        0.4360747, 0.3850649, 0.1430804,
        0.2225045, 0.7168786, 0.0606169,
        0.0139322, 0.0971045, 0.7141733
    ]

    /// ファイル内の各要素の配置先。IFDのサイズはオフセット値に依存しないため、
    /// 仮のオフセットで一度サイズを測ってから本番の配置を決める（2パス）。
    private struct Layout {
        var ifd0: UInt32 = 0
        var exifIFD: UInt32 = 0
        var rawIFD: UInt32 = 0
        var previewIFD: UInt32 = 0
        var xmp: UInt32 = 0
        var thumbnail: UInt32 = 0
        var preview: UInt32 = 0
        var raw: UInt32 = 0
    }

    private static func buildDNGData(
        main: MainImage,
        thumbnail: RGB8Image,
        preview: JPEGPreview,
        metadata: RawMetadataInfo,
        embedLensProfile: Bool
    ) -> Data {
        let raw = main.data
        let width = main.width
        let height = main.height
        let camera = main.kind.camera
        let xmpData = buildXMPPacket(metadata: metadata, embedLensProfile: embedLensProfile, neutralProfile: camera == nil)
        let exifTags = buildExifTags(metadata: metadata, embedLensProfile: embedLensProfile)
        let previewDateTime = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime]
        )

        let bytesPerRow = width * 2 * main.kind.samplesPerPixel
        let rowsPerStrip = max(1, min(height, targetStripBytes / max(1, bytesPerRow)))
        let stripCount = (height + rowsPerStrip - 1) / rowsPerStrip

        func makeIFDs(_ layout: Layout) -> (ifd0: [TIFFTag], exif: [TIFFTag], raw: [TIFFTag], preview: [TIFFTag]) {
            var stripOffsets: [UInt32] = []
            var stripByteCounts: [UInt32] = []
            for strip in 0..<stripCount {
                let rows = min(rowsPerStrip, height - strip * rowsPerStrip)
                stripOffsets.append(layout.raw + UInt32(strip * rowsPerStrip * bytesPerRow))
                stripByteCounts.append(UInt32(rows * bytesPerRow))
            }

            // 主画像 SubIFD（16bit）
            var rawTags: [TIFFTag] = [
                longTag(254, 0),                                                          // NewSubFileType: 主画像
                longTag(256, UInt32(width)),                                              // ImageWidth
                longTag(257, UInt32(height)),                                             // ImageLength
                shortTag(259, [1]),                                                       // Compression: None
                TIFFTag(tag: 273, type: 4, count: UInt32(stripCount), valueOrData: .longs(stripOffsets)),     // StripOffsets
                longTag(278, UInt32(rowsPerStrip)),                                       // RowsPerStrip
                TIFFTag(tag: 279, type: 4, count: UInt32(stripCount), valueOrData: .longs(stripByteCounts)),  // StripByteCounts
                shortTag(284, [1]),                                                       // PlanarConfiguration: Chunky
            ]
            switch main.kind {
            case .linearSRGB, .cameraRGB:
                var white: UInt16 = 65535
                if case .cameraRGB(_, let whiteLevel) = main.kind {
                    white = UInt16(clamping: Int(whiteLevel.rounded()))
                }
                rawTags += [
                    shortTag(258, [16, 16, 16]),                                          // BitsPerSample
                    shortTag(262, [34892]),                                               // PhotometricInterpretation: LinearRaw
                    shortTag(277, [3]),                                                   // SamplesPerPixel
                    shortTag(0xC61A, [0, 0, 0]),                                          // BlackLevel
                    shortTag(0xC61D, [white, white, white]),                              // WhiteLevel
                ]
            case .bayer(let mosaic, _):
                let black = mosaic.blackLevels.map { (UInt32(max(0, ($0 * 100).rounded())), UInt32(100)) }
                rawTags += [
                    shortTag(258, [16]),                                                  // BitsPerSample
                    shortTag(262, [32803]),                                               // PhotometricInterpretation: CFA
                    shortTag(277, [1]),                                                   // SamplesPerPixel
                    shortTag(0x828D, [2, 2]),                                             // CFARepeatPatternDim
                    TIFFTag(tag: 0x828E, type: 1, count: 4, valueOrData: .bytes(mosaic.pattern)),              // CFAPattern
                    TIFFTag(tag: 0xC616, type: 1, count: 3, valueOrData: .bytes([0, 1, 2])),                   // CFAPlaneColor: R,G,B
                    shortTag(0xC617, [1]),                                                // CFALayout: Rectangular
                    shortTag(0xC619, [2, 2]),                                             // BlackLevelRepeatDim
                    TIFFTag(tag: 0xC61A, type: 5, count: 4, valueOrData: .rationals(black)),                   // BlackLevel
                    longTag(0xC61D, UInt32(max(1, mosaic.whiteLevel.rounded()))),         // WhiteLevel
                ]
            }

            // プレビュー SubIFD（JPEG, sRGB）
            let sampling = preview.subsampling
            let previewTags: [TIFFTag] = [
                longTag(254, 1),                                                          // NewSubFileType: 縮小画像
                longTag(256, UInt32(preview.width)),
                longTag(257, UInt32(preview.height)),
                shortTag(258, [8, 8, 8]),
                shortTag(259, [7]),                                                       // Compression: JPEG
                shortTag(262, [6]),                                                       // PhotometricInterpretation: YCbCr
                longTag(273, layout.preview),
                shortTag(277, [3]),
                longTag(278, UInt32(preview.height)),
                longTag(279, UInt32(preview.data.count)),
                shortTag(284, [1]),
                TIFFTag(tag: 0x0211, type: 5, count: 3, valueOrData: .rationals([(299, 1000), (587, 1000), (114, 1000)])), // YCbCrCoefficients
                shortTag(0x0212, [sampling.horizontal, sampling.vertical]),              // YCbCrSubSampling
                shortTag(0x0213, [1]),                                                    // YCbCrPositioning: Centered
                TIFFTag(tag: 0x0214, type: 5, count: 6, valueOrData: .rationals([(0, 1), (255, 1), (128, 1), (255, 1), (128, 1), (255, 1)])), // ReferenceBlackWhite
                asciiTag(0xC716, "MacStarStacker"),                                       // PreviewApplicationName
                longTag(0xC71A, 2),                                                       // PreviewColorSpace: sRGB
                asciiTag(0xC71B, previewDateTime),                                        // PreviewDateTime
            ]

            // IFD0（サムネイル + DNG共通タグ + 埋め込みカメラプロファイル）
            let make = !metadata.cameraMake.isEmpty ? metadata.cameraMake : (camera?.make.isEmpty == false ? camera!.make : "Unknown")
            let model = !metadata.cameraModel.isEmpty ? metadata.cameraModel : (camera?.model.isEmpty == false ? camera!.model : "Unknown Camera")
            var ifd0Tags: [TIFFTag] = [
                longTag(254, 1),                                                          // NewSubFileType: 縮小画像（サムネイル）
                longTag(256, UInt32(thumbnail.width)),
                longTag(257, UInt32(thumbnail.height)),
                shortTag(258, [8, 8, 8]),
                shortTag(259, [1]),
                shortTag(262, [2]),                                                       // PhotometricInterpretation: RGB
                asciiTag(271, make),                                                      // Make
                asciiTag(272, model),                                                     // Model
                longTag(273, layout.thumbnail),
                shortTag(274, [camera?.orientation ?? 1]),                                // Orientation
                shortTag(277, [3]),
                longTag(278, UInt32(thumbnail.height)),
                longTag(279, UInt32(thumbnail.pixels.count)),
                shortTag(284, [1]),
                asciiTag(305, "MacStarStacker"),                                          // Software
                TIFFTag(tag: 330, type: 4, count: 2, valueOrData: .longs([layout.rawIFD, layout.previewIFD])), // SubIFDs
                TIFFTag(tag: 700, type: 1, count: UInt32(xmpData.count), valueOrData: .inline(layout.xmp)),   // XMP

                TIFFTag(tag: 0xC612, type: 1, count: 4, valueOrData: .bytes([1, 4, 0, 0])),                   // DNGVersion: 1.4.0.0
                TIFFTag(tag: 0xC613, type: 1, count: 4, valueOrData: .bytes([1, 3, 0, 0])),                   // DNGBackwardVersion: 1.3.0.0
                asciiTag(0xC716, "MacStarStacker"),                                       // PreviewApplicationName
                longTag(0xC71A, 2),                                                       // PreviewColorSpace: sRGB
                asciiTag(0xC71B, previewDateTime),                                        // PreviewDateTime
            ]
            if let camera {
                ifd0Tags += cameraProfileTags(camera, metadata: metadata)
            } else {
                ifd0Tags += neutralProfileTags()
            }
            if let dateTime = exifDateTimeString(metadata.dateTimeOriginal) {
                ifd0Tags.append(asciiTag(306, dateTime))                                  // DateTime
            }
            if !exifTags.isEmpty {
                ifd0Tags.append(longTag(0x8769, layout.exifIFD))                          // ExifIFDPointer
            }
            return (ifd0Tags, exifTags, rawTags, previewTags)
        }

        func aligned(_ offset: Int) -> Int { offset % 2 == 0 ? offset : offset + 1 }

        // パス1: 仮オフセットで各IFDのサイズを測る
        let draft = makeIFDs(Layout())
        let ifd0Size = serializedIFD(draft.ifd0, at: 0).count
        let exifSize = draft.exif.isEmpty ? 0 : serializedIFD(draft.exif, at: 0).count
        let rawIFDSize = serializedIFD(draft.raw, at: 0).count
        let previewIFDSize = serializedIFD(draft.preview, at: 0).count

        // パス2: メタデータ（IFD・XMP）をファイル先頭側、画素データを後ろ側に配置する。
        // macOSのRAWデコーダー（Finder/QuickLookのサムネイル）はIFDが先頭付近にある前提で
        // 埋め込みプレビューを探すため、IFDを末尾に置くとプレビューが使われず真っ黒のサムネイルになる。
        var layout = Layout()
        var cursor = 8
        layout.ifd0 = UInt32(cursor); cursor = aligned(cursor + ifd0Size)
        if exifSize > 0 { layout.exifIFD = UInt32(cursor); cursor = aligned(cursor + exifSize) }
        layout.rawIFD = UInt32(cursor); cursor = aligned(cursor + rawIFDSize)
        layout.previewIFD = UInt32(cursor); cursor = aligned(cursor + previewIFDSize)
        layout.xmp = UInt32(cursor); cursor = aligned(cursor + xmpData.count)
        layout.thumbnail = UInt32(cursor); cursor = aligned(cursor + thumbnail.pixels.count)
        layout.preview = UInt32(cursor); cursor = aligned(cursor + preview.data.count)
        layout.raw = UInt32(cursor)

        let final = makeIFDs(layout)
        var data = Data()
        data.reserveCapacity(cursor + raw.count)
        // TIFF ヘッダ（リトルエンディアン "II", 42, IFD0オフセット）
        data.append(contentsOf: [0x49, 0x49, 42, 0])
        data.append(contentsOf: withUnsafeBytes(of: layout.ifd0.littleEndian, Array.init))

        func place(_ blob: Data, at offset: UInt32) {
            precondition(data.count <= Int(offset), "DNGのレイアウト計算が一致しません")
            data.append(Data(count: Int(offset) - data.count))
            data.append(blob)
        }
        place(serializedIFD(final.ifd0, at: layout.ifd0), at: layout.ifd0)
        if exifSize > 0 { place(serializedIFD(final.exif, at: layout.exifIFD), at: layout.exifIFD) }
        place(serializedIFD(final.raw, at: layout.rawIFD), at: layout.rawIFD)
        place(serializedIFD(final.preview, at: layout.previewIFD), at: layout.previewIFD)
        place(xmpData, at: layout.xmp)
        place(thumbnail.pixels, at: layout.thumbnail)
        place(preview.data, at: layout.preview)
        place(raw, at: layout.raw)
        return data
    }

    /// 現像済みリニアsRGB用: 無変換のカメラプロファイル（アプリ表示と同じ見た目で現像させる）
    private static func neutralProfileTags() -> [TIFFTag] {
        [
            asciiTag(0xC614, uniqueCameraModel),                                          // UniqueCameraModel
            srationalMatrixTag(0xC621, xyzD65ToLinearSRGB),                               // ColorMatrix1
            TIFFTag(tag: 0xC628, type: 5, count: 3, valueOrData: .rationals([(1, 1), (1, 1), (1, 1)])),       // AsShotNeutral
            TIFFTag(tag: 0xC62A, type: 10, count: 1, valueOrData: .srationals([(0, 1)])),                     // BaselineExposure
            shortTag(0xC65A, [21]),                                                       // CalibrationIlluminant1: D65
            asciiTag(0xC6F8, embeddedProfileName),                                        // ProfileName
            // 直線のトーンカーブを明示し、Adobe既定のコントラストカーブを掛けない
            TIFFTag(tag: 0xC6FC, type: 11, count: 4, valueOrData: .floats([0, 0, 1, 1])),                     // ProfileToneCurve
            longTag(0xC6FD, 0),                                                           // ProfileEmbedPolicy: Allow Copying
            srationalMatrixTag(0xC714, linearSRGBToXYZD50),                               // ForwardMatrix1
            TIFFTag(tag: 0xC7A5, type: 10, count: 1, valueOrData: .srationals([(0, 1)])),                     // BaselineExposureOffset
            longTag(0xC7A6, 1),                                                           // DefaultBlackRender: None（自動黒補正なし）
        ]
    }

    /// 実カメラのRAWデータ用: 実カメラ名と色変換行列・ホワイトバランスを書き、
    /// Camera Raw / Lightroom で通常のRAWと同じプロファイル・調整幅で扱わせる。
    private static func cameraProfileTags(_ camera: CameraColorProfile, metadata: RawMetadataInfo) -> [TIFFTag] {
        let unique = !camera.uniqueCameraModel.isEmpty ? camera.uniqueCameraModel
            : (!metadata.uniqueCameraModel.isEmpty ? metadata.uniqueCameraModel : "Unknown Camera")
        var tags: [TIFFTag] = [
            asciiTag(0xC614, unique),                                                     // UniqueCameraModel（実カメラ名）
            srationalMatrixTag(0xC621, camera.colorMatrix1),                              // ColorMatrix1
            shortTag(0xC65A, [UInt16(clamping: camera.illuminant1 > 0 ? camera.illuminant1 : 21)]),         // CalibrationIlluminant1
        ]
        if let matrix2 = camera.colorMatrix2 {
            tags.append(srationalMatrixTag(0xC622, matrix2))                              // ColorMatrix2
            tags.append(shortTag(0xC65B, [UInt16(clamping: camera.illuminant2 > 0 ? camera.illuminant2 : 21)])) // CalibrationIlluminant2
        }
        if camera.baselineExposure != 0 {
            tags.append(TIFFTag(tag: 0xC62A, type: 10, count: 1,
                                valueOrData: .srationals([(Int32((camera.baselineExposure * 100).rounded()), 100)]))) // BaselineExposure
        }
        let neutral = camera.asShotNeutral.prefix(3).map { (UInt32(max(1, ($0 * 1_000_000).rounded())), UInt32(1_000_000)) }
        tags.append(TIFFTag(tag: 0xC628, type: 5, count: UInt32(neutral.count), valueOrData: .rationals(Array(neutral)))) // AsShotNeutral
        return tags
    }

    private static func buildExifTags(metadata: RawMetadataInfo, embedLensProfile: Bool) -> [TIFFTag] {
        var exifTags: [TIFFTag] = []
        if let fl = metadata.focalLength {
            exifTags.append(TIFFTag(tag: 0x920A, type: 5, count: 1, valueOrData: .rationals([(UInt32((fl * 100.0).rounded()), 100)]))) // FocalLength
        }
        if let fl35 = metadata.focalLength35mm {
            exifTags.append(shortTag(0xA405, [UInt16(clamping: Int(fl35.rounded()))]))  // FocalLengthIn35mmFilm
        }
        if let fn = metadata.fNumber {
            exifTags.append(TIFFTag(tag: 0x829D, type: 5, count: 1, valueOrData: .rationals([(UInt32((fn * 100.0).rounded()), 100)]))) // FNumber
        }
        if let iso = metadata.iso {
            exifTags.append(shortTag(0x8827, [UInt16(clamping: iso)]))                // ISOSpeedRatings
        }
        if let exp = metadata.exposureTime, exp > 0 {
            let expRat = exp < 1.0 ? (UInt32(1), UInt32(max(1, (1.0 / exp).rounded()))) : (UInt32((exp * 10.0).rounded()), UInt32(10))
            exifTags.append(TIFFTag(tag: 0x829A, type: 5, count: 1, valueOrData: .rationals([expRat]))) // ExposureTime
        }
        if let dateTime = exifDateTimeString(metadata.dateTimeOriginal) {
            exifTags.append(asciiTag(0x9003, dateTime))                               // DateTimeOriginal
            exifTags.append(asciiTag(0x9004, dateTime))                               // DateTimeDigitized
        }

        // レンズプロファイル EXIF タグ
        if embedLensProfile {
            if !metadata.lensMake.isEmpty { exifTags.append(asciiTag(0xA433, metadata.lensMake)) }                 // LensMake
            if !metadata.lensModel.isEmpty { exifTags.append(asciiTag(0xA434, metadata.lensModel)) }               // LensModel
            if !metadata.lensSerialNumber.isEmpty { exifTags.append(asciiTag(0xA435, metadata.lensSerialNumber)) } // LensSerialNumber
            if metadata.lensSpecification.count == 4 {
                let rationals = metadata.lensSpecification.map { (UInt32(($0 * 100.0).rounded()), UInt32(100)) }
                exifTags.append(TIFFTag(tag: 0xA432, type: 5, count: 4, valueOrData: .rationals(rationals))) // LensSpecification
            }
        }
        return exifTags
    }

    /// 指定オフセットに置くIFDをシリアライズする（エントリ表の直後にIFD外の値を配置）。
    private static func serializedIFD(_ tags: [TIFFTag], at ifdOffset: UInt32) -> Data {
        // TIFF規格ではタグID順の昇順ソートが必須
        let sorted = tags.sorted { $0.tag < $1.tag }
        let extraBase = ifdOffset + UInt32(2 + sorted.count * 12 + 4)

        var extraData = Data()
        var table = Data()
        table.append(contentsOf: withUnsafeBytes(of: UInt16(sorted.count).littleEndian, Array.init))
        for tag in sorted {
            let entry = serializeTag(tag, baseOffset: extraBase, extraData: &extraData)
            table.append(contentsOf: withUnsafeBytes(of: entry.tag.littleEndian, Array.init))
            table.append(contentsOf: withUnsafeBytes(of: entry.type.littleEndian, Array.init))
            table.append(contentsOf: withUnsafeBytes(of: entry.count.littleEndian, Array.init))
            table.append(contentsOf: withUnsafeBytes(of: entry.valueOrOffset.littleEndian, Array.init))
        }
        table.append(contentsOf: [0, 0, 0, 0]) // Next IFD = 0
        return table + extraData
    }

    private static func serializeTag(_ tag: TIFFTag, baseOffset: UInt32, extraData: inout Data) -> (tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
        // TIFFの外部値はワード境界へ配置する。特にUTF-8の日本語メタデータは
        // バイト数が奇数になりやすく、奇数オフセットのままだとExifToolが警告する。
        func alignWord() {
            if extraData.count % 2 != 0 { extraData.append(0) }
        }
        func appendExternal(_ bytes: [UInt8]) -> UInt32 {
            alignWord()
            let offset = baseOffset + UInt32(extraData.count)
            extraData.append(contentsOf: bytes)
            return offset
        }
        func inlineValue(_ bytes: [UInt8]) -> UInt32 {
            var value: UInt32 = 0
            for (index, byte) in bytes.enumerated() {
                value |= UInt32(byte) << (index * 8)
            }
            return value
        }
        func store(_ bytes: [UInt8]) -> UInt32 {
            bytes.count <= 4 ? inlineValue(bytes) : appendExternal(bytes)
        }

        let bytes: [UInt8]
        switch tag.valueOrData {
        case .inline(let value):
            return (tag.tag, tag.type, tag.count, value)
        case .bytes(let values):
            bytes = values
        case .ascii(let string):
            bytes = Array(string.utf8)
        case .shorts(let values):
            bytes = values.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) }
        case .longs(let values):
            bytes = values.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) }
        case .rationals(let values):
            bytes = values.flatMap {
                withUnsafeBytes(of: $0.0.littleEndian, Array.init) + withUnsafeBytes(of: $0.1.littleEndian, Array.init)
            }
        case .srationals(let values):
            bytes = values.flatMap {
                withUnsafeBytes(of: $0.0.littleEndian, Array.init) + withUnsafeBytes(of: $0.1.littleEndian, Array.init)
            }
        case .floats(let values):
            bytes = values.flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian, Array.init) }
        }
        return (tag.tag, tag.type, tag.count, store(bytes))
    }

    // MARK: - XMP パケット生成 (Adobe Camera Raw 現像設定)

    private static func buildXMPPacket(metadata: RawMetadataInfo, embedLensProfile: Bool, neutralProfile: Bool) -> Data {
        // 空の値は属性ごと省略する（空文字のaux:LensInfo等はAdobe製品で不正値として扱われうる）。
        var attributes: [String] = [
            "crs:Version=\"15.0\"",
            "crs:ProcessVersion=\"15.4\"",
        ]
        if neutralProfile {
            attributes += [
                "crs:HasSettings=\"True\"",
                // 埋め込みプロファイルを選択させ、「Adobe カラー」等のルック（コントラスト・彩度の上乗せ）を掛けない。
                "crs:CameraProfile=\"\(escapeXML(embeddedProfileName))\"",
                "crs:ToneCurveName2012=\"Linear\"",
            ]
        }
        func addAttribute(_ name: String, _ value: String) {
            guard !value.isEmpty else { return }
            attributes.append("\(name)=\"\(escapeXML(value))\"")
        }

        if embedLensProfile {
            // プロファイル名やLCPファイル名は捏造せず、Camera Rawにレンズ情報から自動選択させる。
            attributes.append(contentsOf: [
                "crs:LensProfileEnable=\"1\"",
                "crs:LensProfileSetup=\"Auto\"",
                "crs:AutoLateralCA=\"1\"",
            ])
            addAttribute("aux:Lens", metadata.lensModel)
            addAttribute("aux:LensSerialNumber", metadata.lensSerialNumber)
            if metadata.lensSpecification.count == 4 {
                // XMPのaux:LensInfoは有理数4つを空白区切りで表す（例: "200/10 200/10 18/10 18/10"）。
                addAttribute("aux:LensInfo", metadata.lensSpecification
                    .map { "\(Int(($0 * 10.0).rounded()))/10" }
                    .joined(separator: " "))
            }
        }
        if let focal = metadata.focalLength {
            addAttribute("exif:FocalLength", "\(Int((focal * 10.0).rounded()))/10")
        }
        if let fNumber = metadata.fNumber {
            addAttribute("exif:FNumber", "\(Int((fNumber * 10.0).rounded()))/10")
        }
        addAttribute("tiff:Make", metadata.cameraMake)
        addAttribute("tiff:Model", metadata.cameraModel)

        let attributeString = attributes.map { "    " + $0 }.joined(separator: "\n")
        let xmpString = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="MacStarStacker">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:aux="http://ns.adobe.com/exif/1.0/aux/"
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
        \(attributeString)/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        return Data(xmpString.utf8)
    }

    /// EXIF/TIFFの日時タグは "YYYY:MM:DD HH:MM:SS" の19文字（+終端NUL）固定長。
    /// サブ秒やタイムゾーン付きの値は先頭19文字に切り詰め、形式が違う場合は書き込まない。
    static func exifDateTimeString(_ value: String) -> String? {
        let trimmed = String(value.trimmingCharacters(in: .whitespaces).prefix(19))
        let pattern = #"^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    private static func escapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - ExifTool による追加メタデータコピー

    /// 手動指定されたレンズ名をExifToolのコピー後に上書きするための引数。
    private static func lensOverrideArguments(metadata: RawMetadataInfo) -> [String] {
        var args = [
            "-XMP-crs:LensProfileEnable=1",
            "-XMP-crs:LensProfileSetup=Auto",
            "-XMP-crs:AutoLateralCA=1"
        ]
        if !metadata.lensModel.isEmpty {
            args.append("-EXIF:LensModel=\(metadata.lensModel)")
            args.append("-XMP-aux:Lens=\(metadata.lensModel)")
        }
        if !metadata.lensMake.isEmpty {
            args.append("-EXIF:LensMake=\(metadata.lensMake)")
        }
        return args
    }
}
