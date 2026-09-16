import Foundation
import CoreGraphics
import LibRawBridge

/// LibRawから得たRAWファイルのセンサー情報
struct RawSensorInfo: Equatable {
    let width: Int
    let height: Int
    /// 2x2ベイヤー配列を持つか（X-Trans・デモザイク済みDNG等は false）
    let isBayer: Bool
    /// 有効画素領域の左上 (0,0) (0,1) (1,0) (1,1) の色。0=R, 1=G, 2=B
    let cfaPattern: [UInt8]
    /// LibRawのflip値
    let flip: Int
    /// cfaPattern と同じ並びの黒レベル（生の値）
    let blackLevels: [Double]
    /// 白レベル（生の値）
    let whiteLevel: Double
    /// XYZ → カメラRGB（DNGのColorMatrix）
    let colorMatrix1: [Double]
    let illuminant1: Int
    let colorMatrix2: [Double]?
    let illuminant2: Int
    /// 撮影時ホワイトバランス係数（R, G, B。G=1）
    let cameraMultipliers: [Double]
    let make: String
    let model: String

    /// DNG/EXIFのOrientation値
    var orientation: UInt16 {
        switch flip {
        case 3: return 3
        case 5: return 8
        case 6: return 6
        default: return 1
        }
    }

    /// DNGのAsShotNeutral（ホワイトバランス係数の逆数）
    var asShotNeutral: [Double] {
        cameraMultipliers.map { $0 > 0 ? 1.0 / $0 : 1.0 }
    }

    /// Adobeのカメラ別プロファイルと照合される名前（例: "Canon EOS 6D"）
    var uniqueCameraModel: String {
        let trimmedMake = make.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        if trimmedMake.isEmpty { return trimmedModel }
        if trimmedModel.lowercased().hasPrefix(trimmedMake.lowercased()) { return trimmedModel }
        return "\(trimmedMake) \(trimmedModel)"
    }

    /// 同じセンサー配置として合成できるか（寸法・CFA位相・向きが一致）
    func isStackCompatible(with other: RawSensorInfo) -> Bool {
        width == other.width && height == other.height && isBayer == other.isBayer
            && cfaPattern == other.cfaPattern && flip == other.flip
    }
}

/// ベイヤー配列の生データ（黒レベルを含む生の値、有効画素領域のみ）
struct BayerFrame {
    let info: RawSensorInfo
    var pixels: [UInt16]
}

/// カメラ色空間のままデモザイクした16bitリニアRGB（黒レベル除去済み、白=65535、ホワイトバランスなし）
struct CameraRGBFrame {
    let info: RawSensorInfo
    let width: Int
    let height: Int
    var pixels: [UInt16]

    /// センサー飽和に相当する出力値。LibRawは黒レベルを引いた値を「白レベル」で割って65535倍するため、
    /// 実際の飽和は 65535 × (白 − 黒) ÷ 白 になる（DNGのWhiteLevelに書く）。
    var whiteLevel: Double {
        let black = info.blackLevels.reduce(0, +) / Double(max(1, info.blackLevels.count))
        guard info.whiteLevel > black else { return 65535 }
        return 65535.0 * (info.whiteLevel - black) / info.whiteLevel
    }
}

