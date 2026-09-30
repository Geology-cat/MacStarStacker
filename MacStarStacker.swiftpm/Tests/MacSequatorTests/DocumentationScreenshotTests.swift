import XCTest
import AppKit
@testable import MacSequator

/// 使い方の説明書（docs/manual）のスクリーンショットを撮る（手動で実行する。release で数十分かかる）。
/// 環境変数 DOC_SCREENSHOTS_DIR に書き出し先（docs/manual/figures）、DOC_SAMPLE_DIR に RAW のフォルダ
/// （名前に「地上固定」を含むものは地上固定フレームとして使う）を指定したときだけ実行する。
///
/// 画面ごとに、画像（<名前>.jpg）と、説明の矢印を描く位置（<名前>.coords.tex）を書き出す。
/// 位置は画面の部品から求めるので、画面の配置が変わっても撮り直せば矢印の位置も合う。
final class DocumentationScreenshotTests: XCTestCase {
    private var outputDirectory: URL!
    /// 画面全体を撮るウインドウとその大きさ
    private var fixedWindow: NSWindow?
    private var fixedWindowSize: NSSize?

    // MARK: - 撮影

    /// ビューを2倍の解像度で描いて JPEG にし、部品の位置を書き出す。
    /// cropTo を指定すると、それらの部品を囲む範囲（まわりに margin）だけを切り出す
    private func shoot(_ name: String, view: NSView, marks: [(String, NSView?)] = [],
                       rects: [(String, NSRect)] = [], cropTo: [NSView?] = [], cropRects: [NSRect] = [],
                       margin: CGFloat = 8) throws {
        // 画面全体を撮るときは、ウインドウの大きさを決まった大きさに戻す（ファイル名の長さなどで広がることがある）
        if let window = view.window, window === fixedWindow, window.contentView === view, let size = fixedWindowSize {
            window.setContentSize(size)
            settle(0.3)
        }
        view.layoutSubtreeIfNeeded()
        view.display()
        let full = view.bounds.size
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(full.width * scale), pixelsHigh: Int(full.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = full
        view.cacheDisplay(in: view.bounds, to: rep)

        // 左下を原点にした、ビューの中での部品の位置
        func frame(of markView: NSView) -> NSRect {
            var rect = markView.convert(markView.bounds, to: view)
            if view.isFlipped { rect.origin.y = full.height - rect.maxY }
            return rect
        }
        var crop = NSRect(origin: .zero, size: full)
        let cropFrames = cropTo.compactMap { $0 }.map(frame) + cropRects
        if let first = cropFrames.first {
            crop = cropFrames.reduce(first) { $0.union($1) }
                .insetBy(dx: -margin, dy: -margin).intersection(crop).integral
            let cg = try XCTUnwrap(rep.cgImage)
            // CGImage は上が原点
            let pixels = CGRect(x: crop.minX * scale, y: (full.height - crop.maxY) * scale,
                                width: crop.width * scale, height: crop.height * scale)
            let cropped = NSBitmapImageRep(cgImage: try XCTUnwrap(cg.cropping(to: pixels)))
            try writeJPEG(cropped, name: name)
        } else {
            try writeJPEG(rep, name: name)
        }
        let size = crop.size

        var lines = ["% DocumentationScreenshotTests が書き出す（手で編集しない）。\\shotmark{画面}{部品}{中心x}{中心y}{幅}{高さ}"]
        func add(_ markName: String, _ rect: NSRect) {
            lines.append(String(format: "\\shotmark{%@}{%@}{%.4f}{%.4f}{%.4f}{%.4f}", name, markName,
                                (rect.midX - crop.minX) / size.width, (rect.midY - crop.minY) / size.height,
                                rect.width / size.width, rect.height / size.height))
        }
        for (markName, markView) in marks {
            guard let markView else {
                XCTFail("\(name): 部品「\(markName)」が見つかりません")
                continue
            }
            add(markName, frame(of: markView))
        }
        // 画像の左下を原点にした、見た目の位置（部品ではない所）
        for (markName, rect) in rects { add(markName, rect) }
        try (lines.joined(separator: "\n") + "\n").write(
            to: outputDirectory.appendingPathComponent("\(name).coords.tex"), atomically: true, encoding: .utf8)
        print("撮影: \(name) \(Int(size.width))x\(Int(size.height))")
    }

    private func writeJPEG(_ rep: NSBitmapImageRep, name: String) throws {
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]))
        try jpeg.write(to: outputDirectory.appendingPathComponent("\(name).jpg"))
    }

    /// 写真（合成結果など）を長辺 maxSide に縮めて保存する
    private func savePhoto(_ image: NSImage, name: String, maxSide: CGFloat = 1800) throws {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let width = Int(CGFloat(cg.width) * scale), height = Int(CGFloat(cg.height) * scale)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        try writeJPEG(rep, name: name)
        print("写真: \(name) \(width)x\(height)")
    }

    /// 写真の一部（左上を原点に、幅・高さを1とした範囲）を等倍で切り出して保存する
    private func saveCrop(_ image: NSImage, name: String, rect: CGRect, maxSide: CGFloat = 900) throws {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let crop = CGRect(x: rect.minX * CGFloat(cg.width), y: rect.minY * CGFloat(cg.height),
                          width: rect.width * CGFloat(cg.width), height: rect.height * CGFloat(cg.height)).integral
        let cropped = try XCTUnwrap(cg.cropping(to: crop))
        try savePhoto(NSImage(cgImage: cropped, size: .zero), name: name, maxSide: maxSide)
    }

    // MARK: - 部品を探す

    private func allViews(_ root: NSView) -> [NSView] {
        var result: [NSView] = [], stack = [root]
        while let view = stack.popLast() {
            result.append(view)
            stack.append(contentsOf: view.subviews.reversed())
        }
        return result
    }

    private func find<T: NSView>(_ root: NSView, _ type: T.Type, where predicate: (T) -> Bool = { _ in true }) -> T? {
        allViews(root).compactMap { $0 as? T }.first(where: { !$0.isHiddenOrHasHiddenAncestor && predicate($0) })
    }

    /// タイトルが title で始まるボタン（exact なら一致するもの）
    private func button(_ root: NSView, _ title: String, exact: Bool = false) -> NSButton? {
        find(root, NSButton.self) { $0.title == title || (!exact && $0.title.hasPrefix(title)) }
    }

    private func label(_ root: NSView, containing text: String) -> NSTextField? {
        find(root, NSTextField.self) { !$0.isEditable && $0.stringValue.contains(text) }
    }

    private func segmented(_ root: NSView, containing label: String) -> NSSegmentedControl? {
        find(root, NSSegmentedControl.self) { control in
            (0..<control.segmentCount).contains { (control.label(forSegment: $0) ?? "").contains(label) }
        }
    }

    private func popup(_ root: NSView, containing item: String) -> NSPopUpButton? {
        find(root, NSPopUpButton.self) { $0.itemTitles.contains { $0.contains(item) } }
    }

    private func card(_ root: NSView, _ title: String) -> SectionCardView? {
        find(root, SectionCardView.self) { $0.titleLabel.stringValue == title }
    }

    private func identified(_ root: NSView, _ identifier: String) -> NSView? {
        find(root, NSView.self) { $0.identifier?.rawValue == identifier }
    }

    private func slider(_ root: NSView, maxValue: Double? = nil, identifier: String? = nil) -> NSSlider? {
        find(root, NSSlider.self) { slider in
            (identifier == nil || slider.identifier?.rawValue == identifier)
                && (maxValue == nil || slider.maxValue == maxValue)
        }
    }

    /// プレビューで写真が表示されている範囲（view の中、左下を原点）
    private func drawnImageRect(_ canvas: MaskCanvasView?, in view: NSView) -> NSRect {
        guard let canvas, let image = canvas.currentImage, image.size.height > 0 else { return .zero }
        let bounds = canvas.bounds, aspect = image.size.width / image.size.height
        var width = bounds.width, height = width / aspect
        if height > bounds.height { height = bounds.height; width = height * aspect }
        var rect = canvas.convert(NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height),
                                  to: view)
        if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
        return rect
    }

    // MARK: - 状態

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }

    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// アプリと同じ3つの画面（ファイルリスト・プレビュー・設定）を並べたウィンドウ
    private func makeWindow(width: CGFloat, height: CGFloat) -> (NSWindow, MainSplitViewController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MacStarStacker - 星景写真スタッキング"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let split = MainSplitViewController()
        window.contentViewController = split
        window.setContentSize(NSSize(width: width, height: height))
        settle()
        return (window, split)
    }

    private func selectTab(_ settings: NSView, _ index: Int) {
        guard let tabs = segmented(settings, containing: "タイムラプス") else { return XCTFail("タブがありません") }
        tabs.selectedSegment = index
        tabs.sendAction(tabs.action, to: tabs.target)
        settle()
    }

    /// 自動判定の結果のマスクに、空（青）のブラシで塗った所を足す（ブラシで直す例）。
    /// ellipse は画像の左上を原点に、幅・高さを1とした範囲
    private func paintSky(on mask: NSImage, ellipses: [CGRect]) throws -> NSImage {
        let cg = try XCTUnwrap(mask.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let width = cg.width, height = cg.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0.2, blue: 1, alpha: 1))
        for ellipse in ellipses {
            context.fillEllipse(in: CGRect(x: ellipse.minX * CGFloat(width), y: (1 - ellipse.maxY) * CGFloat(height),
                                           width: ellipse.width * CGFloat(width), height: ellipse.height * CGFloat(height)))
        }
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: mask.size)
    }

    // MARK: - 撮影する画面

    func testCaptureScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["DOC_SCREENSHOTS_DIR"], let sample = environment["DOC_SAMPLE_DIR"] else {
            throw XCTSkip("DOC_SCREENSHOTS_DIR と DOC_SAMPLE_DIR を指定したときだけ実行する")
        }
        outputDirectory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: sample), includingPropertiesForKeys: nil)
            .filter(RawDecoder.isRawFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let lights = files.filter { !$0.lastPathComponent.contains("地上固定") }
        let groundFixed = files.filter { $0.lastPathComponent.contains("地上固定") }
        let state = StackingStateController.shared
        state.resetAll()
        defer { state.resetAll() }

        // 画面全体（1280x800）と、設定パネルを縦に全部写すための縦長のウィンドウ
        let (window, split) = makeWindow(width: 1280, height: 800)
        fixedWindow = window
        fixedWindowSize = NSSize(width: 1280, height: 800)
        let (tallWindow, tallSplit) = makeWindow(width: 1280, height: 1560)
        defer { window.close(); tallWindow.close() }
        let root = try XCTUnwrap(window.contentView)
        let settings = tallSplit.settingsVC.view

        // ── 起動した直後 ──
        try shoot("main_empty", view: root, marks: [
            ("filelist", split.fileListVC.view), ("canvas", split.canvasVC.view), ("settings", split.settingsVC.view),
            ("add", button(root, "＋ 追加")), ("types", segmented(root, containing: "Dark")),
        ])

        // ── Light を読み込んだところ ──
        state.add(urls: lights, to: .light)
        waitUntil(timeout: 180) { (state.images[.light] ?? []).allSatisfy { $0.metadata != nil } }
        settle(1)
        let fileList = split.fileListVC.view
        try shoot("main_loaded", view: root, marks: [
            ("filelist", split.fileListVC.view), ("canvas", split.canvasVC.view), ("settings", split.settingsVC.view),
            ("base", label(root, containing: "★ 基準")), ("star", button(root, "★", exact: true)),
            ("start", button(root, "★ スタッキング開始")), ("export", button(root, "結果を書き出す")),
        ])
        try shoot("filelist", view: fileList, marks: [
            ("reset", button(fileList, "すべてクリア")), ("base", label(fileList, containing: "★ 基準")),
            ("types", segmented(fileList, containing: "Light")), ("add", button(fileList, "＋ 追加")),
            ("clear", button(fileList, "リストをクリア")), ("star", button(fileList, "★", exact: true)),
            ("unstar", button(fileList, "☆", exact: true)), ("remove", button(fileList, "✕", exact: true)),
            ("row", find(fileList, NSTableRowView.self)), ("table", find(fileList, NSTableView.self)),
        ])
        let canvas = split.canvasVC.view
        try shoot("canvas", view: canvas, marks: [
            ("autostretch", button(canvas, "Auto Stretch")), ("zoomout", button(canvas, "−", exact: true)),
            ("zoomin", button(canvas, "+", exact: true)), ("zoomreset", button(canvas, "1:1", exact: true)),
            ("filename", label(canvas, containing: ".CR2")), ("image", find(canvas, MaskCanvasView.self)),
        ], cropTo: [button(canvas, "Auto Stretch"), button(canvas, "1:1", exact: true)],
           cropRects: [drawnImageRect(find(canvas, MaskCanvasView.self), in: canvas)], margin: 6)

        // ── 設定パネル（スタック） ──
        settle(0.5)
        try shoot("settings_stack", view: settings, marks: [
            ("tabs", segmented(settings, containing: "タイムラプス")), ("method", card(settings, "スタック方式")),
            ("mode", popup(settings, containing: "平均")), ("align", button(settings, "アライメント")),
            ("sigma", button(settings, "シグマクリッピング")), ("mask", card(settings, "空と地上（新星景モード）")),
            ("lens", card(settings, "レンズプロファイル")), ("embed", button(settings, "DNGにレンズプロファイル")),
            ("lensname", find(settings, NSTextField.self) { $0.isEditable && ($0.placeholderString ?? "").contains("レンズ") }),
            ("output", card(settings, "書き出し & 実行")), ("format", popup(settings, containing: "RAW (DNG)")),
            ("start", button(settings, "★ スタッキング開始")), ("export", button(settings, "結果を書き出す")),
        ], cropTo: [segmented(settings, containing: "タイムラプス"), card(settings, "書き出し & 実行")])

        // シグマクリッピング
        state.enableSigmaClipping = true
        settle()
        try shoot("settings_sigma", view: try XCTUnwrap(card(settings, "スタック方式")), marks: [
            ("sigma", button(settings, "シグマクリッピング")), ("low", identified(settings, "SigmaLowField")),
            ("high", identified(settings, "SigmaHighField")), ("mode", popup(settings, containing: "平均")),
        ])
        state.enableSigmaClipping = false

        // 比較明合成
        state.stackMode = "Compare Bright"
        state.enableTrailRemoval = true
        settle()
        try shoot("settings_comparebright", view: settings, marks: [
            ("mode", popup(settings, containing: "比較明")), ("align", button(settings, "アライメント")),
            ("trail", button(settings, "✈️ 飛行機")), ("analyzetrails", button(settings, "🔍 光跡を解析")),
            ("mask", button(settings, "空と地上を分けて合成")), ("maskcard", card(settings, "空と地上（新星景モード）")),
        ], cropTo: [segmented(settings, containing: "タイムラプス"), card(settings, "空と地上（新星景モード）")])
        state.enableTrailRemoval = false
        state.stackMode = "Average"

        // タイムラプス
        selectTab(settings, 1)
        try shoot("settings_timelapse", view: settings, marks: [
            ("tabs", segmented(settings, containing: "タイムラプス")), ("range", card(settings, "フレーム範囲")),
            ("speed", card(settings, "再生速度")), ("durationmode", segmented(settings, containing: "FPS指定")),
            ("process", card(settings, "補正 & 画質")), ("align", popup(settings, containing: "地上に合わせる")),
            ("deflicker", button(settings, "フリッカー除去")), ("autostretch", button(settings, "オートストレッチ")),
            ("resolution", popup(settings, containing: "1080p")), ("codec", popup(settings, containing: "H.264")),
            ("write", button(settings, "タイムラプス書き出し")),
        ], cropTo: [segmented(settings, containing: "タイムラプス"), button(settings, "タイムラプス書き出し")], margin: 14)
        selectTab(settings, 0)

        // ── 平均で合成（まずはやってみよう） ──
        state.startStacking()
        waitUntil(timeout: 600) { state.stackingProgress >= 0.3 || !state.isStacking }
        settle(0.3)
        try shoot("main_stacking", view: root, marks: [
            ("progress", find(canvas, NSProgressIndicator.self)),
            ("status", find(canvas, NSTextField.self) { !$0.stringValue.isEmpty && $0.stringValue.contains("中") }),
        ])
        waitUntil(timeout: 1200) { !state.isStacking }
        settle(1)
        try shoot("main_result_average", view: root, marks: [
            ("toggle", button(root, "元画像を表示")), ("status", label(root, containing: "スタッキング完了")),
            ("export", button(root, "結果を書き出す")), ("format", popup(root, containing: "RAW (DNG)")),
            ("image", find(canvas, MaskCanvasView.self)),
        ])
        if let result = state.stackedResult { try savePhoto(result, name: "photo_average") }

        // ── 新星景モード ──
        state.enableSkyGroundMask = true
        settle()
        try shoot("settings_nightscape", view: try XCTUnwrap(card(settings, "空と地上（新星景モード）")), marks: [
            ("check", button(settings, "新星景モード")), ("hint", label(settings, containing: "「解析開始」を押すと")),
            ("register", button(settings, "地上固定フレーム登録")), ("unregister", button(settings, "解除", exact: true)),
            ("analyze", button(settings, "解析開始")), ("brush", segmented(settings, containing: "消しゴム")),
            ("size", slider(settings, maxValue: 150) ?? find(settings, NSSlider.self)),
            ("feather", slider(settings, identifier: "MaskFeatherSlider")), ("clearmask", button(settings, "マスクをクリア")),
        ])

        state.analyzeNightscape()
        settle(1)
        waitUntil(timeout: 900) { !state.isAnalyzingNightscape }
        settle(1)
        XCTAssertNotNil(state.maskBitmap, state.nightscapeAnalysisStatus)
        try shoot("main_analyzed", view: root, marks: [
            ("canvas", split.canvasVC.view), ("image", find(canvas, MaskCanvasView.self)),
            ("analyze", button(root, "解析開始")), ("brush", segmented(root, containing: "消しゴム")),
            ("status", label(root, containing: "自動で判定しました")), ("start", button(root, "★ スタッキング開始")),
        ])
        // ブラシで直す例は、直す所（左下）を大きく見せる
        func lowerLeft(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX, y: rect.minY + rect.height * 0.05, width: rect.width * 0.45, height: rect.height * 0.45)
        }
        let drawn = drawnImageRect(find(canvas, MaskCanvasView.self), in: canvas)
        try shoot("canvas_analyzed", view: canvas, cropRects: [lowerLeft(drawn)], margin: 0)

        // ブラシで直した例（左端の空を塗り足す）
        let mask = try XCTUnwrap(state.maskBitmap)
        state.maskBitmap = try paintSky(on: mask, ellipses: [CGRect(x: -0.02, y: 0.70, width: 0.09, height: 0.10)])
        settle(1)
        try shoot("canvas_brushed", view: canvas, cropRects: [lowerLeft(drawn)], margin: 0)

        // 合成中
        state.startStacking()
        waitUntil(timeout: 600) { state.stackingProgress >= 0.3 || !state.isStacking }
        settle(0.3)
        try shoot("main_stacking_nightscape", view: root, marks: [
            ("progress", find(canvas, NSProgressIndicator.self)),
            ("status", find(canvas, NSTextField.self) { $0.stringValue.contains("新星景モード") }),
        ])
        waitUntil(timeout: 1200) { !state.isStacking }
        settle(1)
        XCTAssertNotNil(state.stackedResult, state.stackingStatus)
        try shoot("main_result", view: root, marks: [
            ("toggle", button(root, "元画像を表示")), ("status", label(root, containing: "スタッキング完了")),
            ("export", button(root, "結果を書き出す")), ("format", popup(root, containing: "RAW (DNG)")),
            ("image", find(canvas, MaskCanvasView.self)),
        ])
        if let result = state.stackedResult { try savePhoto(result, name: "photo_nightscape") }
        // 1枚とスタック結果のノイズの比べ（同じ所を等倍で）
        if let single = state.loadNSImage(from: state.baseImage), let result = state.stackedResult {
            let region = CGRect(x: 0.42, y: 0.30, width: 0.12, height: 0.14)
            try saveCrop(single, name: "photo_single_crop", rect: region)
            try saveCrop(result, name: "photo_stacked_crop", rect: region)
        }

        // ── 地上固定フレーム ──
        state.add(urls: groundFixed, to: .groundFixed)
        settle(1)
        try shoot("filelist_groundfixed", view: fileList, marks: [
            ("section", label(fileList, containing: "地上固定フレーム（")), ("light", label(fileList, containing: "Light（")),
        ])
        state.analyzeNightscape()
        settle(1)
        waitUntil(timeout: 900) { !state.isAnalyzingNightscape }
        settle(1)
        try shoot("main_groundfixed", view: root, marks: [
            ("register", button(root, "地上固定フレーム登録")), ("section", label(root, containing: "地上固定フレーム（")),
            ("image", find(canvas, MaskCanvasView.self)), ("analyze", button(root, "解析開始")),
        ])
        state.nightscapeFeatherRadius = 150
        state.startStacking()
        settle(1)
        waitUntil(timeout: 1200) { !state.isStacking }
        settle(1)
        try shoot("main_groundfixed_result", view: root, marks: [
            ("feather", slider(root, identifier: "MaskFeatherSlider")), ("status", label(root, containing: "地上固定フレーム（")),
        ])
        if let result = state.stackedResult { try savePhoto(result, name: "photo_groundfixed") }
        state.clear(type: .groundFixed)
        state.enableSkyGroundMask = false
        state.nightscapeFeatherRadius = 0

        // ── 比較明合成と光跡の確認 ──
        state.stackMode = "Compare Bright"
        state.enableTrailRemoval = true
        var reviewItems: [DetectedTrailItem] = []
        state.onRequestShowTrailReview = { reviewItems = $0 }
        state.analyzeTrails()
        settle(1)
        waitUntil(timeout: 1200) { !state.isAnalyzingTrails }
        settle(1)
        if !reviewItems.isEmpty {
            let review = TrailReviewViewController(items: reviewItems)
            let reviewWindow = review.makeReviewWindow()
            reviewWindow.appearance = NSAppearance(named: .darkAqua)
            reviewWindow.setContentSize(NSSize(width: 1000, height: 640))
            settle(1)
            let reviewView = review.view
            try shoot("trail_review", view: reviewView, marks: [
                ("highlight", button(reviewView, "光跡ハイライトを表示")), ("protect", button(reviewView, "🌠 流星候補を保護")),
                ("all", button(reviewView, "全選択")), ("none", button(reviewView, "全解除")),
                ("list", find(reviewView, NSScrollView.self)), ("cancel", button(reviewView, "キャンセル")),
                ("apply", button(reviewView, "確定して")),
            ])
            reviewWindow.close()
        } else {
            XCTFail("光跡が検出されませんでした: \(state.trailAnalysisStatus)")
        }
    }
}
