import Cocoa

/// 中央ペインのビューコントローラ（プレビュー・マスク描画・ズーム・プログレス）（macOS 10.12+ 互換）
public class CanvasViewController: NSViewController {

    public let canvasView = MaskCanvasView()

    // ── 上部ツールバーコントロール ──
    private let toolbarContainer = NSView()
    private let autoStretchCheckbox = NSButton(checkboxWithTitle: "Auto Stretch", target: nil, action: nil)
    private let toggleResultButton = NSButton()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let zoomMinusButton = NSButton()
    private let zoomPlusButton = NSButton()
    private let zoomResetButton = NSButton()
    private let zoomLabel = NSTextField(labelWithString: "100%")

    // ── 下部プログレスコントロール ──
    private let bottomContainer = NSView()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")

    override public func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1.0).cgColor

        setupUI()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()

        // 状態監視
        StackingStateController.shared.onStateChanged = { [weak self] in
            self?.updateState()
        }

        // ファイルドロップ対応
        view.registerForDraggedTypes([.fileURL])

        updateState()
    }

    private func setupUI() {
        // 1. 上部ツールバー
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.wantsLayer = true
        toolbarContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1.0).cgColor
        view.addSubview(toolbarContainer)

        autoStretchCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoStretchCheckbox.state = StackingStateController.shared.enableAutoStretch ? .on : .off
        autoStretchCheckbox.target = self
        autoStretchCheckbox.action = #selector(onAutoStretchToggled)
        toolbarContainer.addSubview(autoStretchCheckbox)

        toggleResultButton.translatesAutoresizingMaskIntoConstraints = false
        toggleResultButton.title = "スタック結果を表示"
        toggleResultButton.bezelStyle = .rounded
        toggleResultButton.target = self
        toggleResultButton.action = #selector(onToggleResultClicked)
        toggleResultButton.isHidden = true
        toolbarContainer.addSubview(toggleResultButton)

        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = NSFont.systemFont(ofSize: 11)
        fileNameLabel.textColor = .secondaryLabelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        toolbarContainer.addSubview(fileNameLabel)

        // ズームボタン
        zoomMinusButton.translatesAutoresizingMaskIntoConstraints = false
        zoomMinusButton.title = "−"
        zoomMinusButton.bezelStyle = .roundRect
        zoomMinusButton.target = self
        zoomMinusButton.action = #selector(onZoomMinusClicked)
        toolbarContainer.addSubview(zoomMinusButton)

        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.alignment = .center
        toolbarContainer.addSubview(zoomLabel)

        zoomPlusButton.translatesAutoresizingMaskIntoConstraints = false
        zoomPlusButton.title = "+"
        zoomPlusButton.bezelStyle = .roundRect
        zoomPlusButton.target = self
        zoomPlusButton.action = #selector(onZoomPlusClicked)
        toolbarContainer.addSubview(zoomPlusButton)

        zoomResetButton.translatesAutoresizingMaskIntoConstraints = false
        zoomResetButton.title = "1:1"
        zoomResetButton.bezelStyle = .roundRect
        zoomResetButton.target = self
        zoomResetButton.action = #selector(onZoomResetClicked)
        toolbarContainer.addSubview(zoomResetButton)

        // 2. キャンバス
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)

        // 3. 下部プログレスバー
        bottomContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomContainer.wantsLayer = true
        bottomContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1.0).cgColor
        bottomContainer.isHidden = true
        view.addSubview(bottomContainer)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0.0
        progressIndicator.maxValue = 1.0
        bottomContainer.addSubview(progressIndicator)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        bottomContainer.addSubview(statusLabel)

        // ── AutoLayout ──
        NSLayoutConstraint.activate([
            // Toolbar
            toolbarContainer.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarContainer.heightAnchor.constraint(equalToConstant: 36),

            autoStretchCheckbox.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor, constant: 10),
            autoStretchCheckbox.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),

            toggleResultButton.leadingAnchor.constraint(equalTo: autoStretchCheckbox.trailingAnchor, constant: 12),
            toggleResultButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),

            fileNameLabel.leadingAnchor.constraint(equalTo: toggleResultButton.trailingAnchor, constant: 10),
            fileNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomMinusButton.leadingAnchor, constant: -10),
            fileNameLabel.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),

            zoomResetButton.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor, constant: -10),
            zoomResetButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            zoomResetButton.widthAnchor.constraint(equalToConstant: 32),

            zoomPlusButton.trailingAnchor.constraint(equalTo: zoomResetButton.leadingAnchor, constant: -4),
            zoomPlusButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            zoomPlusButton.widthAnchor.constraint(equalToConstant: 24),

            zoomLabel.trailingAnchor.constraint(equalTo: zoomPlusButton.leadingAnchor, constant: -4),
            zoomLabel.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            zoomLabel.widthAnchor.constraint(equalToConstant: 40),

            zoomMinusButton.trailingAnchor.constraint(equalTo: zoomLabel.leadingAnchor, constant: -4),
            zoomMinusButton.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor),
            zoomMinusButton.widthAnchor.constraint(equalToConstant: 24),

            // Canvas
            canvasView.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bottomContainer.topAnchor),

            // Bottom Progress
            bottomContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomContainer.heightAnchor.constraint(equalToConstant: 32),

            progressIndicator.leadingAnchor.constraint(equalTo: bottomContainer.leadingAnchor, constant: 12),
            progressIndicator.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 200),

            statusLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: bottomContainer.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
        ])
    }

    public func updateState() {
        let state = StackingStateController.shared

        // プレビュー表示する画像の決定
        let displayImg: NSImage?
        if state.showResult, let result = state.stackedResult {
            displayImg = result
            fileNameLabel.stringValue = "スタック結果"
            fileNameLabel.textColor = .systemGreen
        } else if let preview = state.previewImage {
            displayImg = state.loadNSImage(from: preview)
            fileNameLabel.stringValue = preview.name
            fileNameLabel.textColor = .secondaryLabelColor
        } else if let base = state.baseImage {
            displayImg = state.loadNSImage(from: base)
            fileNameLabel.stringValue = base.name
            fileNameLabel.textColor = .secondaryLabelColor
        } else {
            displayImg = nil
            fileNameLabel.stringValue = ""
        }

        canvasView.currentImage = displayImg

        // スタック結果トグルボタンの表示
        if state.stackedResult != nil {
            toggleResultButton.isHidden = false
            toggleResultButton.title = state.showResult ? "元画像を表示" : "スタック結果を表示"
        } else {
            toggleResultButton.isHidden = true
        }

        // プログレスバー
        if state.isStacking {
            bottomContainer.isHidden = false
            progressIndicator.doubleValue = state.stackingProgress
            statusLabel.stringValue = state.stackingStatus
        } else {
            bottomContainer.isHidden = true
        }

        zoomLabel.stringValue = "\(Int(round(canvasView.zoomScale * 100)))%"
    }

    // MARK: - アクション

    @objc private func onAutoStretchToggled() {
        StackingStateController.shared.enableAutoStretch = (autoStretchCheckbox.state == .on)
    }

    @objc private func onToggleResultClicked() {
        let state = StackingStateController.shared
        state.showResult = !state.showResult
        updateState()
    }

    @objc private func onZoomPlusClicked() {
        canvasView.zoomScale = min(10.0, canvasView.zoomScale + 0.25)
        zoomLabel.stringValue = "\(Int(round(canvasView.zoomScale * 100)))%"
    }

    @objc private func onZoomMinusClicked() {
        canvasView.zoomScale = max(0.25, canvasView.zoomScale - 0.25)
        zoomLabel.stringValue = "\(Int(round(canvasView.zoomScale * 100)))%"
    }

    @objc private func onZoomResetClicked() {
        canvasView.zoomScale = 1.0
        canvasView.panOffset = .zero
        zoomLabel.stringValue = "100%"
    }
}
