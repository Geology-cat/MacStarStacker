import Foundation
import ImageIO
import CoreImage

/// RAW画像から抽出されたレンズ情報および撮影メタデータを保持する構造体
public struct RawMetadataInfo: Sendable {
    // ── カメラ・本体情報 ──
    public var cameraMake: String = ""
    public var cameraModel: String = ""
    public var uniqueCameraModel: String = ""
    public var software: String = "MacStarStacker"
    
    // ── レンズ情報 ──
    public var lensMake: String = ""
    public var lensModel: String = ""
    public var lensSerialNumber: String = ""
    public var lensSpecification: [Double] = [] // [minFocal, maxFocal, minF, maxF]
    
    // ── 撮影パラメータ ──
    public var focalLength: Double? = nil
    public var focalLength35mm: Double? = nil
    public var fNumber: Double? = nil
    public var iso: Int? = nil
    public var exposureTime: Double? = nil
    public var dateTimeOriginal: String = ""
    
    // ── カラーマトリクス・DNGプロファイル情報 ──
    public var colorMatrix1: [Double]? = nil
    public var colorMatrix2: [Double]? = nil
    public var forwardMatrix1: [Double]? = nil
    public var forwardMatrix2: [Double]? = nil
    public var asShotNeutral: [Double]? = nil
    public var calibrationIlluminant1: Int = 17 // Standard Light A (2856K)
    public var calibrationIlluminant2: Int = 21 // D65 (6504K)
    public var profileName: String = "Adobe Standard"
    
    // ── 元ファイルのURL ──
    public var sourceURL: URL? = nil
    
    public init() {}
    
    /// レンズ情報のフォーマットされた表示名（例: "Sony FE 20mm F1.8 G (20mm, f/1.8)"）
    public var displayName: String {
        var parts: [String] = []
        if !lensModel.isEmpty {
            if !lensMake.isEmpty && !lensModel.lowercased().contains(lensMake.lowercased()) {
                parts.append("\(lensMake) \(lensModel)")
            } else {
                parts.append(lensModel)
            }
        } else if !cameraModel.isEmpty {
            parts.append(cameraModel)
        }
        
        var specs: [String] = []
        if let fl = focalLength {
            specs.append("\(Int(round(fl)))mm")
        }
        if let fn = fNumber {
            specs.append(String(format: "f/%.1f", fn))
        }
        if let iso = iso {
            specs.append("ISO \(iso)")
        }
        if let exp = exposureTime {
            if exp < 1.0 && exp > 0 {
                specs.append("1/\(Int(round(1.0 / exp)))s")
            } else if exp >= 1.0 {
                specs.append("\(String(format: "%.1f", exp))s")
            }
        }
        
        if specs.isEmpty {
            return parts.joined(separator: " ")
        } else {
            let specStr = specs.joined(separator: ", ")
            return parts.isEmpty ? specStr : "\(parts.joined(separator: " ")) (\(specStr))"
        }
    }
}

/// 各社RAWファイルからメタデータを抽出するクラス
public enum RawMetadataExtractor {
    
    /// 指定された画像URLからメタデータを包括的に抽出する
    public static func extract(from url: URL) -> RawMetadataInfo {
        var info = RawMetadataInfo()
        info.sourceURL = url
        
        // 1. ImageIO による解析
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            parseImageIOProperties(props, into: &info)
        }
        
        // 2. レンズ名やモデル名が不足している場合、ExifToolでさらに詳細に補完
        if info.lensModel.isEmpty || info.cameraModel.isEmpty {
            info = extractViaExifTool(from: url, fallback: info)
        }
        
