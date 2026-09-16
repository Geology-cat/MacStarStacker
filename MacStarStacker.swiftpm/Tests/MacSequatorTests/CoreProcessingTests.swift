import XCTest
import AppKit
@testable import MacSequator

final class CoreProcessingTests: XCTestCase {
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }

    private func makeImage(width: Int, height: Int, pixel: (UInt8, UInt8, UInt8, UInt8)) -> NSImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = pixel.0
            pixels[index + 1] = pixel.1
            pixels[index + 2] = pixel.2
            pixels[index + 3] = pixel.3
        }
        return makeImage(width: width, height: height, pixels: pixels)
    }

    private func makeImage(width: Int, height: Int, pixels: [UInt8]) -> NSImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    private func rgba(_ image: NSImage, x: Int = 0, y: Int = 0) -> (UInt8, UInt8, UInt8, UInt8) {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(
            data: &pixels, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let index = (y * cg.width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }

    func testAverageAndEvenMedianAreCalculatedCorrectly() throws {
        let low = makeImage(width: 2, height: 2, pixel: (20, 40, 60, 255))
        let high = makeImage(width: 2, height: 2, pixel: (100, 120, 140, 255))

        let average = try XCTUnwrap(ImageStacker.stack(images: [low, high], mode: .average))
        let median = try XCTUnwrap(ImageStacker.stack(images: [low, high], mode: .median))
        let averageValue = rgba(average)
        let medianValue = rgba(median)
        XCTAssertEqual(averageValue.0, medianValue.0, accuracy: 1)
        XCTAssertEqual(averageValue.1, medianValue.1, accuracy: 1)
        XCTAssertEqual(averageValue.2, medianValue.2, accuracy: 1)
        XCTAssertEqual(averageValue.3, 255)
        XCTAssertEqual(average.cgImage(forProposedRect: nil, context: nil, hints: nil)?.bitsPerComponent, 16)
    }

    func testStackRejectsMismatchedDimensions() {
        let small = makeImage(width: 2, height: 2, pixel: (10, 10, 10, 255))
        let large = makeImage(width: 3, height: 2, pixel: (20, 20, 20, 255))
        XCTAssertNil(ImageStacker.stack(images: [small, large], mode: .average))
    }

    func testMetalAverageStackerLoadsBundledShader() throws {
        let stacker = try XCTUnwrap(MetalStacker.create())
        let low = makeImage(width: 8, height: 8, pixel: (20, 40, 60, 255))
        let high = makeImage(width: 8, height: 8, pixel: (100, 120, 140, 255))
        let result = try XCTUnwrap(stacker.stackAverage(images: [low, high]))
        let cpuResult = try XCTUnwrap(ImageStacker.stack(images: [low, high], mode: .average))
        let gpuValue = rgba(result)
        let cpuValue = rgba(cpuResult)
        XCTAssertEqual(gpuValue.0, cpuValue.0, accuracy: 1)
        XCTAssertEqual(gpuValue.1, cpuValue.1, accuracy: 1)
        XCTAssertEqual(gpuValue.2, cpuValue.2, accuracy: 1)
        XCTAssertEqual(gpuValue.3, 255)
        XCTAssertEqual(result.cgImage(forProposedRect: nil, context: nil, hints: nil)?.bitsPerComponent, 16)
    }

    func testCalibrationDoesNotDoubleSubtractBiasAndKeepsAlphaOpaque() throws {
        let light = makeImage(width: 2, height: 2, pixel: (200, 180, 160, 255))
        let dark = makeImage(width: 2, height: 2, pixel: (50, 40, 30, 255))
        let bias = makeImage(width: 2, height: 2, pixel: (10, 10, 10, 255))
        let resultWithBias = try XCTUnwrap(CalibrationProcessor.calibrate(
            light: light, masterBias: bias, masterDark: dark, masterFlat: nil
        ))
        let resultWithDarkOnly = try XCTUnwrap(CalibrationProcessor.calibrate(
            light: light, masterBias: nil, masterDark: dark, masterFlat: nil
        ))
        let withBias = rgba(resultWithBias)
        let darkOnly = rgba(resultWithDarkOnly)
        XCTAssertEqual(withBias.0, darkOnly.0, accuracy: 1)
        XCTAssertEqual(withBias.1, darkOnly.1, accuracy: 1)
        XCTAssertEqual(withBias.2, darkOnly.2, accuracy: 1)
        XCTAssertEqual(withBias.3, 255)
        XCTAssertEqual(resultWithBias.cgImage(forProposedRect: nil, context: nil, hints: nil)?.bitsPerComponent, 16)
    }

    func testCalibrationRejectsMismatchedMasterSize() {
        let light = makeImage(width: 2, height: 2, pixel: (200, 200, 200, 255))
        let dark = makeImage(width: 3, height: 2, pixel: (10, 10, 10, 255))
        XCTAssertNil(CalibrationProcessor.calibrate(light: light, masterDark: dark))
    }

    func testSkyGroundBlendUsesGreenAsGroundAndBlueAsSky() throws {
        let width = 80, height = 20
        let sky = makeImage(width: width, height: height, pixel: (10, 20, 220, 255))
        let ground = makeImage(width: width, height: height, pixel: (20, 210, 30, 255))
        var maskPixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if x < width / 2 {
                    maskPixels[index + 1] = 255
                } else {
                    maskPixels[index + 2] = 255
                }
                maskPixels[index + 3] = 255
            }
        }
        let mask = makeImage(width: width, height: height, pixels: maskPixels)
        let result = try XCTUnwrap(StackingStateController.blendSkyGround(
            skyImage: sky, groundImage: ground, mask: mask
        ))

        let left = rgba(result, x: 5, y: height / 2)
        let right = rgba(result, x: width - 6, y: height / 2)
        XCTAssertGreaterThan(left.1, left.2)
        XCTAssertGreaterThan(right.2, right.1)
        XCTAssertEqual(result.cgImage(forProposedRect: nil, context: nil, hints: nil)?.bitsPerComponent, 16)
    }

    func testSkyGroundBlendFeatherRadiusIsAdjustable() throws {
        let width = 120, height = 24
        let sky = makeImage(width: width, height: height, pixel: (10, 20, 220, 255))
        let ground = makeImage(width: width, height: height, pixel: (20, 210, 30, 255))
        var maskPixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                maskPixels[index + (x < width / 2 ? 1 : 2)] = 255
                maskPixels[index + 3] = 255
            }
        }
        let mask = makeImage(width: width, height: height, pixels: maskPixels)
        let hard = try XCTUnwrap(StackingStateController.blendSkyGround(
            skyImage: sky,
            groundImage: ground,
            mask: mask,
            featherRadius: 0
        ))
        let soft = try XCTUnwrap(StackingStateController.blendSkyGround(
            skyImage: sky,
            groundImage: ground,
            mask: mask,
            featherRadius: 16
        ))

        let hardSkySide = rgba(hard, x: width / 2 + 4, y: height / 2)
        let softSkySide = rgba(soft, x: width / 2 + 4, y: height / 2)
        let hardGroundSide = rgba(hard, x: width / 2 - 5, y: height / 2)
        let softGroundSide = rgba(soft, x: width / 2 - 5, y: height / 2)
        XCTAssertGreaterThan(hardSkySide.2, hardSkySide.1)
        XCTAssertGreaterThan(softSkySide.1, hardSkySide.1 + 20, "ぼかし半径を上げても境界が混合されていません")
        XCTAssertGreaterThan(softSkySide.2, softSkySide.1, "境界ぼかしが地上側へ反転しています")
        XCTAssertGreaterThan(hardGroundSide.1, hardGroundSide.2)
        XCTAssertGreaterThan(softGroundSide.2, hardGroundSide.2 + 20, "地上側の境界がぼかされていません")
        XCTAssertGreaterThan(softGroundSide.1, softGroundSide.2, "境界ぼかしが空側へ反転しています")

        let farGround = rgba(soft, x: 8, y: height / 2)
        let farSky = rgba(soft, x: width - 9, y: height / 2)
        XCTAssertGreaterThan(farGround.1, farGround.2)
        XCTAssertGreaterThan(farSky.2, farSky.1)
    }

    func testMaskBufferExistsOnlyWhileEditingIsEnabled() {
        StackingStateController.shared.maskBitmap = nil
        let view = MaskCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        view.currentImage = makeImage(width: 64, height: 48, pixel: (20, 30, 40, 255))
        XCTAssertFalse(view.hasAllocatedMaskBuffer)

        view.isMaskEditingEnabled = true
        XCTAssertTrue(view.hasAllocatedMaskBuffer)

        view.isMaskEditingEnabled = false
        XCTAssertFalse(view.hasAllocatedMaskBuffer)
    }

    func testMaskBrushPaintsAtPointerPositionWithoutVerticalMirroring() throws {
        let state = StackingStateController.shared
        let previousMask = state.maskBitmap
        let previousMode = state.brushMode
        let previousSize = state.brushSize
        defer {
            state.maskBitmap = previousMask
            state.brushMode = previousMode
            state.brushSize = previousSize
        }

        state.maskBitmap = nil
        state.brushMode = .ground
        state.brushSize = 12

        let canvas = MaskCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        canvas.currentImage = makeImage(width: 100, height: 100, pixel: (30, 30, 30, 255))
        canvas.isMaskEditingEnabled = true

        let viewPoint = CGPoint(x: 25, y: 20)
        let imagePoint = try XCTUnwrap(canvas.viewToImagePoint(viewPoint))
        canvas.paint(at: imagePoint, from: imagePoint)
        canvas.exportMaskBitmap()

        let mask = try XCTUnwrap(state.maskBitmap)
        let sky = makeImage(width: 100, height: 100, pixel: (20, 30, 220, 255))
        let ground = makeImage(width: 100, height: 100, pixel: (20, 220, 30, 255))
        let result = try XCTUnwrap(StackingStateController.blendSkyGround(
            skyImage: sky,
            groundImage: ground,
            mask: mask
        ))
        let paintedPosition = rgba(result, x: 25, y: 20)
        let verticallyMirroredPosition = rgba(result, x: 25, y: 80)
        XCTAssertGreaterThan(paintedPosition.1, paintedPosition.2, "ブラシ位置に地上マスクが反映されていません")
        XCTAssertGreaterThan(verticallyMirroredPosition.2, verticallyMirroredPosition.1, "上下反対の位置がマスクされています")
    }

    func testMaskCoordinateConversionIncludesLetterboxingZoomAndPan() throws {
        let canvas = MaskCanvasView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        canvas.currentImage = makeImage(width: 100, height: 100, pixel: (30, 30, 30, 255))
        canvas.zoomScale = 2
        canvas.panOffset = CGPoint(x: 20, y: -10)

        // 100×100画像は200×200にフィットし、2倍ズームとパン後の描画原点は(-30, -110)。
        let converted = try XCTUnwrap(canvas.viewToImagePoint(CGPoint(x: 70, y: 190)))
        XCTAssertEqual(converted.x, 25, accuracy: 0.001)
        XCTAssertEqual(converted.y, 75, accuracy: 0.001)
        XCTAssertNil(canvas.viewToImagePoint(CGPoint(x: 450, y: 10)))
    }

    func testMaskFeatherControlTracksEditingStateAndUpdatesRadius() throws {
        let state = StackingStateController.shared
        let previousEnabled = state.enableSkyGroundMask
        let previousRadius = state.maskFeatherRadius
        defer {
            state.enableSkyGroundMask = previousEnabled
            state.maskFeatherRadius = previousRadius
        }

        state.enableSkyGroundMask = false
        state.maskFeatherRadius = 27
        let controller = SettingsViewController()
        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let views = allSubviews(of: controller.view)
        let slider = try XCTUnwrap(views.compactMap { $0 as? NSSlider }.first {
            $0.identifier?.rawValue == "MaskFeatherSlider"
        })
        let label = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "MaskFeatherLabel"
        })
        XCTAssertFalse(slider.isEnabled)
        XCTAssertEqual(slider.doubleValue, 27, accuracy: 0.001)
        XCTAssertEqual(label.stringValue, "27 px")

        state.enableSkyGroundMask = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(slider.isEnabled)
        slider.doubleValue = 41
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertEqual(state.maskFeatherRadius, 41, accuracy: 0.001)
        XCTAssertEqual(label.stringValue, "41 px")
    }

    func testDurationModeCalculatesRequestedPlaybackSpeed() {
        var settings = TimelapseSettings()
        settings.startFrame = 0
        settings.endFrame = 239
        settings.durationMode = .duration
        settings.targetDuration = 10
        XCTAssertEqual(settings.effectiveFrameCount, 240)
        XCTAssertEqual(settings.effectiveFps, 24, accuracy: 0.001)
        XCTAssertEqual(settings.estimatedDuration, 10, accuracy: 0.001)
    }

    private struct TIFFEntry {
        let type: Int
        let count: Int
        let value: Int
    }

    /// IFDのエントリを読み、タグが昇順に並んでいることも検証する。
    private func readIFD(_ data: Data, at offset: Int, file: StaticString = #filePath, line: UInt = #line) -> [Int: TIFFEntry] {
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var entries: [Int: TIFFEntry] = [:]
        var previousTag = -1
        for index in 0..<u16(offset) {
            let entry = offset + 2 + index * 12
            let tag = u16(entry)
            XCTAssertGreaterThan(tag, previousTag, "IFDのタグは昇順である必要があります", file: file, line: line)
            previousTag = tag
            entries[tag] = TIFFEntry(type: u16(entry + 2), count: u32(entry + 4), value: u32(entry + 8))
        }
        return entries
    }

    /// Adobe製リニアDNGと同じ構成（IFD0サムネイル + 主画像SubIFD + JPEGプレビューSubIFD）と、
    /// Camera Raw / Lightroom がアプリ表示と同じ色で現像するための埋め込みプロファイルを検証する。
    func testDNGMatchesAdobeLinearDNGLayoutAndEmbedsNeutralProfile() throws {
        let width = 300, height = 200
        let image = makeImage(width: width, height: height, pixel: (200, 40, 40, 255))
        var metadata = RawMetadataInfo()
        metadata.cameraMake = "SONY"
        metadata.cameraModel = "ILCE-7M4"
        metadata.uniqueCameraModel = "Sony ILCE-7M4"
        metadata.lensModel = "FE 20mm F1.8 G"
        metadata.lensSpecification = [20, 20, 1.8, 1.8]
        metadata.dateTimeOriginal = "2026:08:01 22:00:00.123+09:00"
        // 元カメラの行列が渡されても、書き出しは標準sRGB行列を使うこと
        metadata.colorMatrix1 = [1, 0, 0, 0]
        metadata.asShotNeutral = [0, 0, 0]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGWriter.write(image: image, metadata: metadata, embedLensProfile: true, to: url)

        let data = try Data(contentsOf: url)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        XCTAssertEqual(Array(data.prefix(4)), [0x49, 0x49, 0x2A, 0x00])
        let ifd0Offset = u32(4)
        XCTAssertEqual(ifd0Offset, 8, "IFD0はファイル先頭に置く（macOSのサムネイル生成が埋め込みプレビューを見つけられるように）")
        let ifd0 = readIFD(data, at: ifd0Offset)

        // IFD0: 8bit RGB サムネイル
        XCTAssertEqual(ifd0[254]?.value, 1, "IFD0はサムネイル（NewSubFileType=1）")
        XCTAssertEqual(ifd0[262]?.value, 2, "サムネイルはRGB")
        XCTAssertEqual(ifd0[256]?.value, 256)
        let thumbnailOffset = try XCTUnwrap(ifd0[273]).value
        XCTAssertEqual(ifd0[279]?.value, (ifd0[256]?.value ?? 0) * (ifd0[257]?.value ?? 0) * 3)
        XCTAssertEqual(Int(data[thumbnailOffset]), 200, accuracy: 2, "サムネイルはsRGB（アプリ表示と同じ値）")
        XCTAssertEqual(Int(data[thumbnailOffset + 1]), 40, accuracy: 2)

        // 埋め込みカメラプロファイル（Adobeのカメラ別プロファイル・既定トーンカーブを使わせない）
        XCTAssertEqual(ifd0[0xC612]?.count, 4, "DNGVersion")
        let uniqueModel = try XCTUnwrap(ifd0[0xC614])
        let uniqueModelString = String(data: data.subdata(in: uniqueModel.value..<(uniqueModel.value + uniqueModel.count - 1)), encoding: .utf8)
        XCTAssertEqual(uniqueModelString, DNGWriter.uniqueCameraModel, "実カメラ名をUniqueCameraModelにしない")
        XCTAssertEqual(ifd0[0xC621]?.count, 9, "ColorMatrix1")
        XCTAssertEqual(ifd0[0xC714]?.count, 9, "ForwardMatrix1")
        XCTAssertEqual(ifd0[0xC65A]?.value, 21, "CalibrationIlluminant1 は D65")
        XCTAssertNil(ifd0[0xC622], "ColorMatrix2は書かない")
        let toneCurve = try XCTUnwrap(ifd0[0xC6FC], "ProfileToneCurve")
        XCTAssertEqual(toneCurve.type, 11)
        XCTAssertEqual(toneCurve.count, 4)
        let curve = (0..<4).map { Float(bitPattern: UInt32(u32(toneCurve.value + $0 * 4))) }
        XCTAssertEqual(curve, [0, 0, 1, 1], "トーンカーブは直線")
        XCTAssertEqual(ifd0[0xC7A6]?.value, 1, "DefaultBlackRender=None")
        XCTAssertEqual(ifd0[0xC71A]?.value, 2, "PreviewColorSpace=sRGB")
        XCTAssertNotNil(ifd0[0xC6F8], "ProfileName")
        let neutral = try XCTUnwrap(ifd0[0xC628])
        XCTAssertEqual(neutral.count, 3)
        for plane in 0..<3 {
            XCTAssertGreaterThan(u32(neutral.value + plane * 8), 0, "AsShotNeutralは正の値である必要があります")
        }
        XCTAssertEqual(ifd0[306]?.count, 20, "DateTimeは19文字+NUL")

        // SubIFD: [主画像, プレビュー]
        let subIFDs = try XCTUnwrap(ifd0[330])
        XCTAssertEqual(subIFDs.count, 2)
        let rawIFDOffset = u32(subIFDs.value)
        let previewIFDOffset = u32(subIFDs.value + 4)
        let raw = readIFD(data, at: rawIFDOffset)
        XCTAssertEqual(raw[254]?.value, 0, "主画像はNewSubFileType=0")
        XCTAssertEqual(raw[262]?.value, 34892, "PhotometricInterpretation は LinearRaw")
        XCTAssertEqual(raw[277]?.value, 3)
        XCTAssertEqual(raw[256]?.value, width)
        XCTAssertEqual(raw[257]?.value, height)
        let strips = try XCTUnwrap(raw[273])
        let stripCounts = try XCTUnwrap(raw[279])
        let stripOffsets = strips.count == 1 ? [strips.value] : (0..<strips.count).map { u32(strips.value + $0 * 4) }
        let stripBytes = stripCounts.count == 1 ? [stripCounts.value] : (0..<stripCounts.count).map { u32(stripCounts.value + $0 * 4) }
        XCTAssertEqual(stripBytes.reduce(0, +), width * height * 6)
        XCTAssertLessThanOrEqual(stripOffsets.last! + stripBytes.last!, data.count)
        XCTAssertGreaterThan(stripOffsets[0], max(rawIFDOffset, previewIFDOffset), "画素データはIFDより後ろに置く")
        // sRGB 200 → リニア約0.578
        XCTAssertEqual(Double(u16(stripOffsets[0])) / 65535.0, 0.578, accuracy: 0.01, "主画像はリニアsRGB")

        let previewIFD = readIFD(data, at: previewIFDOffset)
        XCTAssertEqual(previewIFD[254]?.value, 1)
        XCTAssertEqual(previewIFD[259]?.value, 7, "プレビューはJPEG")
        XCTAssertEqual(previewIFD[0xC71A]?.value, 2, "PreviewColorSpace=sRGB")
        let jpegOffset = try XCTUnwrap(previewIFD[273]).value
        XCTAssertEqual(Array(data[jpegOffset..<(jpegOffset + 2)]), [0xFF, 0xD8])

        let xmp = try XCTUnwrap(ifd0[700])
        let packet = String(data: data.subdata(in: xmp.value..<(xmp.value + xmp.count)), encoding: .utf8) ?? ""
        XCTAssertTrue(packet.contains("crs:CameraProfile=\"\(DNGWriter.embeddedProfileName)\""), "埋め込みプロファイルを既定にする")
        XCTAssertTrue(packet.contains("crs:ToneCurveName2012=\"Linear\""))
        XCTAssertTrue(packet.contains("crs:LensProfileEnable=\"1\""))
        XCTAssertTrue(packet.contains("aux:LensInfo=\"200/10 200/10 18/10 18/10\""))
        XCTAssertFalse(packet.contains("LensProfileFilename"), "存在しないLCPファイル名を捏造しない")

        // macOSのRAWデコーダーが埋め込みプレビューを認識すること（未認識だとFinderのサムネイルが真っ黒になる）
        let previewImage = try XCTUnwrap(CIRAWFilter(imageURL: url)?.previewImage, "埋め込みプレビューがmacOSに認識されていません")
        XCTAssertEqual(Int(max(previewImage.extent.width, previewImage.extent.height)), width)
    }

    /// 約8MBを超える画像ではストリップが複数に分割され、各ストリップが正しい行を指すこと。
    func testLargeDNGSplitsRawDataIntoConsistentStrips() throws {
        let width = 1500, height = 1000
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            // 行ごとに赤の値を変え、ストリップの位置ずれを検出できるようにする
            let red = UInt8(y % 256)
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = red
                pixels[index + 1] = 0
                pixels[index + 2] = 0
            }
        }
        let image = makeImage(width: width, height: height, pixels: pixels)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGWriter.write(image: image, metadata: nil, embedLensProfile: false, to: url)

        let data = try Data(contentsOf: url)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let ifd0 = readIFD(data, at: u32(4))
        let raw = readIFD(data, at: u32(try XCTUnwrap(ifd0[330]).value))
        let rowsPerStrip = try XCTUnwrap(raw[278]).value
        let strips = try XCTUnwrap(raw[273])
        let counts = try XCTUnwrap(raw[279])
        XCTAssertGreaterThan(strips.count, 1, "8MBを超える主画像はストリップを分割する")
        XCTAssertEqual(strips.count, (height + rowsPerStrip - 1) / rowsPerStrip)

        let lut = (0..<256).map { value -> Int in
            let c = Double(value) / 255
            let linear = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            return Int((linear * 65535).rounded())
        }
        var total = 0
        for strip in 0..<strips.count {
            let offset = u32(strips.value + strip * 4)
            let count = u32(counts.value + strip * 4)
            total += count
            XCTAssertLessThanOrEqual(offset + count, data.count)
            // 各ストリップ先頭の画素が、そのストリップの先頭行の値になっていること
            let firstRow = strip * rowsPerStrip
            XCTAssertEqual(u16(offset), lut[firstRow % 256], accuracy: 1500, "ストリップ\(strip)の位置がずれています")
        }
        XCTAssertEqual(total, width * height * 6)
        XCTAssertNotNil(CIRAWFilter(imageURL: url)?.previewImage)
    }

    func testDNGWithoutLensProfileStillEmbedsColorSettings() throws {
        let image = makeImage(width: 32, height: 24, pixel: (40, 80, 120, 255))
        var metadata = RawMetadataInfo()
        metadata.lensModel = "FE 20mm F1.8 G"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGWriter.write(image: image, metadata: metadata, embedLensProfile: false, to: url)

        let data = try Data(contentsOf: url)
        let ifd0 = readIFD(data, at: 8)
        let xmp = try XCTUnwrap(ifd0[700], "色設定のためXMPは常に必要")
        let packet = String(data: data.subdata(in: xmp.value..<(xmp.value + xmp.count)), encoding: .utf8) ?? ""
        XCTAssertTrue(packet.contains("crs:CameraProfile="))
        XCTAssertFalse(packet.contains("LensProfileEnable"))
        XCTAssertFalse(packet.contains("aux:Lens="))
    }

    func testJPEGLumaSamplingIsReadFromStartOfFrame() {
        // SOI, SOF0(長さ17, 8bit, 1x1, 3成分: Y=0x22, Cb=0x11, Cr=0x11)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x01, 0x00, 0x01, 0x03,
                         0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01])
        XCTAssertTrue(DNGWriter.jpegLumaSampling(jpeg) == (2, 2))
        var fourFourFour = jpeg
        fourFourFour[13] = 0x11
        XCTAssertTrue(DNGWriter.jpegLumaSampling(fourFourFour) == (1, 1))
    }

    func testResetAllRestoresLaunchState() throws {
        let state = StackingStateController()
        let defaults = StackingStateController()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let light = directory.appendingPathComponent("light.png")
        let dark = directory.appendingPathComponent("dark.png")
        let png = try XCTUnwrap(NSBitmapImageRep(
            cgImage: try XCTUnwrap(makeImage(width: 2, height: 2, pixel: (1, 2, 3, 255))
                .cgImage(forProposedRect: nil, context: nil, hints: nil))
        ).representation(using: .png, properties: [:]))
        try png.write(to: light)
        try png.write(to: dark)

        state.add(urls: [light], to: .light)
        state.add(urls: [dark], to: .dark)
        state.stackedResult = makeImage(width: 2, height: 2, pixel: (9, 9, 9, 255))
        state.stackedResultMetadata = RawMetadataInfo()
        state.showResult = true
        state.maskBitmap = makeImage(width: 2, height: 2, pixel: (0, 255, 0, 255))
        state.enableSkyGroundMask = true
        state.stackMode = "Median"
        state.enableAlignment = false
        state.enableAutoStretch = false
        state.brushSize = 99
        state.maskFeatherRadius = 55
        state.brushMode = .erase
        state.embedLensProfile = false
        state.customLensModel = "Manual Lens"
        state.customLensMake = "Maker"
        state.exportFormat = .fits32
        state.enableTrailRemoval = true
        state.stackingStatus = "✅ スタッキング完了！"
        state.stackingProgress = 1
        state.timelapseSettings.fps = 60
        state.timelapseSettings.codec = .hevc
        state.timelapseStatus = "done"
        XCTAssertTrue(state.canUndo)

        state.resetAll()

        for type in [ImageType.light, .dark, .flat, .bias] {
            XCTAssertEqual(state.count(for: type), 0)
        }
        XCTAssertNil(state.baseImage)
        XCTAssertNil(state.previewImage)
        XCTAssertNil(state.baseImageMetadata)
        XCTAssertNil(state.stackedResult)
        XCTAssertNil(state.stackedResultMetadata)
        XCTAssertFalse(state.showResult)
        XCTAssertNil(state.maskBitmap)
        XCTAssertEqual(state.enableSkyGroundMask, defaults.enableSkyGroundMask)
        XCTAssertEqual(state.stackMode, defaults.stackMode)
        XCTAssertEqual(state.enableAlignment, defaults.enableAlignment)
        XCTAssertEqual(state.enableAutoStretch, defaults.enableAutoStretch)
        XCTAssertEqual(state.brushSize, defaults.brushSize)
        XCTAssertEqual(state.maskFeatherRadius, defaults.maskFeatherRadius)
        XCTAssertEqual(state.brushMode, defaults.brushMode)
        XCTAssertEqual(state.embedLensProfile, defaults.embedLensProfile)
        XCTAssertEqual(state.customLensModel, "")
        XCTAssertEqual(state.customLensMake, "")
        XCTAssertEqual(state.exportFormat, defaults.exportFormat)
        XCTAssertFalse(state.enableTrailRemoval)
        XCTAssertTrue(state.detectedTrails.isEmpty)
        XCTAssertEqual(state.stackingStatus, "")
        XCTAssertEqual(state.stackingProgress, 0)
        XCTAssertEqual(state.timelapseSettings.fps, defaults.timelapseSettings.fps)
        XCTAssertEqual(state.timelapseSettings.codec, defaults.timelapseSettings.codec)
        XCTAssertEqual(state.timelapseStatus, "")
        XCTAssertFalse(state.canUndo, "リセットは取り消し対象にしない")
    }

    func testResetAllIsIgnoredWhileStacking() {
        let state = StackingStateController()
        state.stackMode = "Median"
        state.isStacking = true
        XCTAssertFalse(state.canResetAll)
        state.resetAll()
        XCTAssertEqual(state.stackMode, "Median")
    }

    func testAllExportFormatsProduceNonEmptyFiles() throws {
        let image = makeImage(width: 16, height: 12, pixel: (40, 80, 120, 255))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for format in ImageExporter.ExportFormat.allCases {
            let url = directory.appendingPathComponent("test.\(format.fileExtension)")
            try ImageExporter.write(image: image, format: format, embedLensProfile: false, to: url)
            let data = try Data(contentsOf: url)
            XCTAssertFalse(data.isEmpty, "\(format.rawValue) が空です")
            switch format {
            case .dng:
                XCTAssertEqual(Array(data.prefix(4)), [0x49, 0x49, 0x2A, 0x00])
                if let exiftool = RawMetadataExtractor.findExiftool() {
                    let process = Process()
                    let pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: exiftool)
                    process.arguments = ["-validate", "-warning", "-error", url.path]
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    process.waitUntilExit()
                    let validation = String(
                        data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                    ) ?? ""
                    XCTAssertEqual(process.terminationStatus, 0, validation)
                    XCTAssertFalse(validation.localizedCaseInsensitiveContains("Error"), validation)
                }
            case .fits32:
                XCTAssertTrue(String(data: data.prefix(6), encoding: .ascii)?.hasPrefix("SIMPLE") == true)
                XCTAssertEqual(data.count % 2880, 0)
                let decoded = try XCTUnwrap(ImageLoader.load(from: url))
                let decodedCG = try XCTUnwrap(decoded.cgImage(forProposedRect: nil, context: nil, hints: nil))
                XCTAssertEqual(decodedCG.width, 16)
                XCTAssertEqual(decodedCG.height, 12)
                // モノクロ化されず、R・G・Bの差が往復後も保たれていること
                XCTAssertTrue(String(data: data.prefix(2880), encoding: .ascii)?.contains("NAXIS3  =                    3") == true)
                let pixel = rgba(decoded)
                XCTAssertEqual(Int(pixel.0), 40, accuracy: 2)
                XCTAssertEqual(Int(pixel.1), 80, accuracy: 2)
                XCTAssertEqual(Int(pixel.2), 120, accuracy: 2)
            case .jpeg:
                XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
            case .tiff16:
                XCTAssertTrue(Array(data.prefix(2)) == [0x49, 0x49] || Array(data.prefix(2)) == [0x4D, 0x4D])
            }
        }
    }
}
