import Foundation
import AppKit
import CoreImage
import OpenCVWrapper

extension Notification.Name {
    static let stackingStateDidChange = Notification.Name("MacStarStacker.StackingStateDidChange")
}

/// アプリ全体の状態管理およびスタッキング・エクスポート処理を司るコントローラ（macOS 14+）
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
    var enableAutoStretch: Bool = true { didSet { if oldValue != enableAutoStretch { notifyStateChanged() } } }
    var enableAlignment: Bool = true { didSet { if oldValue != enableAlignment { notifyStateChanged() } } }
    var stackMode: String = "Average" { didSet { if oldValue != stackMode { notifyStateChanged() } } } // "Average", "Median", "Compare Bright"
    /// ON のときだけ空・地上マスクの編集と分離合成を有効にする。
    var enableSkyGroundMask: Bool = false { didSet { if oldValue != enableSkyGroundMask { notifyStateChanged() } } }
    var maskBitmap: NSImage? = nil { didSet { notifyStateChanged() } }
    var brushSize: CGFloat = 20.0 { didSet { if oldValue != brushSize { notifyStateChanged() } } }
    /// 空と地上を合成するときの境界ぼかし半径（最終画像上のピクセル単位）。
    var maskFeatherRadius: CGFloat = 12.0 { didSet { if oldValue != maskFeatherRadius { notifyStateChanged() } } }
    var brushMode: MaskBrush = .sky { didSet { if oldValue != brushMode { notifyStateChanged() } } }

    // ── レンズプロファイル設定 ──
    var embedLensProfile: Bool = true { didSet { if oldValue != embedLensProfile { notifyStateChanged() } } }
    var customLensModel: String = "" { didSet { if oldValue != customLensModel { notifyStateChanged() } } }
    var customLensMake: String = "" { didSet { if oldValue != customLensMake { notifyStateChanged() } } }
    var exportFormat: ImageExporter.ExportFormat = .dng { didSet { if oldValue != exportFormat { notifyStateChanged() } } }

    // ── スタッキング状態 ──
    var isStacking: Bool = false { didSet { if oldValue != isStacking { notifyStateChanged() } } }
    var stackingProgress: Double = 0.0 { didSet { if oldValue != stackingProgress { notifyStateChanged() } } }
    var stackingStatus: String = "" { didSet { if oldValue != stackingStatus { notifyStateChanged() } } }
    var stackedResult: NSImage? = nil { didSet { notifyStateChanged() } }
    var stackedResultMetadata: RawMetadataInfo? = nil
    var showResult: Bool = false { didSet { if oldValue != showResult { notifyStateChanged() } } }

    // ── タイムラプス設定 ──
    var timelapseSettings = TimelapseSettings()
    var isExportingTimelapse: Bool = false { didSet { if oldValue != isExportingTimelapse { notifyStateChanged() } } }
    var timelapseProgress: Double = 0.0 { didSet { if oldValue != timelapseProgress { notifyStateChanged() } } }
    var timelapseStatus: String = "" { didSet { if oldValue != timelapseStatus { notifyStateChanged() } } }

    // ── 光跡除去設定 (スタートレイル) ──
    var enableTrailRemoval: Bool = false { didSet { if oldValue != enableTrailRemoval { notifyStateChanged() } } }
    var detectedTrails: [DetectedTrailItem] = [] { didSet { notifyStateChanged() } }
    var isAnalyzingTrails: Bool = false { didSet { if oldValue != isAnalyzingTrails { notifyStateChanged() } } }
    var trailAnalysisProgress: Double = 0.0 { didSet { if oldValue != trailAnalysisProgress { notifyStateChanged() } } }
    var trailAnalysisStatus: String = "" { didSet { if oldValue != trailAnalysisStatus { notifyStateChanged() } } }
    private var trailAnalysisGeneration: UInt64 = 0

    // ── コールバック ──
    var onRequestShowTrailReview: (([DetectedTrailItem]) -> Void)? = nil

    // ── Undo 履歴 ──
    private struct Snapshot {
        let images: [ImageType: [ImageFile]]
        let baseImage: ImageFile?
        let previewImage: ImageFile?
    }
    private var undoHistory: [Snapshot] = []
    private let maxUndo = 20
    private var stateNotificationPending = false

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
        invalidateTrailAnalysis()
        normalizeTimelapseRange()
        notifyStateChanged()
    }

    var canUndo: Bool { !undoHistory.isEmpty }

    private func notifyStateChanged() {
        let scheduleNotification = { [weak self] in
            guard let self = self, !self.stateNotificationPending else { return }
            self.stateNotificationPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.stateNotificationPending = false
                NotificationCenter.default.post(name: .stackingStateDidChange, object: self)
            }
        }
        if Thread.isMainThread { scheduleNotification() }
        else { DispatchQueue.main.async(execute: scheduleNotification) }
    }

    // MARK: - ファイル管理

    /// Lightの並びや内容が変わったとき、以前のフレーム番号に紐づくマスクを破棄する。
    private func invalidateTrailAnalysis() {
        trailAnalysisGeneration &+= 1
        isAnalyzingTrails = false
        detectedTrails = []
        trailAnalysisProgress = 0.0
        trailAnalysisStatus = ""
    }

    func add(urls: [URL], to type: ImageType) {
        let importURLs = ImageImportSupport.expandedImageURLs(from: urls)
        guard !importURLs.isEmpty else { return }

        saveUndoSnapshot()
        var current = images[type] ?? []
        var newFiles: [ImageFile] = []

        for url in importURLs {
            guard !current.contains(where: { $0.url == url }) else { continue }
            let file = ImageFile(url: url)
            current.append(file)
            newFiles.append(file)
            if type == .light && baseImage == nil { baseImage = file }
            if previewImage == nil { previewImage = file }
        }
        images[type] = current
        if type == .light {
            invalidateTrailAnalysis()
            normalizeTimelapseRange()
        }
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
                // 追加時に走るバックグラウンド解析の完了を待つ。
                self.baseImageMetadata = nil
            }
        } else {
            self.baseImageMetadata = nil
        }
    }

    func remove(file: ImageFile, from type: ImageType) {
        saveUndoSnapshot()
        images[type]?.removeAll { $0.id == file.id }
        if type == .light {
            invalidateTrailAnalysis()
            normalizeTimelapseRange()
        }
        if previewImage?.id == file.id { previewImage = images[type]?.first }
        if baseImage?.id == file.id   { baseImage = images[.light]?.first }
        notifyStateChanged()
    }

    func clear(type: ImageType) {
        saveUndoSnapshot()
        let removedPreview = images[type]?.contains(where: { $0.id == previewImage?.id }) == true
        images[type]?.removeAll()
        if type == .light {
            baseImage = nil
            invalidateTrailAnalysis()
            normalizeTimelapseRange()
        }
        if removedPreview { previewImage = images[.light]?.first }
        notifyStateChanged()
    }

    private func normalizeTimelapseRange() {
        let count = images[.light]?.count ?? 0
        if count == 0 {
            timelapseSettings.startFrame = 0
            timelapseSettings.endFrame = 0
            return
        }
        timelapseSettings.startFrame = min(max(0, timelapseSettings.startFrame), count - 1)
        if timelapseSettings.endFrame == 999 || timelapseSettings.endFrame >= count {
            timelapseSettings.endFrame = count - 1
        }
        timelapseSettings.endFrame = max(timelapseSettings.startFrame, timelapseSettings.endFrame)
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
        guard let original = ImageLoader.load(from: file.url) else { return nil }
        guard enableAutoStretch else { return original }

        let ci = CIImage(contentsOf: file.url)
            ?? original.cgImage(forProposedRect: nil, context: nil, hints: nil).map(CIImage.init(cgImage:))
        guard let ci else { return original }
        guard let gammaFilter = CIFilter(name: "CIGammaAdjust") else { return original }
        gammaFilter.setValue(ci, forKey: kCIInputImageKey)
        gammaFilter.setValue(0.45, forKey: "inputPower")
        guard let gammaOut = gammaFilter.outputImage else { return original }

        guard let expFilter = CIFilter(name: "CIExposureAdjust") else { return original }
        expFilter.setValue(gammaOut, forKey: kCIInputImageKey)
        expFilter.setValue(1.0, forKey: "inputEV")
        guard let out = expFilter.outputImage else { return original }

        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return original }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - スタッキングパイプライン

    // MARK: - 光跡解析パイプライン (スタートレイル用)

    func analyzeTrails(completion: (([DetectedTrailItem]) -> Void)? = nil) {
        guard !isAnalyzingTrails && !isStacking else { return }
        let lightFiles = images[.light] ?? []
        guard lightFiles.count >= 3 else {
            stackingStatus = "⚠️ 光跡解析には3枚以上のLight画像が必要です"
            notifyStateChanged()
            return
        }

        trailAnalysisGeneration &+= 1
        let generation = trailAnalysisGeneration
        isAnalyzingTrails = true
        trailAnalysisProgress = 0.0
        trailAnalysisStatus = "フレームを解析中..."
        notifyStateChanged()

        let urls = lightFiles.map { $0.url }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let results = TrailCleaner.detectTrails(inImageURLs: urls) { progress, status in
                DispatchQueue.main.async {
                    guard self.trailAnalysisGeneration == generation else { return }
                    self.trailAnalysisProgress = progress
                    self.trailAnalysisStatus = status
                    self.notifyStateChanged()
                }
            }

            var items: [DetectedTrailItem] = []
            for res in results {
                let file = (res.frameIndex < lightFiles.count) ? lightFiles[res.frameIndex] : ImageFile(url: URL(fileURLWithPath: res.filePath))
                let item = DetectedTrailItem(
                    frameIndex: res.frameIndex,
                    file: file,
                    originalImage: res.originalImage,
                    maskImage: res.maskImage,
                    highlightedImage: res.highlightedImage,
                    repairedImage: res.repairedImage,
                    detectedType: res.detectedType,
                    confidenceScore: res.confidenceScore,
                    isLikelyMeteor: res.isLikelyMeteor,
                    isMarkedForRemoval: res.isMarkedForRemoval
                )
                items.append(item)
            }

            DispatchQueue.main.async {
                guard self.trailAnalysisGeneration == generation else { return }
                self.isAnalyzingTrails = false
                self.trailAnalysisProgress = 1.0
                self.detectedTrails = items
                if items.isEmpty {
                    self.trailAnalysisStatus = "人工光跡は検出されませんでした（クリーンです）"
                } else {
                    let removalCount = items.filter { $0.isMarkedForRemoval }.count
                    self.trailAnalysisStatus = "検出: \(items.count)件 (除去対象: \(removalCount)件)"
                }
                self.notifyStateChanged()

                // レビュー画面を開くコールバック
                self.onRequestShowTrailReview?(items)
                completion?(items)
            }
        }
    }

    // MARK: - スタッキングパイプライン

    func startStacking(forceDirectExecution: Bool = false) {
        guard !isStacking && !isAnalyzingTrails else { return }
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
        if enableSkyGroundMask && maskBitmap == nil {
            stackingStatus = "⚠️ 空・地上マスクをONにした場合は、地上領域をブラシで指定してください"
            notifyStateChanged()
            return
        }

        // 比較明合成かつ光跡除去が有効で、直接実行フラグがない場合はまずレビュー
        if stackMode == "Compare Bright" && enableTrailRemoval && !forceDirectExecution {
            if detectedTrails.isEmpty {
                analyzeTrails { _ in
                    // レビューシートが表示されるので待機
                }
                return
            } else {
                // 既存の検出結果でレビューを表示
                onRequestShowTrailReview?(detectedTrails)
                return
            }
        }

        isStacking = true
        stackingProgress = 0.0
        stackingStatus = "キャリブレーションフレームを構築中..."
        stackedResult = nil
        notifyStateChanged()

        let darkFiles  = images[.dark]  ?? []
        let flatFiles  = images[.flat]  ?? []
        let biasFiles  = images[.bias]  ?? []
        let mode       = stackMode
        let useSkyGroundMask = enableSkyGroundMask
        // 比較明合成では星の軌跡を保つため、アライメントを強制的に無効化する。
        let doAlign    = (mode == "Compare Bright") ? false : enableAlignment
        let mask       = useSkyGroundMask ? maskBitmap : nil
        let maskFeather = maskFeatherRadius
        let trailRemovalActive = (mode == "Compare Bright" && enableTrailRemoval)
        let trailItems = self.detectedTrails
        let knownBaseMetadata = baseImageMetadata

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let darkNSImages = darkFiles.compactMap  { ImageLoader.load(from: $0.url) }
            let flatNSImages = flatFiles.compactMap  { ImageLoader.load(from: $0.url) }
            let biasNSImages = biasFiles.compactMap { ImageLoader.load(from: $0.url) }

            guard darkNSImages.count == darkFiles.count,
                  flatNSImages.count == flatFiles.count,
                  biasNSImages.count == biasFiles.count else {
                self.finishStackingWithError("キャリブレーション画像の一部を読み込めませんでした")
                return
            }

            let masterDark = darkNSImages.isEmpty ? nil : CalibrationProcessor.buildMaster(images: darkNSImages)
            let masterFlat = flatNSImages.isEmpty ? nil : CalibrationProcessor.buildMaster(images: flatNSImages)
            let masterBias = biasNSImages.isEmpty ? nil : CalibrationProcessor.buildMaster(images: biasNSImages)

            guard (darkNSImages.isEmpty || masterDark != nil),
                  (flatNSImages.isEmpty || masterFlat != nil),
                  (biasNSImages.isEmpty || masterBias != nil) else {
                self.finishStackingWithError("キャリブレーション画像のサイズが一致していません")
                return
            }

            let total = lightFiles.count

            DispatchQueue.main.async {
                self.stackingStatus = "画像を読み込み・補正中 (0/\(total))..."
                self.notifyStateChanged()
            }

            var calibratedFrames: [(file: ImageFile, image: NSImage)] = []
            calibratedFrames.reserveCapacity(total)
            for (i, lf) in lightFiles.enumerated() {
                var rawImg: NSImage? = nil

                // 光跡除去が有効な場合、該当フレームの光跡をインペイント修復
                let masks = trailRemovalActive
                    ? trailItems.filter { $0.frameIndex == i && $0.isMarkedForRemoval }.compactMap { $0.maskImage }
                    : []
                if trailRemovalActive, !masks.isEmpty {
                    let prevUrl = (i > 0) ? lightFiles[i - 1].url : nil
                    let nextUrl = (i < total - 1) ? lightFiles[i + 1].url : nil
                    rawImg = TrailCleaner.inpaintImage(at: lf.url, withMasks: masks, prevFrameURL: prevUrl, nextFrameURL: nextUrl)
                }

                if rawImg == nil {
                    rawImg = ImageLoader.load(from: lf.url)
                }

                guard let finalFrameImg = rawImg else {
                    self.finishStackingWithError("画像を読み込めませんでした: \(lf.name)")
                    return
                }

                guard let calibrated = CalibrationProcessor.calibrate(
                    light: finalFrameImg, masterBias: masterBias,
                    masterDark: masterDark, masterFlat: masterFlat
                ) else {
                    self.finishStackingWithError("キャリブレーション画像とLight画像のサイズが一致しません: \(lf.name)")
                    return
                }
                calibratedFrames.append((lf, calibrated))

                DispatchQueue.main.async {
                    self.stackingProgress = Double(i + 1) / Double(total) * (doAlign ? 0.35 : 0.75)
                    self.stackingStatus = "画像を読み込み・補正中 (\(i + 1)/\(total))..."
                    self.notifyStateChanged()
                }
            }

            var skyFrames = calibratedFrames.map(\.image)
            if doAlign {
                guard let baseFrame = calibratedFrames.first(where: { $0.file.id == base.id }),
                      let baseReferenceURL = self.writeTemporaryTIFF(baseFrame.image, prefix: "base") else {
                    self.finishStackingWithError("基準画像を位置合わせ用に準備できませんでした")
                    return
                }
                defer { try? FileManager.default.removeItem(at: baseReferenceURL) }

                skyFrames.removeAll(keepingCapacity: true)
                for (i, frame) in calibratedFrames.enumerated() {
                    if frame.file.id == base.id {
                        skyFrames.append(frame.image)
                    } else {
                        guard let targetURL = self.writeTemporaryTIFF(frame.image, prefix: "align") else {
                            self.finishStackingWithError("位置合わせ用画像を準備できませんでした: \(frame.file.name)")
                            return
                        }
                        do {
                            let aligned = try ImageAligner.alignImage(at: targetURL, toBaseImageAt: baseReferenceURL)
                            skyFrames.append(aligned)
                            try? FileManager.default.removeItem(at: targetURL)
                        } catch {
                            try? FileManager.default.removeItem(at: targetURL)
                            self.finishStackingWithError("星の位置合わせに失敗しました: \(frame.file.name)（\(error.localizedDescription)）")
                            return
                        }
                    }

                    DispatchQueue.main.async {
                        self.stackingProgress = 0.35 + Double(i + 1) / Double(total) * 0.40
                        self.stackingStatus = "星を位置合わせ中 (\(i + 1)/\(total))..."
                        self.notifyStateChanged()
                    }
                }
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

            let skyStacked = self.stack(images: skyFrames, mode: sMode)
            let result: NSImage?
            if useSkyGroundMask, let maskImg = mask {
                // 地上側は星用の変形を適用せず、固定構図のままノイズ低減する。
                let groundMode: ImageStacker.StackMode = (mode == "Median") ? .median : .average
                let groundStacked = self.stack(images: calibratedFrames.map(\.image), mode: groundMode)
                result = StackingStateController.blendSkyGround(
                    skyImage: skyStacked,
                    groundImage: groundStacked,
                    mask: maskImg,
                    featherRadius: maskFeather
                )
            } else {
                result = skyStacked
            }

            guard let finalResult = result else {
                DispatchQueue.main.async {
                    self.isStacking = false
                    self.stackingStatus = "エラー: スタッキング失敗"
                    self.notifyStateChanged()
                }
                return
            }

            let resolvedBaseMetadata = knownBaseMetadata ?? RawMetadataExtractor.extract(from: base.url)
            DispatchQueue.main.async {
                self.stackedResult = finalResult
                self.stackedResultMetadata = resolvedBaseMetadata
                self.previewImage = nil
                self.stackingProgress = 1.0
                self.stackingStatus = "✅ スタッキング完了！"
                self.isStacking = false
                self.showResult = true
                self.notifyStateChanged()
            }
        }
    }

    private func finishStackingWithError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.isStacking = false
            self?.stackingStatus = "❌ \(message)"
            self?.notifyStateChanged()
        }
    }

    private func writeTemporaryTIFF(_ image: NSImage, prefix: String) -> URL? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStarStacker_\(prefix)_\(UUID().uuidString).tiff")
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .tiff, properties: [:]) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func stack(images: [NSImage], mode: ImageStacker.StackMode) -> NSImage? {
        switch mode {
        case .average:
            return MetalStacker.create()?.stackAverage(images: images)
                ?? ImageStacker.stack(images: images, mode: .average)
        case .median, .compareBright:
            return ImageStacker.stack(images: images, mode: mode)
        }
    }

    // ── マスクブレンド ──
    static func blendSkyGround(
        skyImage: NSImage?,
        groundImage: NSImage?,
        mask: NSImage,
        featherRadius: CGFloat = 3.0
    ) -> NSImage? {
        guard let sky = skyImage, let ground = groundImage else { return skyImage }
        guard let skyCG = sky.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let gndCG = ground.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let mskCG = mask.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return skyImage }

        let extent = CGRect(x: 0, y: 0, width: skyCG.width, height: skyCG.height)
        let skyCI = CIImage(cgImage: skyCG)
        let groundCI = CIImage(cgImage: gndCG).transformed(by: CGAffineTransform(
            scaleX: extent.width / CGFloat(gndCG.width),
            y: extent.height / CGFloat(gndCG.height)
        )).cropped(to: extent)
        let resizedMask = CIImage(cgImage: mskCG).transformed(by: CGAffineTransform(
            scaleX: extent.width / CGFloat(mskCG.width),
            y: extent.height / CGFloat(mskCG.height)
        )).cropped(to: extent)

        // 緑を地上、青と未塗装領域を空として扱い、境界だけを自動でぼかす。
        guard let matrix = CIFilter(name: "CIColorMatrix"),
              let blend = CIFilter(name: "CIBlendWithMask") else { return skyImage }
        matrix.setValue(resizedMask, forKey: kCIInputImageKey)
        let groundVector = CIVector(x: 0, y: 1, z: -1, w: 0)
        matrix.setValue(groundVector, forKey: "inputRVector")
        matrix.setValue(groundVector, forKey: "inputGVector")
        matrix.setValue(groundVector, forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        guard let extractedGroundMask = matrix.outputImage?
            // 青マスクの負値を0へ確定してからぼかし、境界の両側を対称に混合する。
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            .cropped(to: extent) else { return skyImage }
        let radius = min(100.0, max(0.0, featherRadius))
        let groundMask: CIImage
        if radius > 0 {
            // 端で透明色が混ざらないよう画像端を延長してから、指定半径で境界をぼかす。
            groundMask = extractedGroundMask
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        } else {
            groundMask = extractedGroundMask
        }

        blend.setValue(groundCI, forKey: kCIInputImageKey)
        blend.setValue(skyCI, forKey: kCIInputBackgroundImageKey)
        blend.setValue(groundMask, forKey: kCIInputMaskImageKey)
        let outputColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let output = blend.outputImage,
              let outCG = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(
                output, from: extent, format: .RGBA16, colorSpace: outputColorSpace
              )
        else { return skyImage }
        return NSImage(cgImage: outCG, size: NSSize(width: outCG.width, height: outCG.height))
    }

    // MARK: - タイムラプスエクスポート

    func exportTimelapse() {
        guard !isExportingTimelapse else { return }
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
