import Foundation
import AppKit

/// DNG 1.4 / 1.6 規格に準拠した 16-bit リニアDNG (Linear RAW) を書き出すライター
public enum DNGWriter {

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
            throw NSError(domain: "MacStarStacker.DNGWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGImageの取得に失敗しました"])
        }

        let width = cgImage.width
        let height = cgImage.height
        let meta = metadata ?? RawMetadataInfo()

        // 1. 16-bit リニアRGBピクセルデータを抽出
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        var rgbaPixels = [UInt16](repeating: 0, count: width * height * 4) // RGBA (64bpp)
        let bytesPerRow = width * 8 // 4チャンネル * 2バイト

        guard let context = CGContext(
            data: &rgbaPixels,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        ) else {
            throw NSError(domain: "MacStarStacker.DNGWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "CGContextの生成に失敗しました"])
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // RGBA (4ch) から RGB (3ch) へ変換
        var pixels = [UInt16](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            pixels[i * 3 + 0] = rgbaPixels[i * 4 + 0]
            pixels[i * 3 + 1] = rgbaPixels[i * 4 + 1]
            pixels[i * 3 + 2] = rgbaPixels[i * 4 + 2]
        }

        // 2. バイナリDNG/TIFFファイルの構築
        let dngData = buildDNGData(
            pixels: pixels,
            width: width,
            height: height,
            metadata: meta,
            embedLensProfile: embedLensProfile
        )

        try dngData.write(to: url, options: .atomic)

        // 3. システムにexiftoolが存在し、かつ元RAWファイルがある場合は、MakerNotesや追加レンズタグを完全同期
        if embedLensProfile, let sourceURL = meta.sourceURL, let exiftool = RawMetadataExtractor.findExiftool() {
            syncExifToolTags(sourceURL: sourceURL, targetURL: url, exiftoolPath: exiftool, metadata: meta)
        }
    }

    // MARK: - DNG バイナリ構築

    private struct TIFFTag {
        let tag: UInt16
        let type: UInt16 // 1=BYTE, 2=ASCII, 3=SHORT, 4=LONG, 5=RATIONAL, 7=UNDEFINED, 9=SLONG, 10=SRATIONAL
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
    }

    private static func buildDNGData(
        pixels: [UInt16],
        width: Int,
        height: Int,
        metadata: RawMetadataInfo,
        embedLensProfile: Bool
    ) -> Data {
        var data = Data()

        // 1. TIFF ヘッダ (8バイト)
        // Little Endian ("II"), Magic 42, IFD0 Offset = 8
        data.append(contentsOf: [0x49, 0x49]) // "II"
        data.append(contentsOf: [42, 0])       // Magic 42
        let ifd0Offset: UInt32 = 8
        data.append(contentsOf: withUnsafeBytes(of: ifd0Offset.littleEndian, Array.init))

        // 2. IFD0 タグの準備
        var ifd0Tags: [TIFFTag] = []

        // 基本画像構造
        ifd0Tags.append(TIFFTag(tag: 256, type: 4, count: 1, valueOrData: .inline(UInt32(width))))        // ImageWidth
        ifd0Tags.append(TIFFTag(tag: 257, type: 4, count: 1, valueOrData: .inline(UInt32(height))))       // ImageLength
        ifd0Tags.append(TIFFTag(tag: 258, type: 3, count: 3, valueOrData: .shorts([16, 16, 16])))        // BitsPerSample
        ifd0Tags.append(TIFFTag(tag: 259, type: 3, count: 1, valueOrData: .inline(1)))                    // Compression: None
        ifd0Tags.append(TIFFTag(tag: 262, type: 3, count: 1, valueOrData: .inline(34892)))                // PhotometricInterpretation: LinearRaw
        ifd0Tags.append(TIFFTag(tag: 274, type: 3, count: 1, valueOrData: .inline(1)))                    // Orientation: Top-Left
        ifd0Tags.append(TIFFTag(tag: 277, type: 3, count: 1, valueOrData: .inline(3)))                    // SamplesPerPixel: 3
        ifd0Tags.append(TIFFTag(tag: 278, type: 4, count: 1, valueOrData: .inline(UInt32(height))))       // RowsPerStrip
        ifd0Tags.append(TIFFTag(tag: 284, type: 3, count: 1, valueOrData: .inline(1)))                    // PlanarConfiguration: Chunky
        ifd0Tags.append(TIFFTag(tag: 305, type: 2, count: UInt32("MacStarStacker\0".utf8.count), valueOrData: .ascii("MacStarStacker\0"))) // Software

        let makeStr = metadata.cameraMake.isEmpty ? "Unknown\0" : "\(metadata.cameraMake)\0"
        let modelStr = metadata.cameraModel.isEmpty ? "Unknown Camera\0" : "\(metadata.cameraModel)\0"
        let uniqueModelStr = metadata.uniqueCameraModel.isEmpty ? modelStr : "\(metadata.uniqueCameraModel)\0"

        ifd0Tags.append(TIFFTag(tag: 271, type: 2, count: UInt32(makeStr.utf8.count), valueOrData: .ascii(makeStr)))   // Make
        ifd0Tags.append(TIFFTag(tag: 272, type: 2, count: UInt32(modelStr.utf8.count), valueOrData: .ascii(modelStr))) // Model

        if !metadata.dateTimeOriginal.isEmpty {
            let dateStr = "\(metadata.dateTimeOriginal)\0"
            ifd0Tags.append(TIFFTag(tag: 306, type: 2, count: UInt32(dateStr.utf8.count), valueOrData: .ascii(dateStr))) // DateTime
        }

        // DNG 仕様タグ (Tag 50706〜)
        ifd0Tags.append(TIFFTag(tag: 0xC612, type: 1, count: 4, valueOrData: .bytes([1, 4, 0, 0]))) // DNGVersion: 1.4.0.0
        ifd0Tags.append(TIFFTag(tag: 0xC613, type: 1, count: 4, valueOrData: .bytes([1, 3, 0, 0]))) // DNGBackwardVersion: 1.3.0.0
        ifd0Tags.append(TIFFTag(tag: 0xC614, type: 2, count: UInt32(uniqueModelStr.utf8.count), valueOrData: .ascii(uniqueModelStr))) // UniqueCameraModel

        // カラーマトリクス
        let cm1 = metadata.colorMatrix1 ?? [
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0
        ]
        let cm1Rationals = cm1.map { (Int32(round($0 * 10000.0)), Int32(10000)) }
        ifd0Tags.append(TIFFTag(tag: 0xC621, type: 10, count: UInt32(cm1Rationals.count), valueOrData: .srationals(cm1Rationals))) // ColorMatrix1
        ifd0Tags.append(TIFFTag(tag: 0xC65A, type: 3, count: 1, valueOrData: .inline(UInt32(metadata.calibrationIlluminant1))))   // CalibrationIlluminant1 (Standard Light A)

        if let cm2 = metadata.colorMatrix2 {
            let cm2Rationals = cm2.map { (Int32(round($0 * 10000.0)), Int32(10000)) }
            ifd0Tags.append(TIFFTag(tag: 0xC622, type: 10, count: UInt32(cm2Rationals.count), valueOrData: .srationals(cm2Rationals))) // ColorMatrix2
            ifd0Tags.append(TIFFTag(tag: 0xC65B, type: 3, count: 1, valueOrData: .inline(UInt32(metadata.calibrationIlluminant2))))   // CalibrationIlluminant2 (D65)
        }

        let asn = metadata.asShotNeutral ?? [1.0, 1.0, 1.0]
        let asnRationals = asn.map { (UInt32(round($0 * 10000.0)), UInt32(10000)) }
        ifd0Tags.append(TIFFTag(tag: 0xC628, type: 5, count: UInt32(asnRationals.count), valueOrData: .rationals(asnRationals))) // AsShotNeutral

        // 3. EXIF IFD タグの準備
        var exifTags: [TIFFTag] = []
        if let fl = metadata.focalLength {
            let flRat = (UInt32(round(fl * 100.0)), UInt32(100))
            exifTags.append(TIFFTag(tag: 0x920A, type: 5, count: 1, valueOrData: .rationals([flRat]))) // FocalLength
        }
        if let fl35 = metadata.focalLength35mm {
            exifTags.append(TIFFTag(tag: 0xA405, type: 3, count: 1, valueOrData: .inline(UInt32(fl35)))) // FocalLengthIn35mmFilm
        }
        if let fn = metadata.fNumber {
            let fnRat = (UInt32(round(fn * 100.0)), UInt32(100))
            exifTags.append(TIFFTag(tag: 0x829D, type: 5, count: 1, valueOrData: .rationals([fnRat]))) // FNumber
        }
        if let iso = metadata.iso {
            exifTags.append(TIFFTag(tag: 0x8827, type: 3, count: 1, valueOrData: .inline(UInt32(iso)))) // ISOSpeedRatings
        }
        if let exp = metadata.exposureTime {
            let expRat = exp < 1.0 ? (UInt32(1), UInt32(max(1, round(1.0 / exp)))) : (UInt32(round(exp * 10.0)), UInt32(10))
            exifTags.append(TIFFTag(tag: 0x829A, type: 5, count: 1, valueOrData: .rationals([expRat]))) // ExposureTime
        }
        if !metadata.dateTimeOriginal.isEmpty {
            let dtStr = "\(metadata.dateTimeOriginal)\0"
            exifTags.append(TIFFTag(tag: 0x9003, type: 2, count: UInt32(dtStr.utf8.count), valueOrData: .ascii(dtStr))) // DateTimeOriginal
            exifTags.append(TIFFTag(tag: 0x9004, type: 2, count: UInt32(dtStr.utf8.count), valueOrData: .ascii(dtStr))) // DateTimeDigitized
        }

        // レンズプロファイル EXIF タグ
        if embedLensProfile {
            if !metadata.lensMake.isEmpty {
                let lmStr = "\(metadata.lensMake)\0"
                exifTags.append(TIFFTag(tag: 0xA433, type: 2, count: UInt32(lmStr.utf8.count), valueOrData: .ascii(lmStr))) // LensMake
            }
            if !metadata.lensModel.isEmpty {
                let lmStr = "\(metadata.lensModel)\0"
                exifTags.append(TIFFTag(tag: 0xA434, type: 2, count: UInt32(lmStr.utf8.count), valueOrData: .ascii(lmStr))) // LensModel
            }
            if !metadata.lensSerialNumber.isEmpty {
                let lsStr = "\(metadata.lensSerialNumber)\0"
                exifTags.append(TIFFTag(tag: 0xA435, type: 2, count: UInt32(lsStr.utf8.count), valueOrData: .ascii(lsStr))) // LensSerialNumber
            }
            if !metadata.lensSpecification.isEmpty {
                let lSpecRats = metadata.lensSpecification.map { (UInt32(round($0 * 100.0)), UInt32(100)) }
                exifTags.append(TIFFTag(tag: 0xA432, type: 5, count: UInt32(lSpecRats.count), valueOrData: .rationals(lSpecRats))) // LensSpecification
            }
        }

        // 4. XMP パケット (Adobe Camera Raw レンズプロファイル設定) の構築
        let xmpData: Data
        if embedLensProfile {
            xmpData = buildXMPPacket(metadata: metadata)
        } else {
            xmpData = Data()
        }

        // 5. タグのソート (TIFF規格ではタグID順に昇順ソートが必須)
        ifd0Tags.sort { $0.tag < $1.tag }
        exifTags.sort { $0.tag < $1.tag }

        // 6. オフセット計算とアセンブリ
        // レイアウト:
        // [TIFF Header: 8 bytes]
        // [IFD0 Entries: 2 + count * 12 + 4 bytes]
        // [IFD0 Extra Data Block (Strings, Rationals, Arrays)]
        // [EXIF IFD Entries: 2 + count * 12 + 4 bytes]
        // [EXIF IFD Extra Data Block]
        // [XMP Packet]
        // [Pixel Data (Strip 0)]

        var ifd0ExtraData = Data()
        var exifExtraData = Data()

        // IFD0のオフセット計算プレースホルダー
        var ifd0TableSize = 2 + ifd0Tags.count * 12 + 4
        // EXIFポインタタグとXMPタグを追加するためのスロットを確保
        if !exifTags.isEmpty {
            ifd0Tags.append(TIFFTag(tag: 0x8769, type: 4, count: 1, valueOrData: .inline(0))) // ExifIFDPointer
        }
        if !xmpData.isEmpty {
            ifd0Tags.append(TIFFTag(tag: 700, type: 1, count: UInt32(xmpData.count), valueOrData: .inline(0))) // XMP
        }
        // StripOffsets / StripByteCounts
        ifd0Tags.append(TIFFTag(tag: 273, type: 4, count: 1, valueOrData: .inline(0))) // StripOffsets
        ifd0Tags.append(TIFFTag(tag: 279, type: 4, count: 1, valueOrData: .inline(UInt32(pixels.count * 2)))) // StripByteCounts

        ifd0Tags.sort { $0.tag < $1.tag }
        ifd0TableSize = 2 + ifd0Tags.count * 12 + 4

        let ifd0ExtraDataOffset = UInt32(8 + ifd0TableSize)
        
        // IFD0 Extra Data をシリアライズしてオフセットを解決
        var resolvedIFD0Entries: [(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32)] = []
        for tag in ifd0Tags {
            let res = serializeTag(tag, baseOffset: ifd0ExtraDataOffset + UInt32(ifd0ExtraData.count), extraData: &ifd0ExtraData)
            resolvedIFD0Entries.append(res)
        }

        let exifIFDOffset = ifd0ExtraDataOffset + UInt32(ifd0ExtraData.count)
        var exifTableSize = 0
        var resolvedEXIFEntries: [(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32)] = []

        if !exifTags.isEmpty {
            exifTableSize = 2 + exifTags.count * 12 + 4
            let exifExtraDataOffset = exifIFDOffset + UInt32(exifTableSize)
            for tag in exifTags {
                let res = serializeTag(tag, baseOffset: exifExtraDataOffset + UInt32(exifExtraData.count), extraData: &exifExtraData)
                resolvedEXIFEntries.append(res)
            }
        }

        let xmpOffset = exifIFDOffset + UInt32(exifTableSize) + UInt32(exifExtraData.count)
        let pixelDataOffset = xmpOffset + UInt32(xmpData.count)

        // IFD0内の ExifIFDPointer, XMP, StripOffsets のオフセット値を更新
        for i in 0..<resolvedIFD0Entries.count {
            if resolvedIFD0Entries[i].tag == 0x8769 {
                resolvedIFD0Entries[i].valueOrOffset = exifIFDOffset
            } else if resolvedIFD0Entries[i].tag == 700 {
                resolvedIFD0Entries[i].valueOrOffset = xmpOffset
            } else if resolvedIFD0Entries[i].tag == 273 {
                resolvedIFD0Entries[i].valueOrOffset = pixelDataOffset
            }
        }

        // 7. データの連結
        // IFD0 Table
        var ifd0Data = Data()
        let ifd0Count = UInt16(resolvedIFD0Entries.count).littleEndian
        ifd0Data.append(contentsOf: withUnsafeBytes(of: ifd0Count, Array.init))
        for entry in resolvedIFD0Entries {
            let tagLE = entry.tag.littleEndian
            let typeLE = entry.type.littleEndian
            let countLE = entry.count.littleEndian
            let valLE = entry.valueOrOffset.littleEndian
            ifd0Data.append(contentsOf: withUnsafeBytes(of: tagLE, Array.init))
            ifd0Data.append(contentsOf: withUnsafeBytes(of: typeLE, Array.init))
            ifd0Data.append(contentsOf: withUnsafeBytes(of: countLE, Array.init))
            ifd0Data.append(contentsOf: withUnsafeBytes(of: valLE, Array.init))
        }
        ifd0Data.append(contentsOf: [0, 0, 0, 0]) // Next IFD = 0

        data.append(ifd0Data)
        data.append(ifd0ExtraData)

        // EXIF Table
        if !exifTags.isEmpty {
            var exifData = Data()
            let exifCount = UInt16(resolvedEXIFEntries.count).littleEndian
            exifData.append(contentsOf: withUnsafeBytes(of: exifCount, Array.init))
            for entry in resolvedEXIFEntries {
                let tagLE = entry.tag.littleEndian
                let typeLE = entry.type.littleEndian
                let countLE = entry.count.littleEndian
                let valLE = entry.valueOrOffset.littleEndian
                exifData.append(contentsOf: withUnsafeBytes(of: tagLE, Array.init))
                exifData.append(contentsOf: withUnsafeBytes(of: typeLE, Array.init))
                exifData.append(contentsOf: withUnsafeBytes(of: countLE, Array.init))
                exifData.append(contentsOf: withUnsafeBytes(of: valLE, Array.init))
            }
            exifData.append(contentsOf: [0, 0, 0, 0]) // Next IFD = 0
            data.append(exifData)
            data.append(exifExtraData)
        }

        // XMP Packet
        if !xmpData.isEmpty {
            data.append(xmpData)
        }

        // Pixel Data (16-bit little-endian RGB)
        pixels.withUnsafeBytes {
            data.append(contentsOf: $0)
        }

        return data
    }

    private static func serializeTag(_ tag: TIFFTag, baseOffset: UInt32, extraData: inout Data) -> (tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
        switch tag.valueOrData {
        case .inline(let val):
            return (tag.tag, tag.type, tag.count, val)

        case .bytes(let bytes):
            if bytes.count <= 4 {
                var val: UInt32 = 0
                for (idx, b) in bytes.enumerated() {
                    val |= (UInt32(b) << (idx * 8))
                }
                return (tag.tag, tag.type, tag.count, val)
            } else {
                let offset = baseOffset
                extraData.append(contentsOf: bytes)
                return (tag.tag, tag.type, tag.count, offset)
            }

        case .shorts(let shorts):
            if shorts.count <= 2 {
                var val: UInt32 = 0
                for (idx, s) in shorts.enumerated() {
                    val |= (UInt32(s) << (idx * 16))
                }
                return (tag.tag, tag.type, tag.count, val)
            } else {
                let offset = baseOffset
                for s in shorts {
                    let sLE = s.littleEndian
                    extraData.append(contentsOf: withUnsafeBytes(of: sLE, Array.init))
                }
                return (tag.tag, tag.type, tag.count, offset)
            }

        case .longs(let longs):
            if longs.count == 1 {
                return (tag.tag, tag.type, tag.count, longs[0])
            } else {
                let offset = baseOffset
                for l in longs {
                    let lLE = l.littleEndian
                    extraData.append(contentsOf: withUnsafeBytes(of: lLE, Array.init))
                }
                return (tag.tag, tag.type, tag.count, offset)
            }

        case .ascii(let str):
            let utf8Bytes = Array(str.utf8)
            if utf8Bytes.count <= 4 {
                var val: UInt32 = 0
                for (idx, b) in utf8Bytes.enumerated() {
                    val |= (UInt32(b) << (idx * 8))
                }
                return (tag.tag, tag.type, tag.count, val)
            } else {
                let offset = baseOffset
                extraData.append(contentsOf: utf8Bytes)
                return (tag.tag, tag.type, tag.count, offset)
            }

        case .rationals(let rationals):
            let offset = baseOffset
            for (num, den) in rationals {
                let numLE = num.littleEndian
                let denLE = den.littleEndian
                extraData.append(contentsOf: withUnsafeBytes(of: numLE, Array.init))
                extraData.append(contentsOf: withUnsafeBytes(of: denLE, Array.init))
            }
            return (tag.tag, tag.type, tag.count, offset)

        case .srationals(let srationals):
            let offset = baseOffset
            for (num, den) in srationals {
                let numLE = num.littleEndian
                let denLE = den.littleEndian
                extraData.append(contentsOf: withUnsafeBytes(of: numLE, Array.init))
                extraData.append(contentsOf: withUnsafeBytes(of: denLE, Array.init))
            }
            return (tag.tag, tag.type, tag.count, offset)
        }
    }

    // MARK: - XMP パケット生成 (Adobe Camera Raw レンズプロファイル設定)

    private static func buildXMPPacket(metadata: RawMetadataInfo) -> Data {
        let lensModelEscaped = escapeXML(metadata.lensModel)
        let makeEscaped = escapeXML(metadata.cameraMake)
        let modelEscaped = escapeXML(metadata.cameraModel)
        let lensSerialEscaped = escapeXML(metadata.lensSerialNumber)
        
        let lensSpecStr: String
        if !metadata.lensSpecification.isEmpty {
            lensSpecStr = metadata.lensSpecification.map { String($0) }.joined(separator: " ")
        } else {
            lensSpecStr = ""
        }

        let focalStr = metadata.focalLength != nil ? String(format: "%.1f", metadata.focalLength!) : ""
        let fNumberStr = metadata.fNumber != nil ? String(format: "%.1f", metadata.fNumber!) : ""

        let xmpString = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 2022/08/04-04:18:15">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:aux="http://ns.adobe.com/exif/1.0/aux/"
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            crs:Version="15.0"
            crs:ProcessVersion="15.4"
            crs:LensProfileEnable="1"
            crs:LensProfileSetup="LensDefaults"
            crs:AutoLateralCA="1"
            crs:LensManualDistortionAmount="0"
            crs:VignetteCorrectionAmount="100"
            crs:DistortionCorrectionAmount="100"
            crs:LensProfileName="\(lensModelEscaped)"
            aux:Lens="\(lensModelEscaped)"
            aux:LensInfo="\(lensSpecStr)"
            aux:LensSerialNumber="\(lensSerialEscaped)"
            aux:LensID="\(lensModelEscaped)"
            exif:FocalLength="\(focalStr)"
            exif:FNumber="\(fNumberStr)"
            tiff:Make="\(makeEscaped)"
            tiff:Model="\(modelEscaped)">
           <crs:LensProfileFilename>\(lensModelEscaped).lcp</crs:LensProfileFilename>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        return Data(xmpString.utf8)
    }

    private static func escapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - ExifTool による MakerNotes / OpcodeList 完全同期

    private static func syncExifToolTags(sourceURL: URL, targetURL: URL, exiftoolPath: String, metadata: RawMetadataInfo) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        
        var args = [
            "-tagsFromFile", sourceURL.path,
            "-all:all>all:all",
            "-MakerNotes:all>MakerNotes:all",
            "-LensProfile*:all",
            "-XMP-crs:LensProfileEnable=1",
            "-XMP-crs:LensProfileSetup=LensDefaults",
            "-XMP-crs:AutoLateralCA=1",
            "-overwrite_original",
            targetURL.path
        ]
        
        if !metadata.lensModel.isEmpty {
            args.append("-LensModel=\(metadata.lensModel)")
            args.append("-Lens=\(metadata.lensModel)")
        }
        if !metadata.lensMake.isEmpty {
            args.append("-LensMake=\(metadata.lensMake)")
        }

        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // 同期失敗時はネイティブ生成されたDNGのままで問題なし
        }
    }
}
