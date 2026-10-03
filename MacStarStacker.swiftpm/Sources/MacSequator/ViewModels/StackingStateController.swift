import Foundation
import AppKit
import CoreImage
import OpenCVWrapper

extension Notification.Name {
    static let stackingStateDidChange = Notification.Name("MacStarStacker.StackingStateDidChange")
    /// 「すべてクリア」実行時に、ビュー側だけが持つ状態（タブ・ズーム等）を初期化するための通知。
    static let stackingStateDidReset = Notification.Name("MacStarStacker.StackingStateDidReset")
}

/// アプリ全体の状態管理およびスタッキング・エクスポート処理を司るコントローラ（macOS 14+）
class StackingStateController {

    static let shared = StackingStateController()

    // ── 画像リスト ──
    var images: [ImageType: [ImageFile]] = [
        .light: [], .dark: [], .flat: [], .bias: [], .groundFixed: []
    ]
    var baseImage: ImageFile? {
        didSet {
            updateBaseImageMetadata()
            if oldValue?.id != baseImage?.id { nightscapeInputsDidChange() }
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
    /// Light画像を読み込んだ直後は撮って出しの明るさで確認できるよう、既定はOFF
    var enableAutoStretch: Bool = false { didSet { if oldValue != enableAutoStretch { notifyStateChanged() } } }
    var enableAlignment: Bool = true { didSet { if oldValue != enableAlignment { notifyStateChanged() } } }
    /// 比較明合成での位置合わせ。星を合わせると星の軌跡が点になるため、平均・中央値とは別に持ち、既定はOFF
    var enableCompareBrightAlignment: Bool = false {
        didSet { if oldValue != enableCompareBrightAlignment { notifyStateChanged() } }
    }
    /// 現在のスタック方式での位置合わせの設定
    var isAlignmentEnabledForCurrentMode: Bool {
        get { stackMode == "Compare Bright" ? enableCompareBrightAlignment : enableAlignment }
        set {
            if stackMode == "Compare Bright" { enableCompareBrightAlignment = newValue } else { enableAlignment = newValue }
        }
    }
    var stackMode: String = "Average" { // "Average", "Median", "Compare Bright"
        didSet {
            guard oldValue != stackMode else { return }
            nightscapeInputsDidChange()
            notifyStateChanged()
        }
    }
    /// ON のときだけ空・地上マスクの編集と分離合成を有効にする。
    /// 平均・中央値では新星景モード（空と地上を自動で判定し、塗った所は手がかりにする）、
    /// 比較明では塗ったマスクで空（比較明）と地上（平均）を分ける。
    var enableSkyGroundMask: Bool = false {
        didSet {
            guard oldValue != enableSkyGroundMask else { return }
            nightscapeInputsDidChange()
            notifyStateChanged()
        }
    }
    /// 平均でシグマクリッピング（外れ値を除いてから平均）するか
    var enableSigmaClipping: Bool = false { didSet { if oldValue != enableSigmaClipping { notifyStateChanged() } } }
    /// シグマクリッピングの κ（下側・上側）
    var sigmaClipping = SigmaClipping() { didSet { if oldValue != sigmaClipping { notifyStateChanged() } } }
    /// 今の合成方法で使うシグマクリッピング。新星景モードでは外れ値（動く星など）を除く必要があるため常に使う
    var activeSigmaClipping: SigmaClipping? {
        if isNightscapeActive { return sigmaClipping }
        return stackMode == "Average" && enableSigmaClipping ? sigmaClipping : nil
    }
    /// 新星景モード（空は星に、地上は地上に合わせて合成）が有効か
    var isNightscapeActive: Bool { enableSkyGroundMask && stackMode != "Compare Bright" }
    /// 地上固定フレームを使う新星景モードか（地上はそのフレームにし、判定・合成もそのフレームの構図で行う）
    var isGroundFixedActive: Bool { isNightscapeActive && !(images[.groundFixed] ?? []).isEmpty }
    /// 新星景モードの判定結果（マスク）を重ねる画像。地上固定フレームを使うときは1枚目の地上固定フレーム
    var nightscapeReferenceImage: ImageFile? {
        isGroundFixedActive ? images[.groundFixed]?.first : baseImage
    }
    /// 前回の入力で地上固定フレームを使っていたか（使う・使わないが変わるとマスクの構図が変わる）
    private var maskUsesGroundFixed = false
    var maskBitmap: NSImage? = nil { didSet { notifyStateChanged() } }
    var brushSize: CGFloat = 20.0 { didSet { if oldValue != brushSize { notifyStateChanged() } } }
    /// 空と地上を合成するときの境界ぼかし半径（最終画像上のピクセル単位）。
    var maskFeatherRadius: CGFloat = 12.0 { didSet { if oldValue != maskFeatherRadius { notifyStateChanged() } } }
    /// 新星景モードの境界ぼかし半径。境界は画像の輪郭に沿って自動でなじませるため、既定は 0（追加でぼかさない）
    var nightscapeFeatherRadius: CGFloat = 0 {
        didSet { if oldValue != nightscapeFeatherRadius { notifyStateChanged() } }
    }
    /// 現在のモード（新星景モードか比較明の分離合成か）での境界ぼかし半径
    var featherRadiusForCurrentMode: CGFloat {
        get { isNightscapeActive ? nightscapeFeatherRadius : maskFeatherRadius }
        set { if isNightscapeActive { nightscapeFeatherRadius = newValue } else { maskFeatherRadius = newValue } }
    }
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
    /// RAWを現像せずに合成できた場合の結果（DNG書き出しはこちらのセンサーデータを使う）
    var stackedRawResult: RawStackResult? = nil
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

    // ── 新星景モードの解析（合成の前に空と地上を自動で判定し、ブラシで直せるようにする）──
    var isAnalyzingNightscape: Bool = false { didSet { if oldValue != isAnalyzingNightscape { notifyStateChanged() } } }
    var nightscapeAnalysisProgress: Double = 0.0 {
        didSet { if oldValue != nightscapeAnalysisProgress { notifyStateChanged() } }
    }
    var nightscapeAnalysisStatus: String = "" { didSet { if oldValue != nightscapeAnalysisStatus { notifyStateChanged() } } }
    /// 解析の結果。同じ入力（Light・基準画像・キャリブレーション）で合成するときに使い回す
    enum NightscapePrepared {
        case raw(RawStackPipeline.NightscapePreparation)
        case developed(key: String, analysis: NightscapeCompositor.Analysis)

        var key: String {
            switch self {
            case .raw(let preparation): return preparation.key
            case .developed(let key, _): return key
            }
        }
    }
    private(set) var nightscapePrepared: NightscapePrepared?
    private var nightscapeAnalysisToken: CancellationToken?
    /// 実行中の解析の入力の組み合わせ（同じ入力の解析を途中からやり直さない）
    private var nightscapeAnalysisKey: String?

    /// 別スレッドの処理を取りやめるための印
    final class CancellationToken {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

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

    init() {
        // 光跡検出・修復でもRAWをLibRawで読み込み、合成と同じ画像を使う
        TrailCleaner.imageLoader = { ImageLoader.load(from: $0) }
    }

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
        nightscapeInputsDidChange()
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
            if previewImage == nil || (type == .groundFixed && isNightscapeActive && current.count == 1) {
                previewImage = file
            }
        }
        images[type] = current
        if type == .light {
            invalidateTrailAnalysis()
            normalizeTimelapseRange()
        }
        nightscapeInputsDidChange()
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
        if previewImage?.id == file.id { previewImage = images[type]?.first ?? baseImage }
        if baseImage?.id == file.id   { baseImage = images[.light]?.first }
        nightscapeInputsDidChange()
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
        if removedPreview { previewImage = baseImage ?? images[.light]?.first }
        nightscapeInputsDidChange()
        notifyStateChanged()
    }

    /// スタッキング・光跡解析・タイムラプス書き出しの実行中はリセットできない。
    var canResetAll: Bool { !isStacking && !isAnalyzingTrails && !isExportingTimelapse }

    // MARK: - 新星景モードの解析

    /// 解析を使い回せるかの判定に使う、今の入力の組み合わせ
    private func currentNightscapeKey() -> String? {
        guard let input = nightscapeInput(mask: nil) else { return nil }
        return RawStackPipeline.nightscapeKey(for: input)
    }

    private func nightscapeInput(mask: NSImage?) -> RawStackPipeline.Input? {
        let lightFiles = images[.light] ?? []
        guard let base = baseImage, !lightFiles.isEmpty else { return nil }
        return RawStackPipeline.Input(
            lights: lightFiles.map(\.url),
            baseIndex: lightFiles.firstIndex(where: { $0.id == base.id }) ?? 0,
            darks: (images[.dark] ?? []).map(\.url),
            flats: (images[.flat] ?? []).map(\.url),
            biases: (images[.bias] ?? []).map(\.url),
            mode: stackMode == "Median" ? .median : .average,
            align: true, skyGroundMask: mask, maskFeatherRadius: 0, trailMasks: [:],
            nightscape: true, nightscapeFeatherRadius: nightscapeFeatherRadius,
            groundFixed: (images[.groundFixed] ?? []).map(\.url)
        )
    }

    /// 新星景モードの入力（Light・基準画像・キャリブレーション画像・合成方法）が変わったとき。
    /// 解析は「解析開始」で行う。前の解析と自動判定の結果（位置がずれている）は手放し、ブラシで塗った所は残す
    func nightscapeInputsDidChange() {
        // 地上固定フレームを使う・使わないが変わると、マスクの構図（どの画像の上に塗ったか）が変わるため、
        // ブラシで塗った所も含めて消す（追尾撮影では位置がずれる）
        var clearedMask = false
        if maskUsesGroundFixed != isGroundFixedActive {
            maskUsesGroundFixed = isGroundFixedActive
            if maskBitmap != nil {
                maskBitmap = nil
                clearedMask = true
                nightscapeAnalysisStatus = isGroundFixedActive
                    ? "地上固定フレームを使うため、マスクを消しました。「解析開始」を押すと地上固定フレームの上で空と地上を判定します"
                    : "地上固定フレームを使わなくなったため、マスクを消しました"
            }
        }
        guard isNightscapeActive else {
            cancelNightscapeAnalysis()
            return
        }
        let key = currentNightscapeKey()
        if isAnalyzingNightscape, nightscapeAnalysisKey != key {
            cancelNightscapeAnalysis()
            nightscapeAnalysisStatus = "Light・基準画像などが変わったため解析を中止しました。「解析開始」を押してください"
        }
        if let prepared = nightscapePrepared, prepared.key != key {
            nightscapePrepared = nil
            maskBitmap = NightscapeCompositor.userStrokesOnly(maskBitmap)
            if !clearedMask {
                nightscapeAnalysisStatus = "Light・基準画像などが変わりました。「解析開始」を押すと空と地上を判定し直します"
            }
        }
    }

    private func cancelNightscapeAnalysis() {
        nightscapeAnalysisToken?.cancel()
        nightscapeAnalysisToken = nil
        nightscapeAnalysisKey = nil
        if isAnalyzingNightscape {
            isAnalyzingNightscape = false
            nightscapeAnalysisStatus = ""
        }
    }

    /// 新星景モードの解析（全フレームの位置合わせと空・地上の自動判定）を行い、判定結果をブラシで直せるマスクとして表示する。
    /// 解析の結果は合成で使い回す
    func analyzeNightscape() {
        cancelNightscapeAnalysis()
        guard isNightscapeActive, !isStacking, let base = nightscapeReferenceImage,
              (images[.light] ?? []).count >= 2, let input = nightscapeInput(mask: maskBitmap) else { return }
        let token = CancellationToken()
        nightscapeAnalysisToken = token
        let key = RawStackPipeline.nightscapeKey(for: input)
        nightscapeAnalysisKey = key
        // 入力の違う前の解析は、新しい解析の前に手放す（メモリに2つ持たない）
        if nightscapePrepared?.key != key { nightscapePrepared = nil }
        isAnalyzingNightscape = true
        nightscapeAnalysisProgress = 0
        nightscapeAnalysisStatus = "新星景モード: 空と地上を自動判定しています..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report: (Double, String) -> Void = { fraction, status in
                DispatchQueue.main.async {
                    guard let self, !token.isCancelled else { return }
                    self.nightscapeAnalysisProgress = fraction
                    self.nightscapeAnalysisStatus = status
                }
            }
            do {
                let prepared: NightscapePrepared
                let overlay: NSImage?
                let reason: String?
                if let raw = try RawStackPipeline.prepareNightscape(input, isCancelled: { token.isCancelled }, progress: report) {
                    prepared = .raw(raw)
                    reason = raw.analysis.notNeededReason
                    overlay = raw.analysis.detectedSkyAlpha.flatMap { alpha in
                        StackingStateController.displayOrientedOverlay(
                            NightscapeCompositor.hintOverlay(skyAlpha: alpha, width: raw.analysis.width, height: raw.analysis.height),
                            orientation: Int(raw.base.info.orientation))
                    }
                } else {
                    let analysis = try StackingStateController.analyzeDevelopedNightscape(
                        input, isCancelled: { token.isCancelled }, progress: report)
                    prepared = .developed(key: key, analysis: analysis)
                    reason = analysis.notNeededReason
                    overlay = analysis.detectedSkyAlpha.flatMap { alpha in
                        NightscapeCompositor.hintOverlay(skyAlpha: alpha, width: analysis.width, height: analysis.height)
                            .map { NSImage(cgImage: $0, size: NSSize(width: analysis.width, height: analysis.height)) }
                    }
                }
                DispatchQueue.main.async {
                    guard let self, !token.isCancelled else { return }
                    self.nightscapeAnalysisToken = nil
                    self.nightscapeAnalysisKey = nil
                    self.nightscapePrepared = prepared
                    self.isAnalyzingNightscape = false
                    self.nightscapeAnalysisProgress = 1
                    if let overlay {
                        // 解析中にブラシで塗った所も残す
                        self.maskBitmap = NightscapeCompositor.mergingUserStrokes(from: self.maskBitmap, onto: overlay)
                        // 判定結果は基準画像（地上固定フレームを使うときは地上固定フレーム）の上に表示する
                        // （ブラシで直せるよう、スタック結果ではなく元画像を表示する）
                        self.previewImage = base
                        self.showResult = false
                        self.nightscapeAnalysisStatus = "空と地上を自動で判定しました。違う所があればブラシで直してから、スタッキングを開始してください"
                    } else {
                        self.nightscapeAnalysisStatus = reason.map { "新星景モード: \($0)" } ?? ""
                    }
                }
            } catch is NightscapeCompositor.Cancelled {
                return
            } catch {
                DispatchQueue.main.async {
                    guard let self, !token.isCancelled else { return }
                    self.nightscapeAnalysisToken = nil
                    self.nightscapeAnalysisKey = nil
                    self.isAnalyzingNightscape = false
                    self.nightscapeAnalysisStatus = "新星景モード: 空と地上を判定できませんでした（\(error.localizedDescription)）"
                }
            }
        }
    }

    /// 現像済み画像（JPEG・TIFFなど）での新星景モードの解析
    private static func analyzeDevelopedNightscape(
        _ input: RawStackPipeline.Input,
        isCancelled: @escaping () -> Bool,
        progress: @escaping (Double, String) -> Void
    ) throws -> NightscapeCompositor.Analysis {
        progress(0.02, "キャリブレーションフレームを構築中...")
        func master(_ urls: [URL]) throws -> NSImage? {
            guard !urls.isEmpty else { return nil }
            let loaded = urls.compactMap { ImageLoader.load(from: $0) }
            guard loaded.count == urls.count, let built = CalibrationProcessor.buildMaster(images: loaded) else {
                throw NightscapeCompositor.CompositorError(message: "キャリブレーション画像を読み込めませんでした")
            }
            return built
        }
        let masterDark = try master(input.darks), masterFlat = try master(input.flats), masterBias = try master(input.biases)
        let groundReference = try input.usesGroundFixed
            ? developedGroundReference(input: input, masterBias: masterBias, masterFlat: masterFlat, progress: progress)
            : nil
        func load(_ index: Int) throws -> NightscapeCompositor.RGB16Image {
            let url = input.lights[index]
            guard let image = ImageLoader.load(from: url),
                  let calibrated = CalibrationProcessor.calibrate(light: image, masterBias: masterBias,
                                                                  masterDark: masterDark, masterFlat: masterFlat),
                  let rgb = NightscapeCompositor.rgb16(from: calibrated) else {
                throw NightscapeCompositor.CompositorError(message: "画像を読み込めませんでした: \(url.lastPathComponent)")
            }
            return rgb
        }
        let baseIndex = min(max(0, input.baseIndex), input.lights.count - 1)
        let first = try load(baseIndex)
        let hints = input.skyGroundMask
            .flatMap { NightscapeCompositor.hints(from: $0, width: first.width, height: first.height) }
            .flatMap(NightscapeCompositor.userHints)
        // ブラシで直している間も解析を持ち続けるため、現像したフレームは保持しない（メモリを抑える）
        let analysis = try NightscapeCompositor.analyze(
            frameCount: input.lights.count, baseIndex: baseIndex, width: first.width, height: first.height, hints: hints,
            groundReference: groundReference?.pixels, cacheFrames: false, isCancelled: isCancelled,
            loadFrame: { index in
                if index == baseIndex { return first.pixels }
                let frame = try load(index)
                guard frame.width == first.width, frame.height == first.height else {
                    throw NightscapeCompositor.CompositorError(message: "画像サイズが一致しません: \(input.lights[index].lastPathComponent)")
                }
                return frame.pixels
            },
            progress: progress
        )
        if groundReference?.matchedExposure == false { analysis.groundReferenceNote = NightscapeCompositor.unmatchedExposureNote }
        return analysis
    }

    /// 現像済み画像での地上固定フレーム: 読み込んで（ダークは露出時間が違うため使わない）線形の16bit RGBにし、
    /// 露出を Light（基準画像）に揃えて1枚にする
    static func developedGroundReference(
        input: RawStackPipeline.Input, masterBias: NSImage?, masterFlat: NSImage?, progress: (Double, String) -> Void
    ) throws -> (pixels: [UInt16], matchedExposure: Bool) {
        let lightMetadata = RawMetadataExtractor.extract(from: input.lights[min(max(0, input.baseIndex), input.lights.count - 1)])
        var frames: [[UInt16]] = []
        var scales: [Double] = []
        var size: (Int, Int)?
        var matchedExposure = true
        for (index, url) in input.groundFixed.enumerated() {
            progress(0.02, "地上固定フレームを読み込み中 (\(index + 1)/\(input.groundFixed.count))...")
            guard let image = ImageLoader.load(from: url),
                  let calibrated = CalibrationProcessor.calibrate(light: image, masterBias: masterBias, masterDark: nil,
                                                                  masterFlat: masterFlat),
                  let rgb = NightscapeCompositor.rgb16(from: calibrated) else {
                throw NightscapeCompositor.CompositorError(message: "地上固定フレームを読み込めませんでした: \(url.lastPathComponent)")
            }
            if let size, size != (rgb.width, rgb.height) {
                throw NightscapeCompositor.CompositorError(message: "地上固定フレームの大きさが一致しません: \(url.lastPathComponent)")
            }
            size = (rgb.width, rgb.height)
            frames.append(rgb.pixels)
            let scale = NightscapeCompositor.exposureScale(light: lightMetadata, ground: RawMetadataExtractor.extract(from: url))
            if scale == nil { matchedExposure = false }
            scales.append(scale ?? 1)
        }
        return (NightscapeCompositor.groundReference(frames: frames, scales: scales, blackLevel: 0, whiteLevel: 65535),
                matchedExposure)
    }

    /// 読み込んだ画像・結果・マスク・各種設定をすべて破棄し、起動直後の状態へ戻す。
    /// Undo履歴は画像リストしか保持しておらず部分的にしか戻せないため、併せて破棄する。
    func resetAll() {
        guard canResetAll else { return }
        let defaults = StackingStateController()

        images = defaults.images
        baseImage = nil
        previewImage = nil
        baseImageMetadata = nil

        enableAutoStretch = defaults.enableAutoStretch
        enableAlignment = defaults.enableAlignment
        enableCompareBrightAlignment = defaults.enableCompareBrightAlignment
        stackMode = defaults.stackMode
        enableSkyGroundMask = defaults.enableSkyGroundMask
        cancelNightscapeAnalysis()
        nightscapePrepared = nil
        nightscapeAnalysisStatus = ""
        maskBitmap = nil
        maskUsesGroundFixed = false
        brushSize = defaults.brushSize
        maskFeatherRadius = defaults.maskFeatherRadius
        enableSigmaClipping = defaults.enableSigmaClipping
        sigmaClipping = defaults.sigmaClipping
        nightscapeFeatherRadius = defaults.nightscapeFeatherRadius
        brushMode = defaults.brushMode

        embedLensProfile = defaults.embedLensProfile
        customLensModel = defaults.customLensModel
        customLensMake = defaults.customLensMake
        exportFormat = defaults.exportFormat

        stackingProgress = defaults.stackingProgress
        stackingStatus = defaults.stackingStatus
        stackedResult = nil
        stackedResultMetadata = nil
        stackedRawResult = nil
        showResult = defaults.showResult

        timelapseSettings = defaults.timelapseSettings
        timelapseProgress = defaults.timelapseProgress
        timelapseStatus = defaults.timelapseStatus

        enableTrailRemoval = defaults.enableTrailRemoval
        invalidateTrailAnalysis()

        undoHistory.removeAll()
        notifyStateChanged()
        NotificationCenter.default.post(name: .stackingStateDidReset, object: self)
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

    /// バックグラウンドから呼べるよう、自動ストレッチの有無は引数で受け取る（省略時は現在の設定）。
    func loadNSImage(from file: ImageFile?, autoStretch: Bool? = nil) -> NSImage? {
        guard let file = file else { return nil }
        guard let original = ImageLoader.load(from: file.url) else { return nil }
        guard autoStretch ?? enableAutoStretch else { return original }

        // 画像の明るさの分布に合わせて暗部を持ち上げる（固定のガンマ・露出補正では明るくなりすぎる）。
        // RAWはmacOSのRAWエンジンで読み直さず、LibRawで現像した画像をそのまま使う
        return AutoStretch.stretch(original) ?? original
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
        if enableSkyGroundMask && !isNightscapeActive && maskBitmap == nil {
            stackingStatus = "⚠️ 比較明合成で空と地上を分ける場合は、地上領域をブラシで指定してください"
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

        // 解析中なら取りやめる（合成の中で必要な解析を行う）
        cancelNightscapeAnalysis()
        let preparedNightscape = isNightscapeActive ? nightscapePrepared : nil
        let nightscapeKey = currentNightscapeKey()

        isStacking = true
        stackingProgress = 0.0
        stackingStatus = "キャリブレーションフレームを構築中..."
        stackedResult = nil
        stackedRawResult = nil
        notifyStateChanged()

        let darkFiles  = images[.dark]  ?? []
        let flatFiles  = images[.flat]  ?? []
        let biasFiles  = images[.bias]  ?? []
        let mode       = stackMode
        let useSkyGroundMask = enableSkyGroundMask
        // 新星景モード（平均・中央値）: 空は星に、地上は地上に合わせる（塗ったマスクは判定の手がかり）
        let nightscape = isNightscapeActive
        let doAlign    = isAlignmentEnabledForCurrentMode
        let mask       = useSkyGroundMask ? maskBitmap : nil
        let maskFeather = maskFeatherRadius
        let nightscapeFeather = nightscapeFeatherRadius
        let clipping = activeSigmaClipping
        let groundFixedURLs = isGroundFixedActive ? (images[.groundFixed] ?? []).map(\.url) : []
        let trailRemovalActive = (mode == "Compare Bright" && enableTrailRemoval)
        let trailItems = self.detectedTrails
        let knownBaseMetadata = baseImageMetadata

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 全てベイヤー配列のRAWなら、現像せずにセンサーデータのまま合成する
            // （位置合わせなし・比較明はベイヤー配列、位置合わせありはカメラ色空間RGB）。
            let rawInput = RawStackPipeline.Input(
                lights: lightFiles.map(\.url),
                baseIndex: lightFiles.firstIndex(where: { $0.id == base.id }) ?? 0,
                darks: darkFiles.map(\.url),
                flats: flatFiles.map(\.url),
                biases: biasFiles.map(\.url),
                mode: mode == "Median" ? .median : (mode == "Compare Bright" ? .compareBright : .average),
                align: doAlign,
                skyGroundMask: mask,
                maskFeatherRadius: maskFeather,
                trailMasks: trailRemovalActive
                    ? Dictionary(grouping: trailItems.filter(\.isMarkedForRemoval), by: \.frameIndex)
                        .mapValues { $0.compactMap(\.maskImage) }
                    : [:],
                nightscape: nightscape,
                nightscapeFeatherRadius: nightscapeFeather,
                sigmaClipping: clipping,
                groundFixed: groundFixedURLs
            )
            var rawFallbackReason: String?
            do {
                var rawPrepared: RawStackPipeline.NightscapePreparation?
                if case .raw(let preparation)? = preparedNightscape { rawPrepared = preparation }
                if let rawResult = try RawStackPipeline.stack(rawInput, nightscape: rawPrepared, progress: { fraction, status in
                    DispatchQueue.main.async {
                        self.stackingProgress = fraction
                        self.stackingStatus = status
                        self.notifyStateChanged()
                    }
                }) {
                    let resolvedBaseMetadata = knownBaseMetadata ?? RawMetadataExtractor.extract(from: base.url)
                    // 自動判定の結果を、表示の向きのマスクにしてブラシで直せるようにする
                    let overlay = rawResult.skyAlpha.flatMap { alpha in
                        StackingStateController.displayOrientedOverlay(
                            NightscapeCompositor.hintOverlay(skyAlpha: alpha, width: rawResult.width, height: rawResult.height),
                            orientation: Int(rawResult.info.orientation))
                    }
                    // 解析は状態で持つので、結果には持たせない（メモリに二重に残さない）
                    var storedResult = rawResult
                    storedResult.nightscape = nil
                    DispatchQueue.main.async {
                        self.stackedResult = rawResult.displayImage
                        self.stackedRawResult = storedResult
                        self.stackedResultMetadata = resolvedBaseMetadata
                        self.previewImage = nil
                        self.stackingProgress = 1.0
                        if let preparation = rawResult.nightscape { self.nightscapePrepared = .raw(preparation) }
                        // ブラシで塗った所は残し、それ以外を今回の判定結果にする
                        if let overlay { self.maskBitmap = NightscapeCompositor.mergingUserStrokes(from: self.maskBitmap, onto: overlay) }
                        let method = rawResult.skyAlpha != nil
                            ? "新星景モード・\(rawResult.modeDescription)" : rawResult.modeDescription
                        self.stackingStatus = "✅ スタッキング完了！（\(method)で合成）"
                            + (rawResult.note.map { "\n\($0)" } ?? "")
                            + (StackingStateController.sigmaClippingNote(
                                clipping, frameCount: lightFiles.count, nightscape: rawResult.skyAlpha != nil).map { "\n\($0)" } ?? "")
                        self.isStacking = false
                        self.showResult = true
                        self.notifyStateChanged()
                    }
                    return
                }
            } catch let error as RawStackPipeline.PipelineError where !error.allowsFallback {
                self.finishStackingWithError(error.message)
                return
            } catch {
                // RAWのまま合成できない場合は、従来どおり現像済み画像で合成する
                rawFallbackReason = error.localizedDescription
            }

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
                    self.stackingProgress = Double(i + 1) / Double(total) * (doAlign || nightscape ? 0.35 : 0.75)
                    self.stackingStatus = "画像を読み込み・補正中 (\(i + 1)/\(total))..."
                    self.notifyStateChanged()
                }
            }

            // 新星景モード: 空は星に、地上は地上に合わせて合成する。分ける必要が無い・できないときは通常の合成にする
            var alignFrames = doAlign
            var nightscapeImage: NSImage?
            var nightscapeOverlay: NSImage?
            var notes: [String] = []
            if nightscape {
                let baseIndex = calibratedFrames.firstIndex(where: { $0.file.id == base.id }) ?? 0
                do {
                    guard let first = NightscapeCompositor.rgb16(from: calibratedFrames[baseIndex].image) else {
                        throw NightscapeCompositor.CompositorError(message: "基準画像を読み込めませんでした")
                    }
                    let hints = mask.flatMap { NightscapeCompositor.hints(from: $0, width: first.width, height: first.height) }
                    let loadFrame: (Int) throws -> [UInt16] = { index in
                        if index == baseIndex { return first.pixels }
                        guard let frame = NightscapeCompositor.rgb16(from: calibratedFrames[index].image),
                              frame.width == first.width, frame.height == first.height else {
                            throw NightscapeCompositor.CompositorError(
                                message: "画像サイズが一致しません: \(calibratedFrames[index].file.name)")
                        }
                        return frame.pixels
                    }
                    let report: (Double, String) -> Void = { fraction, status in
                        DispatchQueue.main.async {
                            self.stackingProgress = 0.35 + fraction * 0.6
                            self.stackingStatus = status
                            self.notifyStateChanged()
                        }
                    }
                    // 同じ入力で解析済みなら使い回す（位置合わせと判定用のデータ集めをやり直さない）
                    let analysis: NightscapeCompositor.Analysis
                    var composeHints = hints
                    if case .developed(let key, let prepared)? = preparedNightscape, key == nightscapeKey {
                        analysis = prepared
                    } else {
                        // 前回の自動判定の結果は、その解析を使い回すときだけ手がかりにする
                        composeHints = hints.flatMap(NightscapeCompositor.userHints)
                        let groundReference = groundFixedURLs.isEmpty ? nil : try StackingStateController.developedGroundReference(
                            input: rawInput, masterBias: masterBias, masterFlat: masterFlat, progress: { _, status in
                                DispatchQueue.main.async { self.stackingStatus = status }
                            })
                        analysis = try NightscapeCompositor.analyze(
                            frameCount: total, baseIndex: baseIndex, width: first.width, height: first.height,
                            hints: hints.flatMap(NightscapeCompositor.userHints), groundReference: groundReference?.pixels,
                            loadFrame: loadFrame,
                            progress: { fraction, status in report(fraction * 0.5, status) })
                        if groundReference?.matchedExposure == false {
                            analysis.groundReferenceNote = NightscapeCompositor.unmatchedExposureNote
                        }
                    }
                    if let nightscapeKey {
                        DispatchQueue.main.async { self.nightscapePrepared = .developed(key: nightscapeKey, analysis: analysis) }
                    }
                    let outcome = try NightscapeCompositor.compose(
                        analysis: analysis, hints: composeHints, featherRadius: Double(nightscapeFeather), clipping: clipping,
                        loadFrame: loadFrame,
                        progress: { fraction, status in report(0.5 + fraction * 0.5, status) })
                    switch outcome {
                    case .composited(let composited):
                        nightscapeImage = NightscapeCompositor.image(from: NightscapeCompositor.RGB16Image(
                            pixels: composited.pixels, width: first.width, height: first.height, colorSpace: first.colorSpace))
                        nightscapeOverlay = NightscapeCompositor.hintOverlay(
                            skyAlpha: composited.skyAlpha, width: first.width, height: first.height
                        ).map { NSImage(cgImage: $0, size: NSSize(width: first.width, height: first.height)) }
                        if mode == "Median" { notes.append("新星景モードでは、中央値の代わりに外れ値を除いた平均で合成しました") }
                        if !groundFixedURLs.isEmpty {
                            notes.append("地上は地上固定フレーム（\(groundFixedURLs.count)枚）にし、その構図で合成しました")
                            if let note = analysis.groundReferenceNote { notes.append(note) }
                        }
                        if composited.groundFallbackCount > 0 {
                            notes.append("地上の位置合わせができなかった\(composited.groundFallbackCount)枚は、隣のフレームと同じ動きとして合成しました")
                        }
                    case .notNeeded(let reason):
                        notes.append(groundFixedURLs.isEmpty ? reason : "\(reason)。地上固定フレームは使いませんでした")
                        alignFrames = true
                    }
                } catch where !groundFixedURLs.isEmpty {
                    // 地上固定フレームを登録したときは、黙って地上固定フレームを使わない合成にしない
                    self.finishStackingWithError("新星景モード（地上固定フレーム）で合成できませんでした（\(error.localizedDescription)）")
                    return
                } catch {
                    notes.append("新星景モードで合成できなかったため、空と地上を分けずに合成しました（\(error.localizedDescription)）")
                }
            }

            var skyFrames = calibratedFrames.map(\.image)
            if nightscapeImage == nil && alignFrames {
                guard let baseFrame = calibratedFrames.first(where: { $0.file.id == base.id }),
                      let baseReferenceURL = self.writeTemporaryTIFF(baseFrame.image, prefix: "base") else {
                    self.finishStackingWithError("基準画像を位置合わせ用に準備できませんでした")
                    return
                }
                defer { try? FileManager.default.removeItem(at: baseReferenceURL) }

                // 地上の模様に引きずられないよう、星だけで位置合わせする
                let starAligner: StarAligner
                do {
                    starAligner = try StarAligner(baseImageAt: baseReferenceURL, skyMask: nil)
                } catch {
                    self.finishStackingWithError("星の位置合わせを準備できませんでした（\(error.localizedDescription)）")
                    return
                }
                // 直前のフレームの変換を初期値にする（隣り合うフレームほど星の動きが近い）
                var previousHomography: [NSNumber]?

                skyFrames.removeAll(keepingCapacity: true)
                for (i, frame) in calibratedFrames.enumerated() {
                    if frame.file.id == base.id {
                        skyFrames.append(frame.image)
                        previousHomography = [1, 0, 0, 0, 1, 0, 0, 0, 1]
                    } else {
                        guard let targetURL = self.writeTemporaryTIFF(frame.image, prefix: "align") else {
                            self.finishStackingWithError("位置合わせ用画像を準備できませんでした: \(frame.file.name)")
                            return
                        }
                        do {
                            let homography = try starAligner.homographyForImage(at: targetURL,
                                                                         initialGuess: previousHomography)
                            previousHomography = homography
                            let aligned = try ImageAligner.warpImage(at: targetURL, homography: homography)
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

            let result: NSImage?
            if let nightscapeImage {
                result = nightscapeImage
            } else if useSkyGroundMask && !nightscape, let maskImg = mask {
                let skyStacked = self.stack(images: skyFrames, mode: sMode)
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
                result = self.stack(images: skyFrames, mode: sMode, sigmaClipping: sMode == .average ? clipping : nil)
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
                if let nightscapeOverlay {
                    self.maskBitmap = NightscapeCompositor.mergingUserStrokes(from: self.maskBitmap, onto: nightscapeOverlay)
                }
                var status: String
                if let rawFallbackReason {
                    status = "✅ スタッキング完了（RAWのまま合成できなかったため現像済み画像で合成: \(rawFallbackReason)）"
                } else {
                    status = nightscapeImage != nil ? "✅ スタッキング完了！（新星景モードで合成）" : "✅ スタッキング完了！"
                }
                for note in notes { status += "\n\(note)" }
                if let note = StackingStateController.sigmaClippingNote(
                    clipping, frameCount: total, nightscape: nightscapeImage != nil) { status += "\n\(note)" }
                self.stackingStatus = status
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

    private func stack(images: [NSImage], mode: ImageStacker.StackMode, sigmaClipping: SigmaClipping? = nil) -> NSImage? {
        switch mode {
        case .average where sigmaClipping != nil:
            // シグマクリッピングは全フレームの値を比べるため CPU で行う
            return ImageStacker.stack(images: images, mode: .average, sigmaClipping: sigmaClipping)
        case .average:
            return MetalStacker.create()?.stackAverage(images: images)
                ?? ImageStacker.stack(images: images, mode: .average)
        case .median, .compareBright:
            return ImageStacker.stack(images: images, mode: mode)
        }
    }

    /// シグマクリッピングについての完了時の補足（新星景モードは外れ値の幅に使うだけなので書かない）
    static func sigmaClippingNote(_ clipping: SigmaClipping?, frameCount: Int, nightscape: Bool) -> String? {
        guard let clipping, !nightscape else { return nil }
        guard frameCount >= SigmaClipping.minimumFrames else {
            return "\(SigmaClipping.minimumFrames)枚未満のため、シグマクリッピングは行わずに平均しました"
        }
        return String(format: "シグマクリッピング（κ 下側%.1f・上側%.1f）で外れ値を除いて平均しました", clipping.low, clipping.high)
    }

    /// センサーの向きのマスク画像を、表示（撮影時）の向きにする
    static func displayOrientedOverlay(_ image: CGImage?, orientation: Int) -> NSImage? {
        guard let image else { return nil }
        let displayOrientation = CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up
        guard displayOrientation != .up else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(displayOrientation.rawValue))  // oriented(_:) は 10.13 以降
        let extent = oriented.extent
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let rendered = context.createCGImage(
            oriented.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)),
            from: CGRect(origin: .zero, size: extent.size), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else { return nil }
        return NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
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
