import Cocoa

/// 検出された光跡の確認・流星保護用レビューシートコントローラ（macOS 10.12+ 互換）
public class TrailReviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private var trailItems: [DetectedTrailItem] = []
    private var selectedIndex: Int = 0
    private var previewMode: Int = 0 // 0: ハイライト, 1: 除去後, 2: 2値マスク

    private let titleLabel = NSTextField(labelWithString: "✈️ 飛行機・人工衛星の光跡確認 ＆ 流星の保護")
    private let descriptionLabel = NSTextField(labelWithString: "検出された光跡の一覧です。流星（流れ星）など残したい光跡は「除去」のチェックを外してください。")

    // 左ペイン: テーブル
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let protectMeteorsButton = NSButton()
    private let selectAllButton = NSButton()
    private let deselectAllButton = NSButton()

    // 右ペイン: プレビュー
    private let previewSegmentedControl = NSSegmentedControl()
    private let previewImageView = NSImageView()
    private let infoLabel = NSTextField(labelWithString: "")

    // 下部アクションバー
    private let cancelButton = NSButton()
    private let applyAndStackButton = NSButton()

    public var onConfirmed: (([DetectedTrailItem]) -> Void)?
    public var onCancelled: (() -> Void)?

    public init(items: [DetectedTrailItem]) {
        self.trailItems = items
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 600))
        self.view.wantsLayer = true
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateSelectionPreview()
    }

    private func setupUI() {
        view.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).cgColor

        // ── 上部ヘッダー ──
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = .white
        view.addSubview(titleLabel)

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = NSFont.systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        view.addSubview(descriptionLabel)

        // ── 左ペイン: 一括操作ボタン ──
        protectMeteorsButton.translatesAutoresizingMaskIntoConstraints = false
        protectMeteorsButton.title = "🌠 流星を自動保護 (チェック解除)"
        protectMeteorsButton.bezelStyle = .roundRect
        protectMeteorsButton.font = NSFont.systemFont(ofSize: 11)
        protectMeteorsButton.target = self
        protectMeteorsButton.action = #selector(onProtectMeteorsClicked)
        view.addSubview(protectMeteorsButton)

        selectAllButton.translatesAutoresizingMaskIntoConstraints = false
        selectAllButton.title = "全選択"
        selectAllButton.bezelStyle = .roundRect
        selectAllButton.font = NSFont.systemFont(ofSize: 11)
        selectAllButton.target = self
        selectAllButton.action = #selector(onSelectAllClicked)
        view.addSubview(selectAllButton)

        deselectAllButton.translatesAutoresizingMaskIntoConstraints = false
        deselectAllButton.title = "全解除"
        deselectAllButton.bezelStyle = .roundRect
        deselectAllButton.font = NSFont.systemFont(ofSize: 11)
        deselectAllButton.target = self
        deselectAllButton.action = #selector(onDeselectAllClicked)
        view.addSubview(deselectAllButton)

        // ── 左ペイン: テーブルビュー ──
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor(white: 0.25, alpha: 1.0).cgColor

        let colCheck = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CheckColumn"))
        colCheck.title = "除去"
        colCheck.width = 44
        tableView.addTableColumn(colCheck)

        let colInfo = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("InfoColumn"))
        colInfo.title = "検出フレーム"
        colInfo.width = 250
        tableView.addTableColumn(colInfo)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 50
        tableView.backgroundColor = NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0)
        view.addSubview(scrollView)

        // ── 右ペイン: プレビュー ──
        previewSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        previewSegmentedControl.segmentCount = 3
        previewSegmentedControl.setLabel("🔴 光跡ハイライト", forSegment: 0)
        previewSegmentedControl.setLabel("✨ 除去後プレビュー", forSegment: 1)
        previewSegmentedControl.setLabel("🔲 光跡マスク", forSegment: 2)
        previewSegmentedControl.selectedSegment = 0
        previewSegmentedControl.target = self
        previewSegmentedControl.action = #selector(onPreviewModeChanged)
        view.addSubview(previewSegmentedControl)

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 6
        previewImageView.layer?.borderWidth = 1
        previewImageView.layer?.borderColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        previewImageView.layer?.backgroundColor = NSColor.black.cgColor
        view.addSubview(previewImageView)

        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        view.addSubview(infoLabel)

        // ── 下部ボタン ──
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.title = "キャンセル"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(onCancelClicked)
        view.addSubview(cancelButton)

        applyAndStackButton.translatesAutoresizingMaskIntoConstraints = false
        applyAndStackButton.title = "確定してスタッキング開始"
        applyAndStackButton.bezelStyle = .rounded
        applyAndStackButton.keyEquivalent = "\r"
        applyAndStackButton.target = self
        applyAndStackButton.action = #selector(onApplyClicked)
        view.addSubview(applyAndStackButton)

        // ── AutoLayout ──
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            descriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // 一括操作ボタン
            protectMeteorsButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 12),
            protectMeteorsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            protectMeteorsButton.widthAnchor.constraint(equalToConstant: 190),

            selectAllButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 12),
            selectAllButton.leadingAnchor.constraint(equalTo: protectMeteorsButton.trailingAnchor, constant: 6),
            selectAllButton.widthAnchor.constraint(equalToConstant: 60),

            deselectAllButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 12),
            deselectAllButton.leadingAnchor.constraint(equalTo: selectAllButton.trailingAnchor, constant: 6),
            deselectAllButton.widthAnchor.constraint(equalToConstant: 60),

            // 左ペイン: テーブル
            scrollView.topAnchor.constraint(equalTo: protectMeteorsButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.widthAnchor.constraint(equalToConstant: 320),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -16),

            // 右ペイン: プレビュー切替
            previewSegmentedControl.topAnchor.constraint(equalTo: protectMeteorsButton.topAnchor),
            previewSegmentedControl.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 16),
            previewSegmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // 右ペイン: プレビュー画像
            previewImageView.topAnchor.constraint(equalTo: previewSegmentedControl.bottomAnchor, constant: 8),
            previewImageView.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 16),
            previewImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            previewImageView.bottomAnchor.constraint(equalTo: infoLabel.topAnchor, constant: -6),

            // 右ペイン: 情報
            infoLabel.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            infoLabel.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -16),

            // 下部ボタン
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: applyAndStackButton.leadingAnchor, constant: -12),
            cancelButton.widthAnchor.constraint(equalToConstant: 90),

            applyAndStackButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            applyAndStackButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            applyAndStackButton.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return trailItems.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < trailItems.count else { return nil }
        let item = trailItems[row]

        if tableColumn?.identifier.rawValue == "CheckColumn" {
            let check = NSButton()
            check.setButtonType(.switch)
            check.title = ""
            check.state = item.isMarkedForRemoval ? .on : .off
            check.tag = row
            check.target = self
            check.action = #selector(onCheckboxToggled(_:))
            return check
        } else {
            let cell = TrailRowCellView()
            cell.configure(item: item)
            return cell
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 && row < trailItems.count {
            selectedIndex = row
            updateSelectionPreview()
        }
    }

    // MARK: - プレビュー更新

    private func updateSelectionPreview() {
        guard selectedIndex >= 0 && selectedIndex < trailItems.count else {
            previewImageView.image = nil
            infoLabel.stringValue = ""
            return
        }

        let item = trailItems[selectedIndex]
        switch previewMode {
        case 1:
            previewImageView.image = item.repairedImage ?? item.highlightedImage
        case 2:
            previewImageView.image = item.maskImage
        default:
            previewImageView.image = item.highlightedImage
        }

        let meteorStr = item.isLikelyMeteor ? "🌠 流星の可能性: 高 (非対称バースト)" : "人工物 (飛行機/衛星/車)"
        let removalStr = item.isMarkedForRemoval ? "【 除去対象 】" : "【 保護 (残す) 】"
        infoLabel.stringValue = "フレーム #\(item.frameIndex + 1) (\(item.file.name)) | タイプ: \(item.detectedType) | 信頼度: \(Int(item.confidenceScore * 100))% | \(meteorStr) \(removalStr)"

        let removeCount = trailItems.filter { $0.isMarkedForRemoval }.count
        applyAndStackButton.title = "確定して開始 (\(removeCount)件を除去)"
    }

    // MARK: - アクション

    @objc private func onPreviewModeChanged() {
        previewMode = previewSegmentedControl.selectedSegment
        updateSelectionPreview()
    }

    @objc private func onCheckboxToggled(_ sender: NSButton) {
        let row = sender.tag
        if row >= 0 && row < trailItems.count {
            trailItems[row].isMarkedForRemoval = (sender.state == .on)
            updateSelectionPreview()
        }
    }

    @objc private func onProtectMeteorsClicked() {
        for i in 0..<trailItems.count {
            if trailItems[i].isLikelyMeteor {
                trailItems[i].isMarkedForRemoval = false
            }
        }
        tableView.reloadData()
        updateSelectionPreview()
    }

    @objc private func onSelectAllClicked() {
        for i in 0..<trailItems.count {
            trailItems[i].isMarkedForRemoval = true
        }
        tableView.reloadData()
        updateSelectionPreview()
    }

    @objc private func onDeselectAllClicked() {
        for i in 0..<trailItems.count {
            trailItems[i].isMarkedForRemoval = false
        }
        tableView.reloadData()
        updateSelectionPreview()
    }

    @objc private func onCancelClicked() {
        dismiss(self)
        onCancelled?()
    }

    @objc private func onApplyClicked() {
        dismiss(self)
        onConfirmed?(trailItems)
    }
}

// MARK: - カスタム行セルビュー
class TrailRowCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let tagLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCell()
    }

    private func setupCell() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.boldSystemFont(ofSize: 11)
        titleLabel.textColor = .white
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        addSubview(subtitleLabel)

        tagLabel.translatesAutoresizingMaskIntoConstraints = false
        tagLabel.font = NSFont.boldSystemFont(ofSize: 9)
        tagLabel.textColor = NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1.0)
        addSubview(tagLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: tagLabel.leadingAnchor, constant: -4),

            tagLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            tagLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    func configure(item: DetectedTrailItem) {
        titleLabel.stringValue = "フレーム #\(item.frameIndex + 1): \(item.file.name)"
        subtitleLabel.stringValue = item.detectedType
        tagLabel.stringValue = item.isLikelyMeteor ? "🌠 流星疑い" : "✈️ 人工光跡"
        tagLabel.textColor = item.isLikelyMeteor ? NSColor.systemGreen : NSColor.systemOrange
    }
}