        return info
    }
    
    // MARK: - ImageIO プロパティの解析
    private static func parseImageIOProperties(_ props: [String: Any], into info: inout RawMetadataInfo) {
        // TIFF タグ
        if let tiff = props["{TIFF}"] as? [String: Any] {
            if let make = tiff["Make"] as? String {
                info.cameraMake = make.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let model = tiff["Model"] as? String {
                info.cameraModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let date = tiff["DateTime"] as? String {
                info.dateTimeOriginal = date
            }
        }
        
        // EXIF タグ
        if let exif = props["{Exif}"] as? [String: Any] {
            if let lMake = exif["LensMake"] as? String {
                info.lensMake = lMake.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let lModel = exif["LensModel"] as? String {
                info.lensModel = lModel.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let lSerial = exif["LensSerialNumber"] as? String {
                info.lensSerialNumber = lSerial.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let lSpec = exif["LensSpecification"] as? [Any] {
                info.lensSpecification = lSpec.compactMap {
                    if let d = $0 as? Double { return d }
                    if let s = $0 as? String, let d = Double(s) { return d }
                    return nil
                }
            }
            if let fl = exif["FocalLength"] as? Double {
                info.focalLength = fl
            } else if let flStr = exif["FocalLength"] as? String, let fl = Double(flStr) {
                info.focalLength = fl
            }
            if let fl35 = exif["FocalLenIn35mmFilm"] as? Double {
                info.focalLength35mm = fl35
            } else if let fl35Int = exif["FocalLenIn35mmFilm"] as? Int {
                info.focalLength35mm = Double(fl35Int)
            }
            if let fn = exif["FNumber"] as? Double {
                info.fNumber = fn
            }
            if let isos = exif["ISOSpeedRatings"] as? [Int], let first = isos.first {
                info.iso = first
            } else if let iso = exif["ISOSpeedRatings"] as? Int {
                info.iso = iso
            }
            if let exp = exif["ExposureTime"] as? Double {
                info.exposureTime = exp
            }
            if let date = exif["DateTimeOriginal"] as? String {
                info.dateTimeOriginal = date
            }
        }
        
        // ExifAux タグ
        if let aux = props["{ExifAux}"] as? [String: Any] {
            if info.lensModel.isEmpty, let lModel = aux["LensModel"] as? String {
                info.lensModel = lModel.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if info.lensSpecification.isEmpty, let lInfo = aux["LensInfo"] as? [Any] {
                info.lensSpecification = lInfo.compactMap {
                    if let d = $0 as? Double { return d }
                    if let s = $0 as? String, let d = Double(s) { return d }
                    return nil
                }
            }
            if info.lensSerialNumber.isEmpty, let lSerial = aux["LensSerialNumber"] as? String {
                info.lensSerialNumber = lSerial.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // DNG タグ
        if let dng = props["{DNG}"] as? [String: Any] {
            if let ucm = dng["UniqueCameraModel"] as? String {
                info.uniqueCameraModel = ucm
            }
            if let cm1 = dng["ColorMatrix1"] as? [Any] {
                info.colorMatrix1 = cm1.compactMap { Double("\($0)") }
            }
            if let cm2 = dng["ColorMatrix2"] as? [Any] {
                info.colorMatrix2 = cm2.compactMap { Double("\($0)") }
            }
            if let fm1 = dng["ForwardMatrix1"] as? [Any] {
                info.forwardMatrix1 = fm1.compactMap { Double("\($0)") }
            }
            if let fm2 = dng["ForwardMatrix2"] as? [Any] {
                info.forwardMatrix2 = fm2.compactMap { Double("\($0)") }
            }
            if let asn = dng["AsShotNeutral"] as? [Any] {
                info.asShotNeutral = asn.compactMap { Double("\($0)") }
            }
            if let ci1 = dng["CalibrationIlluminant1"] as? Int {
                info.calibrationIlluminant1 = ci1
            }
            if let ci2 = dng["CalibrationIlluminant2"] as? Int {
                info.calibrationIlluminant2 = ci2
            }
            if let pn = dng["ProfileName"] as? String {
                info.profileName = pn
            }
        }
        
        // UniqueCameraModelの補完
        if info.uniqueCameraModel.isEmpty {
            if !info.cameraMake.isEmpty && !info.cameraModel.isEmpty {
                if info.cameraModel.lowercased().hasPrefix(info.cameraMake.lowercased()) {
                    info.uniqueCameraModel = info.cameraModel
                } else {
                    info.uniqueCameraModel = "\(info.cameraMake) \(info.cameraModel)"
                }
            } else if !info.cameraModel.isEmpty {
                info.uniqueCameraModel = info.cameraModel
            }
        }
    }
    
    // MARK: - ExifTool フォールバック・高度抽出
    private static func extractViaExifTool(from url: URL, fallback: RawMetadataInfo) -> RawMetadataInfo {
        var info = fallback
        let exiftoolPath = findExiftool()
        guard let toolPath = exiftoolPath else { return info }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = [
            "-j",
            "-LensMake", "-LensModel", "-Lens", "-LensID", "-LensInfo", "-LensSerialNumber", "-LensSpec",
            "-Make", "-Model", "-UniqueCameraModel",
            "-FocalLength", "-FocalLengthIn35mmFormat", "-FNumber", "-Aperture", "-ISO", "-ExposureTime",
            "-DateTimeOriginal",
            url.path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let dict = jsonArray.first {
                
                if info.lensModel.isEmpty {
                    if let l = dict["LensModel"] as? String ?? dict["Lens"] as? String ?? dict["LensID"] as? String {
                        info.lensModel = l.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if info.lensMake.isEmpty {
                    if let lm = dict["LensMake"] as? String {
                        info.lensMake = lm.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if info.lensSerialNumber.isEmpty {
                    if let ls = dict["LensSerialNumber"] as? String {
                        info.lensSerialNumber = ls.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if info.cameraMake.isEmpty, let m = dict["Make"] as? String {
                    info.cameraMake = m.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if info.cameraModel.isEmpty, let m = dict["Model"] as? String {
                    info.cameraModel = m.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if info.uniqueCameraModel.isEmpty, let ucm = dict["UniqueCameraModel"] as? String {
                    info.uniqueCameraModel = ucm
                }
                if info.focalLength == nil {
                    if let fl = dict["FocalLength"] as? Double {
                        info.focalLength = fl
                    } else if let flStr = dict["FocalLength"] as? String {
                        let numStr = flStr.replacingOccurrences(of: " mm", with: "").replacingOccurrences(of: "mm", with: "")
                        info.focalLength = Double(numStr)
                    }
                }
                if info.fNumber == nil {
                    if let fn = dict["FNumber"] as? Double ?? dict["Aperture"] as? Double {
                        info.fNumber = fn
                    }
                }
                if info.iso == nil, let iso = dict["ISO"] as? Int {
                    info.iso = iso
                }
                if info.exposureTime == nil {
                    if let exp = dict["ExposureTime"] as? Double {
                        info.exposureTime = exp
                    } else if let expStr = dict["ExposureTime"] as? String {
                        if expStr.contains("/") {
                            let parts = expStr.split(separator: "/")
                            if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
                                info.exposureTime = num / den
                            }
                        } else {
                            info.exposureTime = Double(expStr)
                        }
                    }
                }
            }
        } catch {
            // エラー時はフォールバックのまま返す
        }
        
        return info
    }
    
    /// 元画像の撮影情報（露出・レンズ・日時・GPS）だけを書き出しファイルへコピーする。
    ///
    /// `-all:all>all:all` の一括コピーは、元RAWのセンサー固有タグ（BlackLevel / WhiteLevel /
    /// CFAPattern / ActiveArea / DefaultCrop 等）や Orientation、センサーデータ前提のメーカーノートまで持ち込み、
    /// デモザイク済み・回転済みの書き出し画像と矛盾してAdobe製品で開けなくなる恐れがあるため、許可リスト方式にする。
    /// ExifToolが無い場合やコピーに失敗した場合は何もしない（ネイティブに書いたタグだけで有効なファイルになっている）。
    static func copyShootingMetadata(from sourceURL: URL, to targetURL: URL, extraArguments: [String] = []) {
        guard let exiftool = findExiftool() else { return }

        let copiedTags = [
            "-EXIF:ExposureTime", "-EXIF:FNumber", "-EXIF:ExposureProgram", "-EXIF:ISO",
            "-EXIF:DateTimeOriginal", "-EXIF:CreateDate", "-EXIF:OffsetTime*", "-EXIF:SubSecTime*",
            "-EXIF:ExposureCompensation", "-EXIF:MeteringMode", "-EXIF:Flash",
            "-EXIF:FocalLength", "-EXIF:FocalLengthIn35mmFormat",
            "-EXIF:LensInfo", "-EXIF:LensMake", "-EXIF:LensModel", "-EXIF:LensSerialNumber",
            "-EXIF:SerialNumber", "-EXIF:Artist", "-EXIF:Copyright",
            "-GPS:all"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftool)
        // タグ代入は -tagsFromFile のコピーより後ろに置くことで、コピー結果を上書きできる。
        process.arguments = ["-tagsFromFile", sourceURL.path] + copiedTags + extraArguments
            + ["-overwrite_original", targetURL.path]
        // 読み出さないパイプはバッファが埋まるとwaitUntilExitが戻らなくなるため、出力は破棄する。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // 同期失敗時はネイティブ生成されたファイルのままで問題なし
            // （-overwrite_original は書き込み成功時のみ置換するため、失敗しても元ファイルは壊れない）
        }
    }

    /// システム上の exiftool の実行可能パスを探す
    public static func findExiftool() -> String? {
        let candidates = [
            "/usr/local/bin/exiftool",
            "/opt/homebrew/bin/exiftool",
            "/usr/bin/exiftool"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