enum RawDecoder {
    struct DecodeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// LibRawで扱うRAWの拡張子（一般画像やFITSはこの経路に乗せない）
    static let rawExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "dng", "pef"]

    static func isRawFile(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    static func readInfo(from url: URL) throws -> RawSensorInfo {
        var info = LRRawInfo()
        var message = [CChar](repeating: 0, count: 256)
        let code = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return LRReadInfo(path, &info, &message, Int32(message.count))
        }
        guard code == 0 else { throw DecodeError(message: errorText(message, url: url)) }
        return RawSensorInfo(info)
    }

    static func readBayer(from url: URL) throws -> BayerFrame {
        var info = LRRawInfo()
        var message = [CChar](repeating: 0, count: 256)
        var output: UnsafeMutablePointer<UInt16>?
        let code = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return LRReadBayer(path, &info, &output, &message, Int32(message.count))
        }
        guard code == 0, let output else { throw DecodeError(message: errorText(message, url: url)) }
        defer { LRFree(output) }
        let sensor = RawSensorInfo(info)
        let pixels = Array(UnsafeBufferPointer(start: output, count: sensor.width * sensor.height))
        return BayerFrame(info: sensor, pixels: pixels)
    }

    /// カメラ色空間のままデモザイクする。replacementBayer を渡すと、その生データ（キャリブレーション済み等）を現像する。
    static func demosaicCameraRGB(from url: URL, replacementBayer: [UInt16]? = nil) throws -> CameraRGBFrame {
        var info = LRRawInfo()
        var message = [CChar](repeating: 0, count: 256)
        var output: UnsafeMutablePointer<UInt16>?
        var width: Int32 = 0
        var height: Int32 = 0
        let code = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            if let replacementBayer {
                return replacementBayer.withUnsafeBufferPointer { replacement in
                    LRDemosaicCameraRGB(path, replacement.baseAddress, &info, &output, &width, &height, &message, Int32(message.count))
                }
            }
            return LRDemosaicCameraRGB(path, nil, &info, &output, &width, &height, &message, Int32(message.count))
        }
        guard code == 0, let output else { throw DecodeError(message: errorText(message, url: url)) }
        defer { LRFree(output) }
        let count = Int(width) * Int(height) * 3
        let pixels = Array(UnsafeBufferPointer(start: output, count: count))
        return CameraRGBFrame(info: RawSensorInfo(info), width: Int(width), height: Int(height), pixels: pixels)
    }

    /// 撮影時ホワイトバランス・sRGBで現像した16bit RGB（センサーの向き）を CGImage として返す。
    static func renderSRGB(from url: URL, exposure: Double = 0) throws -> CGImage {
        var message = [CChar](repeating: 0, count: 256)
        var output: UnsafeMutablePointer<UInt16>?
        var width: Int32 = 0
        var height: Int32 = 0
        let code = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return LRRenderSRGB(path, pow(2.0, exposure), &output, &width, &height, &message, Int32(message.count))
        }
        guard code == 0, let output else { throw DecodeError(message: errorText(message, url: url)) }
        defer { LRFree(output) }
        let data = Data(bytes: output, count: Int(width) * Int(height) * 3 * MemoryLayout<UInt16>.size)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: Int(width), height: Int(height), bitsPerComponent: 16, bitsPerPixel: 48,
                bytesPerRow: Int(width) * 6, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else {
            throw DecodeError(message: "現像結果の画像を作成できませんでした: \(url.lastPathComponent)")
        }
        return image
    }

    private static func errorText(_ message: [CChar], url: URL) -> String {
        let text = String(cString: message)
        return text.isEmpty ? "RAWを読み込めませんでした: \(url.lastPathComponent)" : "\(text): \(url.lastPathComponent)"
    }
}

private extension RawSensorInfo {
    init(_ info: LRRawInfo) {
        func array<T, U>(_ tuple: T, count: Int, as type: U.Type) -> [U] {
            withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: U.self).prefix(count)) }
        }
        func string<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
        }
        self.init(
            width: Int(info.width),
            height: Int(info.height),
            isBayer: info.isBayer != 0,
            cfaPattern: array(info.cfaPattern, count: 4, as: UInt8.self),
            flip: Int(info.flip),
            blackLevels: array(info.blackLevel, count: 4, as: Double.self),
            whiteLevel: info.whiteLevel,
            colorMatrix1: array(info.colorMatrix1, count: 9, as: Double.self),
            illuminant1: Int(info.illuminant1),
            colorMatrix2: info.hasColorMatrix2 != 0 ? array(info.colorMatrix2, count: 9, as: Double.self) : nil,
            illuminant2: Int(info.illuminant2),
            cameraMultipliers: array(info.cameraMultipliers, count: 3, as: Double.self),
            make: string(info.make),
            model: string(info.model)
        )
    }
}

extension RawSensorInfo {
    /// DNG書き出し用のベイヤー配列情報
    var bayerMosaic: DNGWriter.BayerMosaic {
        DNGWriter.BayerMosaic(pattern: cfaPattern, blackLevels: blackLevels, whiteLevel: whiteLevel)
    }

    /// DNG書き出し用の実カメラ色情報
    /// - Parameter baselineExposure: 機種ごとの露出基準（EV）。CIRAWFilter の baselineExposure 等から与える。
    func cameraColorProfile(baselineExposure: Double = 0) -> DNGWriter.CameraColorProfile {
        DNGWriter.CameraColorProfile(
            make: make,
            model: model,
            uniqueCameraModel: uniqueCameraModel,
            colorMatrix1: colorMatrix1,
            illuminant1: illuminant1,
            colorMatrix2: colorMatrix2,
            illuminant2: illuminant2,
            asShotNeutral: asShotNeutral,
            orientation: orientation,
            baselineExposure: baselineExposure
        )
    }
}
