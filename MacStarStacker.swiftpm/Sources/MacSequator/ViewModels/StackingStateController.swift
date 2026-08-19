import Foundation
import AppKit
import CoreImage
import OpenCVWrapper

/// アプリ全体の状態管理およびスタッキング・エクスポート処理を司るコントローラ（macOS 10.12+ 互換）
class StackingStateController {

    static let shared = StackingStateController()

    // ── 画像リスト ──
    var images: [ImageType: [ImageFile]] = [
        .light: [], .dark: [], .flat: [], .bias: []
    ]
    var baseImage: ImageFile? {
        didSet {
            updateBaseImageMetadata()
            notifyStateChanged()
        }
    }
    var previewImage: ImageFile? {
        didSet {
            notifyStateChanged()
        }
    }
    var baseImageMetadata: RawMetadataInfo? = nil

    // ── 設定 ──
    var enableAutoStretch: Bool = true { didSet { notifyStateChanged() } }
    var enableAlignment: Bool = true { didSet { notifyStateChanged() } }
    var stackMode: String = "Average" { didSet { notifyStateChanged() } } // "Average", "Median", "Compare Bright"
    var compositingMode: String = "SkyGround" { didSet { notifyStateChanged() } } // "SkyGround", "Sky"
    var maskBitmap: NSImage? = nil { didSet { notifyStateChanged() } }
    var brushSize: CGFloat = 20.0 { didSet { notifyStateChanged() } }
    var brushSoftness: CGFloat = 0.0 { didSet { notifyStateChanged() } }
    var brushMode: MaskBrush = .sky { didSet { notifyStateChanged() } }

    // ── レンズプロファイル設定 ──
    var embedLensProfile: Bool = true { didSet { notifyStateChanged() } }
    var customLensModel: String = "" { didSet { notifyStateChanged() } }
    var customLensMake: String = "" { didSet { notifyStateChanged() } }
    var exportFormat: ImageExporter.ExportFormat = .dng { didSet { notifyStateChanged() } }

    // ── スタッキング状態 ──
    var isStacking: Bool = false { didSet { notifyStateChanged() } }
    var stackingProgress: Double = 0.0 { didSet { notifyStateChanged() } }
    var stackingStatus: String = "" { didSet { notifyStateChanged() } }
    var stackedResult: NSImage? = nil { didSet { notifyStateChanged() } }
    var stackedResultMetadata: RawMetadataInfo? = nil
    var showResult: Bool = false { didSet { notifyStateChanged() } }

    // ── タイムラプス設定 ──
    var timelapseSettings = TimelapseSettings()
    var isExportingTimelapse: Bool = false { didSet { notifyStateChanged() } }
    var timelapseProgress: Double = 0.0 { didSet { notifyStateChanged() } }
    var timelapseStatus: String = "" { didSet { notifyStateChanged() } }

    // ── コールバック ──
    var onStateChanged: (() -> Void)? = nil

    // ── Undo 履歴 ──
    private struct Snapshot {
        let images: [ImageType: [ImageFile]]
        let baseImage: ImageFile?
        let previewImage: ImageFile?
    }
    private var undoHistory: [Snapshot] = []
    private let maxUndo = 20

    init() {}

    func saveUndoSnapshot() {
        let snap = Snapshot(images: images, baseImage: baseImage, previewImage: previewImage)
        undoHistory.append(snap)
        if undoHistory.count > maxUndo { undoHistory.removeFirst() }
    }

    func undo() {
        guard let last = undoHistory.popLast() else { return }
        images = last.images
        baseImage = last.baseImage
        previewImage = last.previewImage
        updateBaseImageMetadata()
        notifyStateChanged()
    }

    var canUndo: Bool { !undoHistory.isEmpty }

