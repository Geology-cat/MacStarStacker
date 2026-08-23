import AppKit
import Foundation

/// macOS標準画像とFITSを同じ経路で読み込む。
enum ImageLoader {
    static func load(from url: URL) -> NSImage? {
        switch url.pathExtension.lowercased() {
        case "fit", "fits":
            return FITSImageReader.load(from: url)
        default:
            return NSImage(contentsOf: url)
        }
    }
}

private enum FITSImageReader {
    private struct Header {
        let width: Int
        let height: Int
        let channels: Int
        let bitpix: Int
        let bscale: Double
        let bzero: Double
        let dataMinimum: Double?
        let dataMaximum: Double?
        let dataOffset: Int
    }

    static func load(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let header = parseHeader(data),
              header.width > 0,
              header.height > 0,
              header.channels == 1 || header.channels == 3,
              header.width <= Int.max / header.height else { return nil }

        let planePixels = header.width * header.height
        guard planePixels <= Int.max / header.channels else { return nil }
        let sampleCount = planePixels * header.channels
        let bytesPerSample = abs(header.bitpix) / 8
        guard bytesPerSample > 0,
              sampleCount <= (data.count - header.dataOffset) / bytesPerSample else { return nil }

        let range = displayRange(header: header, data: data, sampleCount: sampleCount)
        guard range.maximum > range.minimum else { return nil }
        let scale = 1.0 / (range.maximum - range.minimum)

        var rgba = [UInt16](repeating: UInt16.max, count: planePixels * 4)
        for outputY in 0..<header.height {
            // FITSの先頭行は画像下端なので、AppKit用に上下を戻す。
            let fitsY = header.height - 1 - outputY
            for x in 0..<header.width {
                let planeIndex = fitsY * header.width + x
                let outputIndex = (outputY * header.width + x) * 4
                if header.channels == 1 {
                    let value = normalizedValue(
                        sample(at: planeIndex, header: header, data: data),
                        minimum: range.minimum,
                        scale: scale
                    )
                    rgba[outputIndex] = value
                    rgba[outputIndex + 1] = value
                    rgba[outputIndex + 2] = value
                } else {
                    for channel in 0..<3 {
                        rgba[outputIndex + channel] = normalizedValue(
                            sample(at: channel * planePixels + planeIndex, header: header, data: data),
                            minimum: range.minimum,
                            scale: scale
                        )
                    }
                }
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        let image = rgba.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: header.width,
                    height: header.height,
                    bitsPerComponent: 16,
                    bytesPerRow: header.width * 8,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder16Little.rawValue
                  ) else { return nil }
            return context.makeImage()
        }
        guard let image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: header.width, height: header.height))
    }

    private static func parseHeader(_ data: Data) -> Header? {
        var values: [String: String] = [:]
        var offset = 0
        var dataOffset: Int?

        while offset + 80 <= data.count {
            let cardData = data.subdata(in: offset..<(offset + 80))
            guard let card = String(data: cardData, encoding: .ascii) else { return nil }
            let keyword = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
            if keyword == "END" {
                dataOffset = ((offset + 80 + 2879) / 2880) * 2880
                break
            }
            if card.count >= 10, card[card.index(card.startIndex, offsetBy: 8)] == "=" {
                let rawValue = String(card.dropFirst(10))
                let value = rawValue.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rawValue
                values[keyword] = value.trimmingCharacters(in: .whitespaces)
            }
            offset += 80
        }

        guard values["SIMPLE"]?.hasPrefix("T") == true,
              let width = values["NAXIS1"].flatMap(Int.init),
              let height = values["NAXIS2"].flatMap(Int.init),
              let bitpix = values["BITPIX"].flatMap(Int.init),
              [8, 16, 32, -32, -64].contains(bitpix),
              let dataOffset,
              dataOffset <= data.count else { return nil }

        let axisCount = values["NAXIS"].flatMap(Int.init) ?? 2
        let channels = axisCount >= 3 ? (values["NAXIS3"].flatMap(Int.init) ?? 1) : 1
        return Header(
            width: width,
            height: height,
            channels: channels,
            bitpix: bitpix,
            bscale: parseDouble(values["BSCALE"]) ?? 1,
            bzero: parseDouble(values["BZERO"]) ?? 0,
            dataMinimum: parseDouble(values["DATAMIN"]),
            dataMaximum: parseDouble(values["DATAMAX"]),
            dataOffset: dataOffset
        )
    }

    private static func parseDouble(_ value: String?) -> Double? {
        value.flatMap { Double($0.replacingOccurrences(of: "D", with: "E")) }
    }

    private static func sample(at index: Int, header: Header, data: Data) -> Double {
        let bytesPerSample = abs(header.bitpix) / 8
        let offset = header.dataOffset + index * bytesPerSample
        let raw: Double
        switch header.bitpix {
        case 8:
            raw = Double(data[offset])
        case 16:
            let bits = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            raw = Double(Int16(bitPattern: bits))
        case 32:
            let bits = UInt32(data[offset]) << 24
                | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8
                | UInt32(data[offset + 3])
            raw = Double(Int32(bitPattern: bits))
        case -32:
            let bits = UInt32(data[offset]) << 24
                | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8
                | UInt32(data[offset + 3])
            raw = Double(Float(bitPattern: bits))
        case -64:
            var bits: UInt64 = 0
            for byte in data[offset..<(offset + 8)] {
                bits = (bits << 8) | UInt64(byte)
            }
            raw = Double(bitPattern: bits)
        default:
            return 0
        }
        return raw * header.bscale + header.bzero
    }

    private static func displayRange(
        header: Header,
        data: Data,
        sampleCount: Int
    ) -> (minimum: Double, maximum: Double) {
        if let minimum = header.dataMinimum,
           let maximum = header.dataMaximum,
           maximum > minimum {
            return (minimum, maximum)
        }

        switch header.bitpix {
        case 8:
            return sortedRange(0 * header.bscale + header.bzero, 255 * header.bscale + header.bzero)
        case 16:
            return sortedRange(
                Double(Int16.min) * header.bscale + header.bzero,
                Double(Int16.max) * header.bscale + header.bzero
            )
        case 32:
            return sortedRange(
                Double(Int32.min) * header.bscale + header.bzero,
                Double(Int32.max) * header.bscale + header.bzero
            )
        default:
            var minimum = Double.infinity
            var maximum = -Double.infinity
            for index in 0..<sampleCount {
                let value = sample(at: index, header: header, data: data)
                guard value.isFinite else { continue }
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
            if minimum >= 0, maximum <= 1 { return (0, 1) }
            return maximum > minimum ? (minimum, maximum) : (0, 1)
        }
    }

    private static func sortedRange(_ first: Double, _ second: Double) -> (minimum: Double, maximum: Double) {
        first <= second ? (first, second) : (second, first)
    }

    private static func normalizedValue(_ value: Double, minimum: Double, scale: Double) -> UInt16 {
        guard value.isFinite else { return 0 }
        let normalized = min(1, max(0, (value - minimum) * scale))
        return UInt16((normalized * Double(UInt16.max)).rounded())
    }
}
