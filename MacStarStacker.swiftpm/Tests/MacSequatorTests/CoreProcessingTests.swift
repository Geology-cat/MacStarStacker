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
                let pixel = rgba(decoded)
                XCTAssertEqual(pixel.0, pixel.1, accuracy: 1)
                XCTAssertEqual(pixel.1, pixel.2, accuracy: 1)
                XCTAssertGreaterThan(pixel.0, 0)
                XCTAssertLessThan(pixel.0, 255)
            case .jpeg:
                XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
            case .tiff16:
                XCTAssertTrue(Array(data.prefix(2)) == [0x49, 0x49] || Array(data.prefix(2)) == [0x4D, 0x4D])
            }
        }
    }
}