    private func notifyStateChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?()
        }
    }

    // MARK: - ファイル管理

    func add(urls: [URL], to type: ImageType) {
        saveUndoSnapshot()
        var current = images[type] ?? []
        var newFiles: [ImageFile] = []

        for url in urls {
            guard !current.contains(where: { $0.url == url }) else { continue }
            let file = ImageFile(url: url)
            current.append(file)
            newFiles.append(file)
            if type == .light && baseImage == nil { baseImage = file }
            if previewImage == nil { previewImage = file }
        }
        images[type] = current
        notifyStateChanged()

        // バックグラウンドでメタデータを解析
        DispatchQueue.global(qos: .background).async { [weak self] in
            for file in newFiles {
                let meta = RawMetadataExtractor.extract(from: file.url)
                DispatchQueue.main.async {
                    self?.updateFileMetadata(fileId: file.id, type: type, metadata: meta)
                }
            }
        }
    }

    private func updateFileMetadata(fileId: UUID, type: ImageType, metadata: RawMetadataInfo) {
        guard var list = images[type] else { return }
        if let idx = list.firstIndex(where: { $0.id == fileId }) {
            list[idx].metadata = metadata
            images[type] = list
            if baseImage?.id == fileId {
                baseImage?.metadata = metadata
                updateBaseImageMetadata()
            }
            if previewImage?.id == fileId {
                previewImage?.metadata = metadata
            }
            notifyStateChanged()
        }
    }

    private func updateBaseImageMetadata() {
        if let base = baseImage {
            if let meta = base.metadata {
                self.baseImageMetadata = meta
            } else {
                let meta = RawMetadataExtractor.extract(from: base.url)
                self.baseImageMetadata = meta
                if let idx = images[.light]?.firstIndex(where: { $0.id == base.id }) {
                    images[.light]?[idx].metadata = meta
                }
            }
        } else {
            self.baseImageMetadata = nil
        }
    }

    func remove(file: ImageFile, from type: ImageType) {
        saveUndoSnapshot()
        images[type]?.removeAll { $0.id == file.id }
        if previewImage?.id == file.id { previewImage = images[type]?.first }
        if baseImage?.id == file.id   { baseImage = images[.light]?.first }
        notifyStateChanged()
    }

    func clear(type: ImageType) {
        saveUndoSnapshot()
        images[type]?.removeAll()
        if type == .light {
            baseImage = nil
        }
        notifyStateChanged()
    }

    func count(for type: ImageType) -> Int {
        images[type]?.count ?? 0
    }

    func getEffectiveMetadata() -> RawMetadataInfo? {
        let meta = stackedResultMetadata ?? baseImageMetadata
        if var m = meta {
            if !customLensModel.isEmpty {
                m.lensModel = customLensModel
            }
            if !customLensMake.isEmpty {
                m.lensMake = customLensMake
            }
            return m
        }
        return nil
    }

    // MARK: - 画像読み込み・表示用処理

    func loadNSImage(from file: ImageFile?) -> NSImage? {
        guard let file = file else { return nil }
        guard enableAutoStretch else { return NSImage(contentsOf: file.url) }

        guard let ci = CIImage(contentsOf: file.url) else { return NSImage(contentsOf: file.url) }
        guard let gammaFilter = CIFilter(name: "CIGammaAdjust") else { return NSImage(contentsOf: file.url) }
        gammaFilter.setValue(ci, forKey: kCIInputImageKey)
        gammaFilter.setValue(0.45, forKey: "inputPower")
        guard let gammaOut = gammaFilter.outputImage else { return NSImage(contentsOf: file.url) }

        guard let expFilter = CIFilter(name: "CIExposureAdjust") else { return NSImage(contentsOf: file.url) }
        expFilter.setValue(gammaOut, forKey: kCIInputImageKey)
        expFilter.setValue(1.0, forKey: "inputEV")
        guard let out = expFilter.outputImage else { return NSImage(contentsOf: file.url) }

        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return NSImage(contentsOf: file.url) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - スタッキングパイプライン

    func startStacking() {
        guard let base = baseImage else {
            stackingStatus = "⚠️ 基準画像を選択してください（★ボタン）"
            notifyStateChanged()
            return
        }
        let lightFiles = images[.light] ?? []
        guard !lightFiles.isEmpty else {
            stackingStatus = "⚠️ Light画像を追加してください"
            notifyStateChanged()
            return
        }

        isStacking = true
        stackingProgress = 0.0
        stackingStatus = "キャリブレーションフレームを構築中..."
        stackedResult = nil
        notifyStateChanged()

        let baseMetadata = baseImageMetadata ?? RawMetadataExtractor.extract(from: base.url)
        let darkFiles  = images[.dark]  ?? []
        let flatFiles  = images[.flat]  ?? []
        let biasFiles  = images[.bias]  ?? []
        let mode       = stackMode
        let compMode   = compositingMode
        let doAlign    = enableAlignment
        let mask       = maskBitmap

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let darkNSImages = darkFiles.compactMap  { NSImage(contentsOf: $0.url) }
            let flatNSImages = flatFiles.compactMap  { NSImage(contentsOf: $0.url) }
            let biasNSImages = biasFiles.compactMap { NSImage(contentsOf: $0.url) }

            let masterDark = darkNSImages.isEmpty ? nil : CalibrationProcessor.buildMaster(images: darkNSImages)
            let masterFlat = flatNSImages.isEmpty ? nil : CalibrationProcessor.buildMaster(images: flatNSImages)
            let masterBias = biasNSImages.isEmpty ? nil : CalibrationProcessor.buildMaster(images: biasNSImages)

            let total = lightFiles.count
            let statusLabel = doAlign ? "アライメント中" : "キャリブレーション中"

            DispatchQueue.main.async {
                self.stackingStatus = "\(statusLabel) (0/\(total))..."
                self.notifyStateChanged()
            }

            var alignedImages: [NSImage] = []
            for (i, lf) in lightFiles.enumerated() {
                guard let rawImg = NSImage(contentsOf: lf.url) else {
                    DispatchQueue.main.async {
                        self.stackingProgress = Double(i + 1) / Double(total) * 0.75
                        self.notifyStateChanged()
                    }
                    continue
                }

                let cal = CalibrationProcessor.calibrate(
                    light: rawImg, masterBias: masterBias,
                    masterDark: masterDark, masterFlat: masterFlat
                ) ?? rawImg

                let tempUrl = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cal_\(UUID().uuidString).tiff")
                if let cg = cal.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .tiff, properties: [:])?.write(to: tempUrl)
                }

                if !doAlign || lf.url == base.url {
                    alignedImages.append(cal)
                } else {
                    let aligned = (try? ImageAligner.alignImage(at: tempUrl, toBaseImageAt: base.url)) ?? cal
                    alignedImages.append(aligned)
                }
                try? FileManager.default.removeItem(at: tempUrl)

                DispatchQueue.main.async {
                    self.stackingProgress = Double(i + 1) / Double(total) * 0.75
                    self.stackingStatus = "\(statusLabel) (\(i + 1)/\(total))..."
                    self.notifyStateChanged()
                }
            }

            guard !alignedImages.isEmpty else {
                DispatchQueue.main.async {
                    self.isStacking = false
                    self.stackingStatus = "エラー: アライメント失敗"
                    self.notifyStateChanged()
                }
                return
            }

            DispatchQueue.main.async {
                self.stackingProgress = 0.80
                self.stackingStatus = "スタッキング中..."
                self.notifyStateChanged()
            }

            let sMode: ImageStacker.StackMode
            switch mode {
            case "Median":         sMode = .median
            case "Compare Bright": sMode = .compareBright
            default:               sMode = .average
            }

            var result: NSImage?

            if compMode == "SkyGround", let maskImg = mask {
                let skyStacked: NSImage?
                if mode == "Compare Bright" {
                    skyStacked = ImageStacker.stack(images: alignedImages, mode: .compareBright)
                } else if mode == "Median" {
                    skyStacked = ImageStacker.stack(images: alignedImages, mode: .median)
                } else {
                    let metal = MetalStacker.create()
                    skyStacked = metal?.stackAverage(images: alignedImages)
                                 ?? ImageStacker.stack(images: alignedImages, mode: .average)
                }

                let groundBase = alignedImages.first
                result = StackingStateController.blendSkyGround(
                    skyImage: skyStacked,
                    groundImage: groundBase,
                    mask: maskImg
                )
            } else if compMode == "Sky" {
                let metal = MetalStacker.create()
                result = metal?.stackAverage(images: alignedImages)
                         ?? ImageStacker.stack(images: alignedImages, mode: sMode)
            } else if compMode == "Ground" {
                result = alignedImages.first
            } else {
                if sMode == .average {
                    let metal = MetalStacker.create()
                    result = metal?.stackAverage(images: alignedImages)
                             ?? ImageStacker.stack(images: alignedImages, mode: .average)
                } else {
                    result = ImageStacker.stack(images: alignedImages, mode: sMode)
                }
            }

            guard let finalResult = result else {
                DispatchQueue.main.async {
                    self.isStacking = false
                    self.stackingStatus = "エラー: スタッキング失敗"
                    self.notifyStateChanged()
                }
                return
            }

            DispatchQueue.main.async {
                self.stackedResult = finalResult
                self.stackedResultMetadata = baseMetadata
                self.previewImage = nil
                self.stackingProgress = 1.0
                self.stackingStatus = "✅ スタッキング完了！"
                self.isStacking = false
                self.showResult = true
                self.notifyStateChanged()
            }
        }
    }

    // ── マスクブレンド ──
    private static func blendSkyGround(
        skyImage: NSImage?,
        groundImage: NSImage?,
        mask: NSImage
    ) -> NSImage? {
        guard let sky = skyImage, let ground = groundImage else { return skyImage }
        guard let skyCG = sky.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let gndCG = ground.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let mskCG = mask.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return skyImage }

        let W = skyCG.width, H = skyCG.height
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedLast.rawValue

        var skyPx = [UInt8](repeating: 0, count: W * H * 4)
        var gndPx = [UInt8](repeating: 0, count: W * H * 4)
        var mskPx = [UInt8](repeating: 0, count: W * H * 4)

        skyPx.withUnsafeMutableBytes { ptr in
            if let baseAddr = ptr.baseAddress {
                let ctx = CGContext(data: baseAddr, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: bi)
                ctx?.draw(skyCG, in: CGRect(x: 0, y: 0, width: W, height: H))
            }
        }
        gndPx.withUnsafeMutableBytes { ptr in
            if let baseAddr = ptr.baseAddress {
                let ctx = CGContext(data: baseAddr, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: bi)
                ctx?.draw(gndCG, in: CGRect(x: 0, y: 0, width: W, height: H))
            }
        }
        mskPx.withUnsafeMutableBytes { ptr in
            if let baseAddr = ptr.baseAddress {
                let ctx = CGContext(data: baseAddr, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: bi)
                ctx?.draw(mskCG, in: CGRect(x: 0, y: 0, width: W, height: H))
            }
        }

        var outPx = [UInt8](repeating: 0, count: W * H * 4)
        for i in stride(from: 0, to: W * H * 4, by: 4) {
            let mR = mskPx[i], mG = mskPx[i + 1]
            if mG > 100 && mG > mR {
                outPx[i]     = gndPx[i]
                outPx[i + 1] = gndPx[i + 1]
                outPx[i + 2] = gndPx[i + 2]
                outPx[i + 3] = gndPx[i + 3]
            } else {
                outPx[i]     = skyPx[i]
                outPx[i + 1] = skyPx[i + 1]
                outPx[i + 2] = skyPx[i + 2]
                outPx[i + 3] = skyPx[i + 3]
            }
        }

        guard let prov = CGDataProvider(data: Data(outPx) as CFData),
              let outCG = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: W * 4, space: cs,
                                  bitmapInfo: CGBitmapInfo(rawValue: bi),
                                  provider: prov, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { return skyImage }

        return NSImage(cgImage: outCG, size: NSSize(width: W, height: H))
    }

    // MARK: - タイムラプスエクスポート

    func exportTimelapse() {
        let lightFiles = images[.light] ?? []
        guard !lightFiles.isEmpty else {
            timelapseStatus = "⚠️ Light画像を追加してください"
            notifyStateChanged()
            return
        }
        var settings = timelapseSettings
        settings.startFrame = max(0, settings.startFrame)
        settings.endFrame   = min(lightFiles.count - 1, settings.endFrame)

        isExportingTimelapse = true
        timelapseProgress    = 0.0
        timelapseStatus      = "タイムラプスを準備中..."
        notifyStateChanged()

        TimelapseExporter.export(
            imageFiles: lightFiles,
            settings: settings,
            baseFile: baseImage,
            progress: { [weak self] p, msg in
                DispatchQueue.main.async {
                    self?.timelapseProgress = p
                    self?.timelapseStatus   = msg
                    self?.notifyStateChanged()
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    self?.isExportingTimelapse = false
                    switch result {
                    case .success:
                        self?.timelapseStatus = "✅ タイムラプス書き出し完了！"
                    case .failure(let err):
                        self?.timelapseStatus = "❌ \(err.localizedDescription)"
                    }
                    self?.notifyStateChanged()
                }
            }
        )
    }
}
