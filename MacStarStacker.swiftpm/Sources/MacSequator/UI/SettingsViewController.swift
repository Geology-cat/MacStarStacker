import Cocoa

/// 上から下にスクロール・レイアウトするための反転ビュー（macOS 14+）
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// セクションごとの角丸カードビュー
class SectionCardView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let container = NSView()

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor(calibratedWhite: 0.28, alpha: 1.0).cgColor
        layer?.borderWidth = 1.0

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.boldSystemFont(ofSize: 11)
        titleLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        titleLabel.stringValue = title
        addSubview(titleLabel)

        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            container.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 右ペインのスタック設定・タイムラプス設定ビューコントローラ（macOS 14+）
public class SettingsViewController: NSViewController {

    private let tabSegmentedControl = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()

    private let stackViewContainer = NSView()
    private let timelapseViewContainer = NSView()
    /// 表示中のタブだけをスクロール範囲の下端に固定する。両方を固定すると、背の低いタブが
    /// もう一方の高さまで引き伸ばされ、チェックボックスなどの間に余白ができる。
    private lazy var stackBottomConstraint = stackViewContainer.bottomAnchor.constraint(
        equalTo: documentView.bottomAnchor, constant: -16)
    private lazy var timelapseBottomConstraint = timelapseViewContainer.bottomAnchor.constraint(
        equalTo: documentView.bottomAnchor, constant: -16)

    // ── スタック設定コントロール ──
    private let stackModePopup = NSPopUpButton()
    private let alignCheckbox = NSButton(checkboxWithTitle: "アライメント (星の位置合わせ)", target: nil, action: nil)
    private let trailRemovalCheckbox = NSButton(checkboxWithTitle: "✈️ 飛行機・人工衛星の光跡を除去", target: nil, action: nil)
    private let analyzeTrailsButton = NSButton()
    private let trailStatusBadge = NSTextField(labelWithString: "")
    private let skyGroundMaskCheckbox = NSButton(
        checkboxWithTitle: "空と地上を分けて合成（ブラシを使用）",
        target: nil,
        action: nil
    )
    /// 新星景モード・比較明でのマスクの使い方の説明
    private let skyGroundHintLabel = NSTextField(wrappingLabelWithString: "")
    /// 新星景モードの「解析開始」ボタン（比較明では高さを0にして隠す）
    private let analyzeNightscapeButton = NSButton()
    private var analyzeNightscapeButtonHeight: NSLayoutConstraint?
    private var analyzeNightscapeButtonSpacing: NSLayoutConstraint?
    private let brushModeSegmented = NSSegmentedControl()
    private let brushSizeSlider = NSSlider(value: 20, minValue: 5, maxValue: 150, target: nil, action: nil)
    private let brushSizeLabel = NSTextField(labelWithString: "20 px")
    private let maskFeatherSlider = NSSlider(value: 12, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let maskFeatherLabel = NSTextField(labelWithString: "12 px")
    private let clearMaskButton = NSButton()

    // レンズプロファイル
    private let lensInfoCameraLabel = NSTextField(labelWithString: "")
    private let lensInfoLensLabel = NSTextField(labelWithString: "")
    private let lensInfoParamsLabel = NSTextField(labelWithString: "")
    private let embedLensCheckbox = NSButton(checkboxWithTitle: "DNGにレンズプロファイルを埋め込む", target: nil, action: nil)
    private let lensHintLabel = NSTextField(labelWithString: "Lightroom等で開いた際にレンズ補正が自動適用されます")
    private let customLensField = NSTextField()

    // フォーマット & アクション
    private let formatPopup = NSPopUpButton()
    private let startStackButton = NSButton()
    private let exportButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    // ── タイムラプス設定コントロール ──
    private let startFrameSlider = NSSlider()
    private let endFrameSlider = NSSlider()
    private let frameRangeLabel = NSTextField(labelWithString: "")
    private let durationModeSegmented = NSSegmentedControl()
    private let fpsSlider = NSSlider(value: 24, minValue: 1, maxValue: 120, target: nil, action: nil)
    /// 再生速度（fps または秒数）を直接入力する欄と単位
    private let speedField = NSTextField(string: "24")
    private let speedUnitLabel = NSTextField(labelWithString: "fps")
    private let timelapseAlignPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let deflickerCheckbox = NSButton(checkboxWithTitle: "フリッカー除去 (輝度均一化)", target: nil, action: nil)
    private let autoStretchTimelapseCheckbox = NSButton(checkboxWithTitle: "オートストレッチ", target: nil, action: nil)
    private let resolutionPopup = NSPopUpButton()
    private let codecPopup = NSPopUpButton()
    private let startTimelapseButton = NSButton()
    private let timelapseStatusLabel = NSTextField(labelWithString: "")
    private var stateChangeObserver: NSObjectProtocol?
    private var stateResetObserver: NSObjectProtocol?

    override public func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1.0).cgColor

        setupUI()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()

        stateChangeObserver = NotificationCenter.default.addObserver(
            forName: .stackingStateDidChange,
            object: StackingStateController.shared,
            queue: .main
        ) { [weak self] _ in
            self?.updateUI()
        }
        stateResetObserver = NotificationCenter.default.addObserver(
            forName: .stackingStateDidReset,
            object: StackingStateController.shared,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 起動時と同じくスタックタブを表示する。
            self.tabSegmentedControl.selectedSegment = 0
            self.onTabChanged()
            self.view.window?.makeFirstResponder(nil)
            self.updateUI()
        }

        StackingStateController.shared.onRequestShowTrailReview = { [weak self] items in
            self?.presentTrailReview(items: items)
        }

        updateUI()
    }

    deinit {
        for observer in [stateChangeObserver, stateResetObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupUI() {
        // 1. タブ切り替え（スタック / タイムラプス）
        tabSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        tabSegmentedControl.segmentCount = 2
        tabSegmentedControl.setLabel("スタック", forSegment: 0)
        tabSegmentedControl.setLabel("タイムラプス", forSegment: 1)
        tabSegmentedControl.selectedSegment = 0
        tabSegmentedControl.target = self
        tabSegmentedControl.action = #selector(onTabChanged)
        view.addSubview(tabSegmentedControl)

        // 2. スクロールビュー
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        view.addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackViewContainer)
        documentView.addSubview(timelapseViewContainer)

        stackViewContainer.translatesAutoresizingMaskIntoConstraints = false
        timelapseViewContainer.translatesAutoresizingMaskIntoConstraints = false
        timelapseViewContainer.isHidden = true

        buildStackTabUI()
        buildTimelapseTabUI()

        // ── AutoLayout ──
        NSLayoutConstraint.activate([
            // タブ
            tabSegmentedControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            tabSegmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabSegmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tabSegmentedControl.heightAnchor.constraint(equalToConstant: 24),

            // スクロールビュー
            scrollView.topAnchor.constraint(equalTo: tabSegmentedControl.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Document View
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            // Stack Container
            stackViewContainer.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            stackViewContainer.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 10),
            stackViewContainer.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -10),
            stackBottomConstraint,

            // Timelapse Container
            timelapseViewContainer.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            timelapseViewContainer.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 10),
            timelapseViewContainer.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -10),
        ])
    }

    // MARK: - スタックタブ UI 構築

    private func buildStackTabUI() {
        // カード1: スタック方式
        let methodCard = SectionCardView(title: "スタック方式")
        stackModePopup.translatesAutoresizingMaskIntoConstraints = false
        stackModePopup.addItems(withTitles: ["平均 (Average)", "中央値 (Median)", "比較明合成 (Star Trails)"])
        stackModePopup.target = self
        stackModePopup.action = #selector(onStackModeChanged)

        alignCheckbox.translatesAutoresizingMaskIntoConstraints = false
        alignCheckbox.state = StackingStateController.shared.isAlignmentEnabledForCurrentMode ? .on : .off
        alignCheckbox.target = self
        alignCheckbox.action = #selector(onAlignToggled)

        trailRemovalCheckbox.translatesAutoresizingMaskIntoConstraints = false
        trailRemovalCheckbox.title = "✈️ 飛行機・人工衛星の光跡を除去"
        trailRemovalCheckbox.font = NSFont.systemFont(ofSize: 11)
        trailRemovalCheckbox.target = self
        trailRemovalCheckbox.action = #selector(onTrailRemovalToggled)

        analyzeTrailsButton.translatesAutoresizingMaskIntoConstraints = false
        analyzeTrailsButton.title = "🔍 光跡を解析して確認…"
        analyzeTrailsButton.bezelStyle = .rounded
        analyzeTrailsButton.font = NSFont.boldSystemFont(ofSize: 12)
        analyzeTrailsButton.target = self
        analyzeTrailsButton.action = #selector(onAnalyzeTrailsClicked)

        trailStatusBadge.translatesAutoresizingMaskIntoConstraints = false
        trailStatusBadge.font = NSFont.systemFont(ofSize: 10)
        trailStatusBadge.textColor = NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1.0)
        trailStatusBadge.lineBreakMode = .byTruncatingTail

        // 光跡除去の項目は比較明合成のときだけ表示する。非表示の間は場所を取らないよう縦のスタックに並べる
        let methodRows = makeRowStack(
            [stackModePopup, alignCheckbox, trailRemovalCheckbox, analyzeTrailsButton, trailStatusBadge],
            spacings: [8, 8, 6, 4]
        )
        pin(methodRows, to: methodCard.container)
        analyzeTrailsButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        // カード2: コンポジット & マスク
        let maskCard = SectionCardView(title: "空と地上（新星景モード）")
        skyGroundMaskCheckbox.translatesAutoresizingMaskIntoConstraints = false
        skyGroundMaskCheckbox.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        skyGroundMaskCheckbox.state = StackingStateController.shared.enableSkyGroundMask ? .on : .off
        skyGroundMaskCheckbox.target = self
        skyGroundMaskCheckbox.action = #selector(onSkyGroundMaskToggled)

        skyGroundHintLabel.translatesAutoresizingMaskIntoConstraints = false
        skyGroundHintLabel.font = NSFont.systemFont(ofSize: 10)
        skyGroundHintLabel.textColor = .secondaryLabelColor

        analyzeNightscapeButton.translatesAutoresizingMaskIntoConstraints = false
        analyzeNightscapeButton.bezelStyle = .roundRect
        analyzeNightscapeButton.font = NSFont.systemFont(ofSize: 11)
        analyzeNightscapeButton.target = self
        analyzeNightscapeButton.action = #selector(onAnalyzeNightscapeClicked)
        analyzeNightscapeButton.toolTip = "全フレームを位置合わせして空と地上を自動で判定します（ブラシで塗った所は残ります）。解析の結果はスタッキングで使い回します"

        brushModeSegmented.translatesAutoresizingMaskIntoConstraints = false
        brushModeSegmented.segmentCount = 3
        brushModeSegmented.setLabel("空 (青)", forSegment: 0)
        brushModeSegmented.setLabel("地上 (緑)", forSegment: 1)
        brushModeSegmented.setLabel("消しゴム", forSegment: 2)
        brushModeSegmented.selectedSegment = 0
        brushModeSegmented.target = self
        brushModeSegmented.action = #selector(onBrushModeChanged)

        let sizeTitle = NSTextField(labelWithString: "ブラシ:")
        sizeTitle.translatesAutoresizingMaskIntoConstraints = false
        sizeTitle.font = NSFont.systemFont(ofSize: 10)
        sizeTitle.textColor = .secondaryLabelColor

        brushSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        brushSizeSlider.isContinuous = true
        brushSizeSlider.target = self
        brushSizeSlider.action = #selector(onBrushSizeChanged)

        brushSizeLabel.translatesAutoresizingMaskIntoConstraints = false
        brushSizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        brushSizeLabel.alignment = .right

        let featherTitle = NSTextField(labelWithString: "境界ぼかし:")
        featherTitle.translatesAutoresizingMaskIntoConstraints = false
        featherTitle.font = NSFont.systemFont(ofSize: 10)
        featherTitle.textColor = .secondaryLabelColor

        maskFeatherSlider.translatesAutoresizingMaskIntoConstraints = false
        maskFeatherSlider.identifier = NSUserInterfaceItemIdentifier("MaskFeatherSlider")
        maskFeatherSlider.isContinuous = true
        maskFeatherSlider.target = self
        maskFeatherSlider.action = #selector(onMaskFeatherChanged)

        maskFeatherLabel.translatesAutoresizingMaskIntoConstraints = false
        maskFeatherLabel.identifier = NSUserInterfaceItemIdentifier("MaskFeatherLabel")
        maskFeatherLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        maskFeatherLabel.alignment = .right

        clearMaskButton.translatesAutoresizingMaskIntoConstraints = false
        clearMaskButton.title = "マスクをクリア"
        clearMaskButton.bezelStyle = .roundRect
        clearMaskButton.font = NSFont.systemFont(ofSize: 11)
        clearMaskButton.target = self
        clearMaskButton.action = #selector(onClearMaskClicked)

        maskCard.container.addSubview(skyGroundMaskCheckbox)
        maskCard.container.addSubview(skyGroundHintLabel)
        maskCard.container.addSubview(analyzeNightscapeButton)
        maskCard.container.addSubview(brushModeSegmented)
        maskCard.container.addSubview(sizeTitle)
        maskCard.container.addSubview(brushSizeSlider)
        maskCard.container.addSubview(brushSizeLabel)
        maskCard.container.addSubview(featherTitle)
        maskCard.container.addSubview(maskFeatherSlider)
        maskCard.container.addSubview(maskFeatherLabel)
        maskCard.container.addSubview(clearMaskButton)

        NSLayoutConstraint.activate([
            skyGroundMaskCheckbox.topAnchor.constraint(equalTo: maskCard.container.topAnchor),
            skyGroundMaskCheckbox.leadingAnchor.constraint(equalTo: maskCard.container.leadingAnchor),
            skyGroundMaskCheckbox.trailingAnchor.constraint(equalTo: maskCard.container.trailingAnchor),

            skyGroundHintLabel.topAnchor.constraint(equalTo: skyGroundMaskCheckbox.bottomAnchor, constant: 4),
            skyGroundHintLabel.leadingAnchor.constraint(equalTo: maskCard.container.leadingAnchor),
            skyGroundHintLabel.trailingAnchor.constraint(equalTo: maskCard.container.trailingAnchor),

            analyzeNightscapeButton.leadingAnchor.constraint(equalTo: maskCard.container.leadingAnchor),
            analyzeNightscapeButton.trailingAnchor.constraint(equalTo: maskCard.container.trailingAnchor),
            brushModeSegmented.topAnchor.constraint(equalTo: analyzeNightscapeButton.bottomAnchor, constant: 6),
            brushModeSegmented.leadingAnchor.constraint(equalTo: maskCard.container.leadingAnchor),
            brushModeSegmented.trailingAnchor.constraint(equalTo: maskCard.container.trailingAnchor),

            sizeTitle.leadingAnchor.constraint(equalTo: maskCard.container.leadingAnchor),
            sizeTitle.centerYAnchor.constraint(equalTo: brushSizeSlider.centerYAnchor),
            sizeTitle.widthAnchor.constraint(equalToConstant: 42),

            brushSizeSlider.topAnchor.constraint(equalTo: brushModeSegmented.bottomAnchor, constant: 6),
            brushSizeSlider.leadingAnchor.constraint(equalTo: sizeTitle.trailingAnchor, constant: 2),
            brushSizeSlider.trailingAnchor.constraint(equalTo: brushSizeLabel.leadingAnchor, constant: -4),

            brushSizeLabel.trailingAnchor.constraint(equalTo: maskCard.container.trailingAnchor),
            brushSizeLabel.centerYAnchor.constraint(equalTo: brushSizeSlider.centerYAnchor),
            brushSizeLabel.widthAnchor.constraint(equalToConstant: 38),

            featherTitle.leadingAnchor.constraint(equalTo: maskCard.container.leadingAnchor),
            featherTitle.centerYAnchor.constraint(equalTo: maskFeatherSlider.centerYAnchor),
            featherTitle.widthAnchor.constraint(equalToConstant: 64),

            maskFeatherSlider.topAnchor.constraint(equalTo: brushSizeSlider.bottomAnchor, constant: 6),
            maskFeatherSlider.leadingAnchor.constraint(equalTo: featherTitle.trailingAnchor, constant: 2),
            maskFeatherSlider.trailingAnchor.constraint(equalTo: maskFeatherLabel.leadingAnchor, constant: -4),

            maskFeatherLabel.trailingAnchor.constraint(equalTo: maskCard.container.trailingAnchor),
            maskFeatherLabel.centerYAnchor.constraint(equalTo: maskFeatherSlider.centerYAnchor),
            maskFeatherLabel.widthAnchor.constraint(equalToConstant: 38),

            clearMaskButton.topAnchor.constraint(equalTo: maskFeatherSlider.bottomAnchor, constant: 6),
            clearMaskButton.leadingAnchor.constraint(equalTo: maskCard.container.leadingAnchor),
            clearMaskButton.trailingAnchor.constraint(equalTo: maskCard.container.trailingAnchor),
            clearMaskButton.bottomAnchor.constraint(equalTo: maskCard.container.bottomAnchor),
        ])

        let buttonSpacing = analyzeNightscapeButton.topAnchor.constraint(equalTo: skyGroundHintLabel.bottomAnchor, constant: 6)
        let buttonHeight = analyzeNightscapeButton.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([buttonSpacing, buttonHeight])
        analyzeNightscapeButtonSpacing = buttonSpacing
        analyzeNightscapeButtonHeight = buttonHeight

        // カード3: レンズプロファイル & カメラ
        let lensCard = SectionCardView(title: "レンズプロファイル")
        lensInfoCameraLabel.translatesAutoresizingMaskIntoConstraints = false
        lensInfoCameraLabel.font = NSFont.boldSystemFont(ofSize: 11)
        lensInfoCameraLabel.lineBreakMode = .byTruncatingTail

        lensInfoLensLabel.translatesAutoresizingMaskIntoConstraints = false
        lensInfoLensLabel.font = NSFont.systemFont(ofSize: 11)
        lensInfoLensLabel.textColor = NSColor(calibratedRed: 0.3, green: 0.7, blue: 1.0, alpha: 1.0)
        lensInfoLensLabel.lineBreakMode = .byTruncatingTail

        lensInfoParamsLabel.translatesAutoresizingMaskIntoConstraints = false
        lensInfoParamsLabel.font = NSFont.systemFont(ofSize: 10)
        lensInfoParamsLabel.textColor = .secondaryLabelColor

        embedLensCheckbox.translatesAutoresizingMaskIntoConstraints = false
        embedLensCheckbox.state = StackingStateController.shared.embedLensProfile ? .on : .off
        embedLensCheckbox.target = self
        embedLensCheckbox.action = #selector(onEmbedLensToggled)

        lensHintLabel.translatesAutoresizingMaskIntoConstraints = false
        lensHintLabel.font = NSFont.systemFont(ofSize: 9)
        lensHintLabel.textColor = .secondaryLabelColor

        customLensField.translatesAutoresizingMaskIntoConstraints = false
        customLensField.placeholderString = "手動レンズ名 (例: FE 20mm F1.8 G)"
        customLensField.font = NSFont.systemFont(ofSize: 10)
        customLensField.target = self
        customLensField.action = #selector(onCustomLensChanged)

        // 補足説明はチェックボックスの文字の位置にそろえて字下げする
        let lensHintRow = NSView()
        lensHintRow.translatesAutoresizingMaskIntoConstraints = false
        lensHintRow.addSubview(lensHintLabel)
        NSLayoutConstraint.activate([
            lensHintLabel.topAnchor.constraint(equalTo: lensHintRow.topAnchor),
            lensHintLabel.bottomAnchor.constraint(equalTo: lensHintRow.bottomAnchor),
            lensHintLabel.leadingAnchor.constraint(equalTo: lensHintRow.leadingAnchor, constant: 18),
            lensHintLabel.trailingAnchor.constraint(equalTo: lensHintRow.trailingAnchor),
        ])
        // 基準画像が未設定のときはレンズ名・撮影条件の行が空になるため、非表示にして詰める
        let lensRows = makeRowStack(
            [lensInfoCameraLabel, lensInfoLensLabel, lensInfoParamsLabel, embedLensCheckbox, lensHintRow, customLensField],
            spacings: [2, 2, 8, 2, 6]
        )
        pin(lensRows, to: lensCard.container)

        // カード4: 出力フォーマット & アクション
        let outCard = SectionCardView(title: "書き出し & 実行")
        formatPopup.translatesAutoresizingMaskIntoConstraints = false
        formatPopup.addItems(withTitles: ["RAW (DNG)", "16bit TIFF", "32bit FITS", "High Quality JPEG"])
        formatPopup.target = self
        formatPopup.action = #selector(onFormatChanged)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        startStackButton.translatesAutoresizingMaskIntoConstraints = false
        startStackButton.title = "★ スタッキング開始"
        startStackButton.bezelStyle = .rounded
        startStackButton.font = NSFont.boldSystemFont(ofSize: 13)
        startStackButton.target = self
        startStackButton.action = #selector(onStartStackClicked)

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.title = "結果を書き出す…"
        exportButton.bezelStyle = .rounded
        exportButton.font = NSFont.systemFont(ofSize: 12)
        exportButton.target = self
        exportButton.action = #selector(onExportClicked)

        // 処理中のメッセージが無いときはステータス行を詰める
        let outRows = makeRowStack([formatPopup, statusLabel, startStackButton, exportButton], spacings: [6, 6, 6])
        pin(outRows, to: outCard.container)
        startStackButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        // スタックコンテナへの追加
        stackViewContainer.addSubview(methodCard)
        stackViewContainer.addSubview(maskCard)
        stackViewContainer.addSubview(lensCard)
        stackViewContainer.addSubview(outCard)

        NSLayoutConstraint.activate([
            methodCard.topAnchor.constraint(equalTo: stackViewContainer.topAnchor),
            methodCard.leadingAnchor.constraint(equalTo: stackViewContainer.leadingAnchor),
            methodCard.trailingAnchor.constraint(equalTo: stackViewContainer.trailingAnchor),

            maskCard.topAnchor.constraint(equalTo: methodCard.bottomAnchor, constant: 10),
            maskCard.leadingAnchor.constraint(equalTo: stackViewContainer.leadingAnchor),
            maskCard.trailingAnchor.constraint(equalTo: stackViewContainer.trailingAnchor),

            lensCard.topAnchor.constraint(equalTo: maskCard.bottomAnchor, constant: 10),
            lensCard.leadingAnchor.constraint(equalTo: stackViewContainer.leadingAnchor),
            lensCard.trailingAnchor.constraint(equalTo: stackViewContainer.trailingAnchor),

            outCard.topAnchor.constraint(equalTo: lensCard.bottomAnchor, constant: 10),
            outCard.leadingAnchor.constraint(equalTo: stackViewContainer.leadingAnchor),
            outCard.trailingAnchor.constraint(equalTo: stackViewContainer.trailingAnchor),
            outCard.bottomAnchor.constraint(equalTo: stackViewContainer.bottomAnchor),
        ])
    }

    // MARK: - タイムラプスタブ UI 構築

    private func buildTimelapseTabUI() {
        // カード1: フレーム範囲
        let rangeCard = SectionCardView(title: "フレーム範囲")
        let startLabel = NSTextField(labelWithString: "開始フレーム:")
        startLabel.translatesAutoresizingMaskIntoConstraints = false
        startLabel.font = NSFont.systemFont(ofSize: 10)
        startLabel.textColor = .secondaryLabelColor

        startFrameSlider.translatesAutoresizingMaskIntoConstraints = false
        startFrameSlider.minValue = 0
        startFrameSlider.maxValue = 100
        startFrameSlider.target = self
        startFrameSlider.action = #selector(onTimelapseRangeChanged)

        let endLabel = NSTextField(labelWithString: "終了フレーム:")
        endLabel.translatesAutoresizingMaskIntoConstraints = false
        endLabel.font = NSFont.systemFont(ofSize: 10)
        endLabel.textColor = .secondaryLabelColor

        endFrameSlider.translatesAutoresizingMaskIntoConstraints = false
        endFrameSlider.minValue = 0
        endFrameSlider.maxValue = 100
        endFrameSlider.target = self
        endFrameSlider.action = #selector(onTimelapseRangeChanged)

        frameRangeLabel.translatesAutoresizingMaskIntoConstraints = false
        frameRangeLabel.font = NSFont.systemFont(ofSize: 10)
        frameRangeLabel.textColor = .secondaryLabelColor

        rangeCard.container.addSubview(startLabel)
        rangeCard.container.addSubview(startFrameSlider)
        rangeCard.container.addSubview(endLabel)
        rangeCard.container.addSubview(endFrameSlider)
        rangeCard.container.addSubview(frameRangeLabel)

        NSLayoutConstraint.activate([
            startLabel.topAnchor.constraint(equalTo: rangeCard.container.topAnchor),
            startLabel.leadingAnchor.constraint(equalTo: rangeCard.container.leadingAnchor),

            startFrameSlider.topAnchor.constraint(equalTo: startLabel.bottomAnchor, constant: 2),
            startFrameSlider.leadingAnchor.constraint(equalTo: rangeCard.container.leadingAnchor),
            startFrameSlider.trailingAnchor.constraint(equalTo: rangeCard.container.trailingAnchor),

            endLabel.topAnchor.constraint(equalTo: startFrameSlider.bottomAnchor, constant: 6),
            endLabel.leadingAnchor.constraint(equalTo: rangeCard.container.leadingAnchor),

            endFrameSlider.topAnchor.constraint(equalTo: endLabel.bottomAnchor, constant: 2),
            endFrameSlider.leadingAnchor.constraint(equalTo: rangeCard.container.leadingAnchor),
            endFrameSlider.trailingAnchor.constraint(equalTo: rangeCard.container.trailingAnchor),

            frameRangeLabel.topAnchor.constraint(equalTo: endFrameSlider.bottomAnchor, constant: 4),
            frameRangeLabel.leadingAnchor.constraint(equalTo: rangeCard.container.leadingAnchor),
            frameRangeLabel.trailingAnchor.constraint(equalTo: rangeCard.container.trailingAnchor),
            frameRangeLabel.bottomAnchor.constraint(equalTo: rangeCard.container.bottomAnchor),
        ])

        // カード2: 再生速度
        let speedCard = SectionCardView(title: "再生速度")
        durationModeSegmented.translatesAutoresizingMaskIntoConstraints = false
        durationModeSegmented.segmentCount = 2
        durationModeSegmented.setLabel("FPS指定", forSegment: 0)
        durationModeSegmented.setLabel("秒数指定", forSegment: 1)
        durationModeSegmented.selectedSegment = 0
        durationModeSegmented.target = self
        durationModeSegmented.action = #selector(onTimelapseDurationModeChanged)

        fpsSlider.translatesAutoresizingMaskIntoConstraints = false
        fpsSlider.target = self
        fpsSlider.action = #selector(onPlaybackSpeedChanged)

        speedField.translatesAutoresizingMaskIntoConstraints = false
        speedField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedField.alignment = .right
        let speedFormatter = NumberFormatter()
        speedFormatter.numberStyle = .decimal
        speedFormatter.usesGroupingSeparator = false
        speedFormatter.maximumFractionDigits = 2
        speedField.formatter = speedFormatter
        speedField.target = self
        speedField.action = #selector(onSpeedFieldEntered)
        speedField.toolTip = "数値を入力して Return で確定します"

        speedUnitLabel.translatesAutoresizingMaskIntoConstraints = false
        speedUnitLabel.font = NSFont.systemFont(ofSize: 10)
        speedUnitLabel.textColor = .secondaryLabelColor

        speedCard.container.addSubview(durationModeSegmented)
        speedCard.container.addSubview(fpsSlider)
        speedCard.container.addSubview(speedField)
        speedCard.container.addSubview(speedUnitLabel)

        NSLayoutConstraint.activate([
            durationModeSegmented.topAnchor.constraint(equalTo: speedCard.container.topAnchor),
            durationModeSegmented.leadingAnchor.constraint(equalTo: speedCard.container.leadingAnchor),
            durationModeSegmented.trailingAnchor.constraint(equalTo: speedCard.container.trailingAnchor),

            fpsSlider.topAnchor.constraint(equalTo: durationModeSegmented.bottomAnchor, constant: 8),
            fpsSlider.leadingAnchor.constraint(equalTo: speedCard.container.leadingAnchor),
            fpsSlider.trailingAnchor.constraint(equalTo: speedField.leadingAnchor, constant: -6),

            speedField.trailingAnchor.constraint(equalTo: speedUnitLabel.leadingAnchor, constant: -3),
            speedField.centerYAnchor.constraint(equalTo: fpsSlider.centerYAnchor),
            speedField.widthAnchor.constraint(equalToConstant: 52),

            speedUnitLabel.trailingAnchor.constraint(equalTo: speedCard.container.trailingAnchor),
            speedUnitLabel.centerYAnchor.constraint(equalTo: fpsSlider.centerYAnchor),
            speedUnitLabel.widthAnchor.constraint(equalToConstant: 22),
            fpsSlider.bottomAnchor.constraint(equalTo: speedCard.container.bottomAnchor),
        ])

        // カード3: 補正 & 画質
        let procCard = SectionCardView(title: "補正 & 画質")
        // 位置合わせ（なし / 地上に合わせる / 星に合わせる）
        let alignTitle = NSTextField(labelWithString: "位置合わせ:")
        alignTitle.translatesAutoresizingMaskIntoConstraints = false
        alignTitle.font = NSFont.systemFont(ofSize: 11)
        timelapseAlignPopup.translatesAutoresizingMaskIntoConstraints = false
        timelapseAlignPopup.addItems(withTitles: TimelapseSettings.FrameAlignment.allCases.map(\.rawValue))
        timelapseAlignPopup.toolTip = "地上に合わせる: 手ぶれ・追尾で動く地上を止めます（星は動きます）\n星に合わせる: 星空を止めます（地上が回ります）"
        timelapseAlignPopup.target = self
        timelapseAlignPopup.action = #selector(onTimelapseSettingChanged)
        let alignRow = NSView()
        alignRow.translatesAutoresizingMaskIntoConstraints = false
        alignRow.addSubview(alignTitle)
        alignRow.addSubview(timelapseAlignPopup)
        NSLayoutConstraint.activate([
            alignTitle.leadingAnchor.constraint(equalTo: alignRow.leadingAnchor),
            alignTitle.centerYAnchor.constraint(equalTo: timelapseAlignPopup.centerYAnchor),
            timelapseAlignPopup.topAnchor.constraint(equalTo: alignRow.topAnchor),
            timelapseAlignPopup.bottomAnchor.constraint(equalTo: alignRow.bottomAnchor),
            timelapseAlignPopup.leadingAnchor.constraint(equalTo: alignTitle.trailingAnchor, constant: 4),
            timelapseAlignPopup.trailingAnchor.constraint(equalTo: alignRow.trailingAnchor),
        ])
        alignTitle.setContentCompressionResistancePriority(.required, for: .horizontal)

        deflickerCheckbox.translatesAutoresizingMaskIntoConstraints = false
        deflickerCheckbox.target = self
        deflickerCheckbox.action = #selector(onTimelapseSettingChanged)

        autoStretchTimelapseCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoStretchTimelapseCheckbox.target = self
        autoStretchTimelapseCheckbox.action = #selector(onTimelapseSettingChanged)

        resolutionPopup.translatesAutoresizingMaskIntoConstraints = false
        resolutionPopup.addItems(withTitles: ["オリジナル", "4K (3840×2160)", "1080p (1920×1080)", "720p (1280×720)"])
        resolutionPopup.target = self
        resolutionPopup.action = #selector(onTimelapseSettingChanged)

        codecPopup.translatesAutoresizingMaskIntoConstraints = false
        codecPopup.addItems(withTitles: ["H.264 (.mp4)", "H.265/HEVC (.mp4)"])
        codecPopup.target = self
        codecPopup.action = #selector(onTimelapseSettingChanged)

        procCard.container.addSubview(alignRow)
        procCard.container.addSubview(deflickerCheckbox)
        procCard.container.addSubview(autoStretchTimelapseCheckbox)
        procCard.container.addSubview(resolutionPopup)
        procCard.container.addSubview(codecPopup)

        NSLayoutConstraint.activate([
            alignRow.topAnchor.constraint(equalTo: procCard.container.topAnchor),
            alignRow.leadingAnchor.constraint(equalTo: procCard.container.leadingAnchor),
            alignRow.trailingAnchor.constraint(equalTo: procCard.container.trailingAnchor),

            deflickerCheckbox.topAnchor.constraint(equalTo: alignRow.bottomAnchor, constant: 8),
            deflickerCheckbox.leadingAnchor.constraint(equalTo: procCard.container.leadingAnchor),
            deflickerCheckbox.trailingAnchor.constraint(equalTo: procCard.container.trailingAnchor),

            autoStretchTimelapseCheckbox.topAnchor.constraint(equalTo: deflickerCheckbox.bottomAnchor, constant: 6),
            autoStretchTimelapseCheckbox.leadingAnchor.constraint(equalTo: procCard.container.leadingAnchor),
            autoStretchTimelapseCheckbox.trailingAnchor.constraint(equalTo: procCard.container.trailingAnchor),

            resolutionPopup.topAnchor.constraint(equalTo: autoStretchTimelapseCheckbox.bottomAnchor, constant: 8),
            resolutionPopup.leadingAnchor.constraint(equalTo: procCard.container.leadingAnchor),
            resolutionPopup.trailingAnchor.constraint(equalTo: procCard.container.trailingAnchor),

            codecPopup.topAnchor.constraint(equalTo: resolutionPopup.bottomAnchor, constant: 6),
            codecPopup.leadingAnchor.constraint(equalTo: procCard.container.leadingAnchor),
            codecPopup.trailingAnchor.constraint(equalTo: procCard.container.trailingAnchor),
            codecPopup.bottomAnchor.constraint(equalTo: procCard.container.bottomAnchor),
        ])

        // カード4: アクション
        let actionCard = SectionCardView(title: "書き出し")
        timelapseStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        timelapseStatusLabel.font = NSFont.systemFont(ofSize: 10)
        timelapseStatusLabel.textColor = .secondaryLabelColor
        timelapseStatusLabel.alignment = .center

        startTimelapseButton.translatesAutoresizingMaskIntoConstraints = false
        startTimelapseButton.title = "タイムラプス書き出し"
        startTimelapseButton.bezelStyle = .rounded
        startTimelapseButton.font = NSFont.boldSystemFont(ofSize: 12)
        startTimelapseButton.target = self
        startTimelapseButton.action = #selector(onStartTimelapseClicked)

        let actionRows = makeRowStack([timelapseStatusLabel, startTimelapseButton], spacings: [6])
        pin(actionRows, to: actionCard.container)
        startTimelapseButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        // タイムラプスコンテナへの追加
        timelapseViewContainer.addSubview(rangeCard)
        timelapseViewContainer.addSubview(speedCard)
        timelapseViewContainer.addSubview(procCard)
        timelapseViewContainer.addSubview(actionCard)

        NSLayoutConstraint.activate([
            rangeCard.topAnchor.constraint(equalTo: timelapseViewContainer.topAnchor),
            rangeCard.leadingAnchor.constraint(equalTo: timelapseViewContainer.leadingAnchor),
            rangeCard.trailingAnchor.constraint(equalTo: timelapseViewContainer.trailingAnchor),

            speedCard.topAnchor.constraint(equalTo: rangeCard.bottomAnchor, constant: 10),
            speedCard.leadingAnchor.constraint(equalTo: timelapseViewContainer.leadingAnchor),
            speedCard.trailingAnchor.constraint(equalTo: timelapseViewContainer.trailingAnchor),

            procCard.topAnchor.constraint(equalTo: speedCard.bottomAnchor, constant: 10),
            procCard.leadingAnchor.constraint(equalTo: timelapseViewContainer.leadingAnchor),
            procCard.trailingAnchor.constraint(equalTo: timelapseViewContainer.trailingAnchor),

            actionCard.topAnchor.constraint(equalTo: procCard.bottomAnchor, constant: 10),
            actionCard.leadingAnchor.constraint(equalTo: timelapseViewContainer.leadingAnchor),
            actionCard.trailingAnchor.constraint(equalTo: timelapseViewContainer.trailingAnchor),
            actionCard.bottomAnchor.constraint(equalTo: timelapseViewContainer.bottomAnchor),
        ])
    }

    /// 行を縦に並べるスタックビュー。非表示にした行は場所を取らない（余白が残らない）。
    /// spacings[i] は rows[i] と次の行の間隔。
    private func makeRowStack(_ rows: [NSView], spacings: [CGFloat]) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (row, spacing) in zip(rows, spacings) {
            stack.setCustomSpacing(spacing, after: row)
        }
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func pin(_ view: NSView, to container: NSView) {
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - UI更新

    public func updateUI() {
        let state = StackingStateController.shared
        let lightCount = state.count(for: .light)

        // レンズ情報更新
        if let meta = state.baseImageMetadata {
            lensInfoCameraLabel.stringValue = "\(meta.cameraMake) \(meta.cameraModel)"
            lensInfoLensLabel.stringValue = meta.lensModel.isEmpty ? "レンズ: (自動検出待ち / 不明)" : meta.lensModel

            var params: [String] = []
            if let fl = meta.focalLength { params.append("\(Int(round(fl)))mm") }
            if let fn = meta.fNumber { params.append(String(format: "f/%.1f", fn)) }
            if let iso = meta.iso { params.append("ISO \(iso)") }
            if let exp = meta.exposureTime { params.append(exp < 1.0 ? "1/\(Int(round(1.0/exp)))s" : "\(String(format: "%.1f", exp))s") }
            lensInfoParamsLabel.stringValue = params.joined(separator: ", ")
        } else {
            lensInfoCameraLabel.stringValue = "基準画像（Base）を設定してください"
            lensInfoLensLabel.stringValue = ""
            lensInfoParamsLabel.stringValue = ""
        }
        lensInfoLensLabel.isHidden = lensInfoLensLabel.stringValue.isEmpty
        lensInfoParamsLabel.isHidden = lensInfoParamsLabel.stringValue.isEmpty

        // 状態側の値をポップアップ・入力欄へ反映する（「すべてクリア」後も表示が食い違わないように）。
        let stackModeIndex: Int
        switch state.stackMode {
        case "Median":         stackModeIndex = 1
        case "Compare Bright": stackModeIndex = 2
        default:               stackModeIndex = 0
        }
        if stackModePopup.indexOfSelectedItem != stackModeIndex {
            stackModePopup.selectItem(at: stackModeIndex)
        }
        let formatIndex = ImageExporter.ExportFormat.allCases.firstIndex(of: state.exportFormat) ?? 0
        if formatPopup.indexOfSelectedItem != formatIndex {
            formatPopup.selectItem(at: formatIndex)
        }
        embedLensCheckbox.state = state.embedLensProfile ? .on : .off
        // 入力中の文字列を通知のたびに巻き戻さないよう、編集中でないときだけ同期する。
        if customLensField.currentEditor() == nil, customLensField.stringValue != state.customLensModel {
            customLensField.stringValue = state.customLensModel
        }

        // レンズプロファイル設定の有効・無効化（RAW/DNG専用）
        let isDNG = (state.exportFormat == .dng)
        embedLensCheckbox.isEnabled = isDNG
        embedLensCheckbox.title = isDNG ? "DNGにレンズプロファイルを埋め込む" : "レンズプロファイル埋め込み (DNG専用)"
        customLensField.isEnabled = isDNG && state.embedLensProfile
        if isDNG {
            lensHintLabel.stringValue = "Lightroom等で開いた際にレンズ補正が自動適用されます"
            lensHintLabel.textColor = .secondaryLabelColor
        } else {
            lensHintLabel.stringValue = "※ レンズプロファイル埋め込みは RAW (DNG) 出力時のみ有効です"
            lensHintLabel.textColor = NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)
        }

        // スタック設定・光跡除去更新
        let isCompareBright = (state.stackMode == "Compare Bright")
        // 比較明合成でも選べる（星を合わせると星の軌跡が点になるため、比較明合成の既定はOFF）
        // 新星景モードでは、空は星に・地上は地上に必ず位置合わせする
        let nightscape = state.isNightscapeActive
        alignCheckbox.state = (nightscape || state.isAlignmentEnabledForCurrentMode) ? .on : .off
        alignCheckbox.isEnabled = !nightscape
        alignCheckbox.toolTip = nightscape
            ? "新星景モードでは、空は星に、地上は地上に合わせて合成します"
            : (isCompareBright
                ? "ONにすると星の位置を合わせて合成します（星は軌跡ではなく点になります）"
                : "星の位置を合わせて合成します")
        trailRemovalCheckbox.isHidden = !isCompareBright
        trailRemovalCheckbox.state = state.enableTrailRemoval ? .on : .off

        analyzeTrailsButton.isHidden = !isCompareBright || !state.enableTrailRemoval
        analyzeTrailsButton.isEnabled = !state.isAnalyzingTrails && lightCount >= 3
        analyzeTrailsButton.title = state.isAnalyzingTrails ? "解析中 (\(Int(state.trailAnalysisProgress * 100))%)..." : "🔍 光跡を解析して確認…"

        trailStatusBadge.stringValue = state.trailAnalysisStatus
        trailStatusBadge.isHidden = !isCompareBright || !state.enableTrailRemoval || state.trailAnalysisStatus.isEmpty

        // マスクOFF時は、ブラシに関係する操作とキャンバス処理を完全に無効化する。
        skyGroundMaskCheckbox.state = state.enableSkyGroundMask ? .on : .off
        skyGroundMaskCheckbox.title = isCompareBright
            ? "空と地上を分けて合成（ブラシを使用）"
            : "新星景モード（空と地上を自動で分けて合成）"
        skyGroundMaskCheckbox.toolTip = isCompareBright
            ? "塗ったマスクで、空は比較明、地上は平均で合成します"
            : "空は星に、地上は地上に合わせて合成し、空と地上の境界は自動で判定します"
        if isCompareBright {
            skyGroundHintLabel.stringValue = "地上を緑、空を青のブラシで塗ってください。"
        } else if state.enableSkyGroundMask && !state.nightscapeAnalysisStatus.isEmpty {
            skyGroundHintLabel.stringValue = state.nightscapeAnalysisStatus
        } else {
            skyGroundHintLabel.stringValue = "「解析開始」を押すと、全フレームを解析して空と地上を自動で塗り分けます。違う所はブラシで直してからスタッキングを開始してください。"
        }
        skyGroundHintLabel.isEnabled = state.enableSkyGroundMask
        // 解析開始ボタン（新星景モードのときだけ表示）
        let showsAnalyzeButton = !isCompareBright
        analyzeNightscapeButton.isHidden = !showsAnalyzeButton
        analyzeNightscapeButtonHeight?.constant = showsAnalyzeButton ? 24 : 0
        analyzeNightscapeButtonSpacing?.constant = showsAnalyzeButton ? 6 : 0
        analyzeNightscapeButton.title = state.isAnalyzingNightscape
            ? "解析中 (\(Int(state.nightscapeAnalysisProgress * 100))%)..."
            : "解析開始"
        analyzeNightscapeButton.isEnabled = state.isNightscapeActive && !state.isAnalyzingNightscape && !state.isStacking
            && lightCount >= 2 && state.baseImage != nil
        switch state.brushMode {
        case .sky: brushModeSegmented.selectedSegment = 0
        case .ground: brushModeSegmented.selectedSegment = 1
        case .erase: brushModeSegmented.selectedSegment = 2
        }
        brushSizeSlider.doubleValue = Double(state.brushSize)
        brushSizeLabel.stringValue = "\(Int(round(state.brushSize))) px"
        brushModeSegmented.isEnabled = state.enableSkyGroundMask
        brushSizeSlider.isEnabled = state.enableSkyGroundMask
        brushSizeLabel.isEnabled = state.enableSkyGroundMask
        // 境界ぼかしは新星景モードと比較明で別々に持つ（新星景モードは境界を自動でなじませるため既定 0 px）
        maskFeatherSlider.isEnabled = state.enableSkyGroundMask
        maskFeatherLabel.isEnabled = state.enableSkyGroundMask
        maskFeatherSlider.toolTip = nightscape
            ? "自動で判定した境界を、さらにぼかして空と地上をなじませます（0 pxなら画像の輪郭に沿った自動の境界のまま）"
            : "空と地上の境界を合成時に滑らかにします（0 pxで無効）"
        maskFeatherSlider.doubleValue = Double(state.featherRadiusForCurrentMode)
        maskFeatherLabel.stringValue = "\(Int(round(state.featherRadiusForCurrentMode))) px"
        clearMaskButton.isEnabled = state.enableSkyGroundMask && state.maskBitmap != nil

        // ボタンの有効化
        startStackButton.isEnabled = !state.isStacking && !state.isAnalyzingTrails && lightCount > 0 && state.baseImage != nil
        exportButton.isEnabled = state.stackedResult != nil
        statusLabel.stringValue = state.stackingStatus
        statusLabel.isHidden = state.stackingStatus.isEmpty

        // タイムラプス更新
        let maxFrames = max(1, lightCount)
        startFrameSlider.maxValue = Double(maxFrames - 1)
        endFrameSlider.maxValue = Double(maxFrames - 1)
        startFrameSlider.doubleValue = Double(min(state.timelapseSettings.startFrame, maxFrames - 1))
        endFrameSlider.doubleValue = Double(min(state.timelapseSettings.endFrame, maxFrames - 1))
        durationModeSegmented.selectedSegment = state.timelapseSettings.durationMode == .fps ? 0 : 1
        if let alignIndex = TimelapseSettings.FrameAlignment.allCases.firstIndex(of: state.timelapseSettings.alignment),
           timelapseAlignPopup.indexOfSelectedItem != alignIndex {
            timelapseAlignPopup.selectItem(at: alignIndex)
        }
        deflickerCheckbox.state = state.timelapseSettings.deflicker ? .on : .off
        autoStretchTimelapseCheckbox.state = state.timelapseSettings.autoStretch ? .on : .off
        let resolutionIndex: Int
        switch state.timelapseSettings.resolution {
        case .original: resolutionIndex = 0
        case .r4k:      resolutionIndex = 1
        case .r1080p:   resolutionIndex = 2
        case .r720p:    resolutionIndex = 3
        }
        if resolutionPopup.indexOfSelectedItem != resolutionIndex {
            resolutionPopup.selectItem(at: resolutionIndex)
        }
        let codecIndex = state.timelapseSettings.codec == .hevc ? 1 : 0
        if codecPopup.indexOfSelectedItem != codecIndex {
            codecPopup.selectItem(at: codecIndex)
        }
        if state.timelapseSettings.durationMode == .fps {
            fpsSlider.minValue = 1
            fpsSlider.maxValue = 120
            fpsSlider.doubleValue = state.timelapseSettings.effectiveFps
            showSpeed(state.timelapseSettings.effectiveFps, unit: "fps")
        } else {
            let minimumDuration = max(1.0, ceil(Double(state.timelapseSettings.effectiveFrameCount) / 120.0))
            fpsSlider.minValue = minimumDuration
            fpsSlider.maxValue = max(600, minimumDuration)
            fpsSlider.doubleValue = max(minimumDuration, state.timelapseSettings.targetDuration)
            showSpeed(fpsSlider.doubleValue, unit: "秒")
        }
        frameRangeLabel.stringValue = "フレーム数: \(state.timelapseSettings.effectiveFrameCount) / 推定: \(String(format: "%.1f", state.timelapseSettings.estimatedDuration))秒"
        startTimelapseButton.isEnabled = !state.isExportingTimelapse && lightCount > 0
        timelapseStatusLabel.stringValue = state.timelapseStatus
        timelapseStatusLabel.isHidden = state.timelapseStatus.isEmpty
    }

    // MARK: - 光跡レビューシート表示

    private func presentTrailReview(items: [DetectedTrailItem]) {
        guard !items.isEmpty else { return }
        let reviewVC = TrailReviewViewController(items: items)
        guard let hostWindow = view.window else {
            presentAsSheet(reviewVC)
            return
        }
        let reviewWindow = reviewVC.makeReviewWindow()
        reviewVC.onDismissRequested = { [weak hostWindow, weak reviewWindow] in
            guard let reviewWindow else { return }
            hostWindow?.ignoresMouseEvents = false
            hostWindow?.removeChildWindow(reviewWindow)
            reviewWindow.orderOut(nil)
            reviewWindow.close()
        }
        reviewVC.onConfirmed = { confirmedItems in
            StackingStateController.shared.detectedTrails = confirmedItems
            StackingStateController.shared.startStacking(forceDirectExecution: true)
        }
        hostWindow.addChildWindow(reviewWindow, ordered: .above)
        let hostFrame = hostWindow.frame
        let reviewFrame = reviewWindow.frame
        reviewWindow.setFrameOrigin(NSPoint(
            x: hostFrame.midX - reviewFrame.width / 2,
            y: hostFrame.midY - reviewFrame.height / 2
        ))
        hostWindow.ignoresMouseEvents = true
        reviewWindow.makeKeyAndOrderFront(nil)
    }

    // MARK: - アクション

    @objc private func onTabChanged() {
        let isStack = tabSegmentedControl.selectedSegment == 0
        stackViewContainer.isHidden = !isStack
        timelapseViewContainer.isHidden = isStack
        stackBottomConstraint.isActive = isStack
        timelapseBottomConstraint.isActive = !isStack
    }

    @objc private func onStackModeChanged() {
        switch stackModePopup.indexOfSelectedItem {
        case 0: StackingStateController.shared.stackMode = "Average"
        case 1: StackingStateController.shared.stackMode = "Median"
        case 2:
            StackingStateController.shared.stackMode = "Compare Bright"
        default: StackingStateController.shared.stackMode = "Average"
        }
    }

    @objc private func onAlignToggled() {
        StackingStateController.shared.isAlignmentEnabledForCurrentMode = (alignCheckbox.state == .on)
    }

    @objc private func onTrailRemovalToggled() {
        StackingStateController.shared.enableTrailRemoval = (trailRemovalCheckbox.state == .on)
    }

    @objc private func onAnalyzeTrailsClicked() {
        StackingStateController.shared.analyzeTrails()
    }

    @objc private func onAnalyzeNightscapeClicked() {
        StackingStateController.shared.analyzeNightscape()
    }

    @objc private func onSkyGroundMaskToggled() {
        StackingStateController.shared.enableSkyGroundMask = (skyGroundMaskCheckbox.state == .on)
    }

    @objc private func onBrushModeChanged() {
        switch brushModeSegmented.selectedSegment {
        case 0: StackingStateController.shared.brushMode = .sky
        case 1: StackingStateController.shared.brushMode = .ground
        case 2: StackingStateController.shared.brushMode = .erase
        default: StackingStateController.shared.brushMode = .sky
        }
    }

    @objc private func onBrushSizeChanged() {
        StackingStateController.shared.brushSize = CGFloat(brushSizeSlider.doubleValue)
        brushSizeLabel.stringValue = "\(Int(brushSizeSlider.doubleValue)) px"
    }

    @objc private func onMaskFeatherChanged() {
        let radius = CGFloat(maskFeatherSlider.doubleValue.rounded())
        StackingStateController.shared.featherRadiusForCurrentMode = radius
        maskFeatherLabel.stringValue = "\(Int(radius)) px"
    }

    @objc private func onClearMaskClicked() {
        StackingStateController.shared.maskBitmap = nil
    }

    @objc private func onEmbedLensToggled() {
        StackingStateController.shared.embedLensProfile = (embedLensCheckbox.state == .on)
    }

    @objc private func onCustomLensChanged() {
        StackingStateController.shared.customLensModel = customLensField.stringValue
    }

    @objc private func onFormatChanged() {
        switch formatPopup.indexOfSelectedItem {
        case 0: StackingStateController.shared.exportFormat = .dng
        case 1: StackingStateController.shared.exportFormat = .tiff16
        case 2: StackingStateController.shared.exportFormat = .fits32
        case 3: StackingStateController.shared.exportFormat = .jpeg
        default: StackingStateController.shared.exportFormat = .dng
        }
        updateUI()
    }

    @objc private func onStartStackClicked() {
        StackingStateController.shared.showResult = false
        StackingStateController.shared.startStacking()
    }

    @objc private func onExportClicked() {
        let state = StackingStateController.shared
        if let img = state.stackedResult {
            ImageExporter.export(
                image: img,
                format: state.exportFormat,
                metadata: state.getEffectiveMetadata(),
                embedLensProfile: state.embedLensProfile,
                rawResult: state.stackedRawResult,
                completion: { result in
                    switch result {
                    case .success(let url):
                        state.stackingStatus = "✅ 書き出し完了: \(url.lastPathComponent)"
                    case .failure(let error):
                        state.stackingStatus = "❌ 書き出し失敗: \(error.localizedDescription)"
                    }
                }
            )
        }
    }

    @objc private func onTimelapseRangeChanged() {
        let state = StackingStateController.shared
        state.timelapseSettings.startFrame = Int(startFrameSlider.doubleValue)
        state.timelapseSettings.endFrame = max(state.timelapseSettings.startFrame, Int(endFrameSlider.doubleValue))
        endFrameSlider.doubleValue = Double(state.timelapseSettings.endFrame)
        updateUI()
    }

    @objc private func onTimelapseDurationModeChanged() {
        let isFps = durationModeSegmented.selectedSegment == 0
        let state = StackingStateController.shared
        state.timelapseSettings.durationMode = isFps ? .fps : .duration
        if !isFps {
            let minimumDuration = max(1.0, ceil(Double(state.timelapseSettings.effectiveFrameCount) / 120.0))
            state.timelapseSettings.targetDuration = max(minimumDuration, state.timelapseSettings.targetDuration)
        }
        updateUI()
    }

    @objc private func onPlaybackSpeedChanged() {
        let state = StackingStateController.shared
        if state.timelapseSettings.durationMode == .fps {
            // スライダーは整数に丸める（小数は入力欄から指定する）
            state.timelapseSettings.fps = fpsSlider.doubleValue.rounded()
        } else {
            state.timelapseSettings.targetDuration = fpsSlider.doubleValue.rounded()
        }
        updateUI()
    }

    /// 入力欄の値をスライダーの範囲に収めて反映する（Return または入力欄から離れたとき）
    @objc private func onSpeedFieldEntered() {
        let state = StackingStateController.shared
        let value = min(fpsSlider.maxValue, max(fpsSlider.minValue, speedField.doubleValue))
        if state.timelapseSettings.durationMode == .fps {
            state.timelapseSettings.fps = value
        } else {
            state.timelapseSettings.targetDuration = value
        }
        updateUI()
    }

    /// 入力中の値は上書きしない
    private func showSpeed(_ value: Double, unit: String) {
        speedUnitLabel.stringValue = unit
        guard speedField.currentEditor() == nil else { return }
        speedField.doubleValue = (value * 100).rounded() / 100
    }

    @objc private func onTimelapseSettingChanged() {
        var settings = StackingStateController.shared.timelapseSettings
        let alignIndex = max(0, timelapseAlignPopup.indexOfSelectedItem)
        settings.alignment = TimelapseSettings.FrameAlignment.allCases[min(alignIndex, TimelapseSettings.FrameAlignment.allCases.count - 1)]
        settings.deflicker = (deflickerCheckbox.state == .on)
        settings.autoStretch = (autoStretchTimelapseCheckbox.state == .on)
        switch resolutionPopup.indexOfSelectedItem {
        case 0: settings.resolution = .original
        case 1: settings.resolution = .r4k
        case 2: settings.resolution = .r1080p
        case 3: settings.resolution = .r720p
        default: settings.resolution = .original
        }
        switch codecPopup.indexOfSelectedItem {
        case 0: settings.codec = .h264
        case 1: settings.codec = .hevc
        default: settings.codec = .h264
        }
        StackingStateController.shared.timelapseSettings = settings
    }

    @objc private func onStartTimelapseClicked() {
        StackingStateController.shared.exportTimelapse()
    }
}
