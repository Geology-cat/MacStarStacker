import Cocoa

/// 左ペインのファイル一覧・管理ビューコントローラ（macOS 14+）
public class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let segmentedTypePicker = NSSegmentedControl()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "ファイルリスト")
    private let addButton = NSButton()
    private let clearButton = NSButton()
    private let baseInfoView = NSView()
    private let baseInfoLabel = NSTextField(labelWithString: "")

    private var currentType: ImageType = .light
    private var stateChangeObserver: NSObjectProtocol?

    override public func loadView() {
        let dropView = ImageDropView()
        dropView.onImageURLsDropped = { [weak self] urls in
            guard let self = self else { return }
            StackingStateController.shared.add(urls: urls, to: self.currentType)
        }
        self.view = dropView
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor

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

        updateUI()
    }

    deinit {
        if let observer = stateChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupUI() {
        // 1. タイトル
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = NSFont.boldSystemFont(ofSize: 13)
        view.addSubview(headerLabel)

        // 2. 基準画像情報バナー
        baseInfoView.translatesAutoresizingMaskIntoConstraints = false
        baseInfoView.wantsLayer = true
        baseInfoView.layer?.backgroundColor = NSColor(calibratedRed: 0.8, green: 0.7, blue: 0.2, alpha: 0.15).cgColor
        baseInfoView.layer?.cornerRadius = 4
        view.addSubview(baseInfoView)

        baseInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        baseInfoLabel.font = NSFont.systemFont(ofSize: 10)
        baseInfoLabel.textColor = .systemYellow
        baseInfoLabel.lineBreakMode = .byTruncatingMiddle
        baseInfoView.addSubview(baseInfoLabel)

        // 3. タイプ切り替えセグメント
        segmentedTypePicker.translatesAutoresizingMaskIntoConstraints = false
        segmentedTypePicker.segmentCount = 4
        segmentedTypePicker.setLabel("Light", forSegment: 0)
        segmentedTypePicker.setLabel("Dark", forSegment: 1)
        segmentedTypePicker.setLabel("Flat", forSegment: 2)
        segmentedTypePicker.setLabel("Bias", forSegment: 3)
        segmentedTypePicker.selectedSegment = 0
        segmentedTypePicker.target = self
        segmentedTypePicker.action = #selector(onTypeChanged)
        view.addSubview(segmentedTypePicker)

        // 4. 追加・削除ツールバー
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.title = "＋ 追加"
        addButton.bezelStyle = .roundRect
        addButton.font = NSFont.systemFont(ofSize: 11)
        addButton.target = self
        addButton.action = #selector(onAddClicked)
        view.addSubview(addButton)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.title = "クリア"
        clearButton.bezelStyle = .roundRect
        clearButton.font = NSFont.systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(onClearClicked)
        view.addSubview(clearButton)

        // 5. テーブルビュー
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        col.title = "ファイル"
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 44
        tableView.backgroundColor = .clear
        view.addSubview(scrollView)

        // ── AutoLayout ──
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),

            baseInfoView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            baseInfoView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            baseInfoView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            baseInfoView.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),

            baseInfoLabel.topAnchor.constraint(equalTo: baseInfoView.topAnchor, constant: 4),
            baseInfoLabel.bottomAnchor.constraint(equalTo: baseInfoView.bottomAnchor, constant: -4),
            baseInfoLabel.leadingAnchor.constraint(equalTo: baseInfoView.leadingAnchor, constant: 6),
            baseInfoLabel.trailingAnchor.constraint(equalTo: baseInfoView.trailingAnchor, constant: -6),

            segmentedTypePicker.topAnchor.constraint(equalTo: baseInfoView.bottomAnchor, constant: 8),
            segmentedTypePicker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            segmentedTypePicker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            addButton.topAnchor.constraint(equalTo: segmentedTypePicker.bottomAnchor, constant: 6),
            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            addButton.widthAnchor.constraint(equalToConstant: 70),

            clearButton.topAnchor.constraint(equalTo: segmentedTypePicker.bottomAnchor, constant: 6),
            clearButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            clearButton.widthAnchor.constraint(equalToConstant: 60),

            scrollView.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
    }

    public func updateUI() {
        let state = StackingStateController.shared

        // 基準画像情報の更新
        if let base = state.baseImage {
            var text = "★ 基準: \(base.name)"
            if let meta = state.baseImageMetadata, !meta.displayName.isEmpty {
                text += "\n\(meta.displayName)"
            }
            baseInfoLabel.stringValue = text
            baseInfoView.isHidden = false
        } else {
            baseInfoLabel.stringValue = "★ をクリックして基準画像を設定"
            baseInfoView.isHidden = false
        }

        // セグメントタイトルの更新（カウント付き）
        segmentedTypePicker.setLabel("Light (\(state.count(for: .light)))", forSegment: 0)
        segmentedTypePicker.setLabel("Dark (\(state.count(for: .dark)))", forSegment: 1)
        segmentedTypePicker.setLabel("Flat (\(state.count(for: .flat)))", forSegment: 2)
        segmentedTypePicker.setLabel("Bias (\(state.count(for: .bias)))", forSegment: 3)

        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return StackingStateController.shared.images[currentType]?.count ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let files = StackingStateController.shared.images[currentType], row < files.count else { return nil }
        let file = files[row]

        let cellIdentifier = NSUserInterfaceItemIdentifier("FileCell")
        var cell = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? FileTableCellView
        if cell == nil {
            cell = FileTableCellView()
            cell?.identifier = cellIdentifier
        }

        let isBase = StackingStateController.shared.baseImage?.id == file.id
        cell?.configure(
            file: file,
            isBase: isBase,
            onSetBase: { [weak self] in
                StackingStateController.shared.baseImage = file
                StackingStateController.shared.previewImage = file
                self?.updateUI()
            },
            onRemove: { [weak self] in
                guard let self = self else { return }
                StackingStateController.shared.remove(file: file, from: self.currentType)
            }
        )

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, let files = StackingStateController.shared.images[currentType], row < files.count else { return }
        let file = files[row]
        StackingStateController.shared.previewImage = file
        StackingStateController.shared.showResult = false
    }

    // MARK: - アクション

    @objc private func onTypeChanged() {
        switch segmentedTypePicker.selectedSegment {
        case 0: currentType = .light
        case 1: currentType = .dark
        case 2: currentType = .flat
        case 3: currentType = .bias
        default: currentType = .light
        }
        tableView.reloadData()
    }

    @objc private func onAddClicked() {
        let panel = ImageImportSupport.makeOpenPanel(title: "\(currentType.rawValue)画像を選択")
        panel.begin { [weak self] response in
            guard response == .OK, let self = self else { return }
            StackingStateController.shared.add(urls: panel.urls, to: self.currentType)
        }
    }

    @objc private func onClearClicked() {
        StackingStateController.shared.clear(type: currentType)
    }

}

// MARK: - カスタムセルビュー
class FileTableCellView: NSTableCellView {

    private let starButton = NSButton()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()

    private var onSetBase: (() -> Void)?
    private var onRemove: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCell()
    }

    private func setupCell() {
        starButton.translatesAutoresizingMaskIntoConstraints = false
        starButton.bezelStyle = .inline
        starButton.isBordered = false
        starButton.target = self
        starButton.action = #selector(onStarClicked)
        addSubview(starButton)

        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = NSFont.systemFont(ofSize: 11)
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(fileNameLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 9)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.title = "✕"
        removeButton.bezelStyle = .inline
        removeButton.isBordered = false
        removeButton.font = NSFont.boldSystemFont(ofSize: 10)
        removeButton.target = self
        removeButton.action = #selector(onRemoveClicked)
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            starButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            starButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            starButton.widthAnchor.constraint(equalToConstant: 20),
            starButton.heightAnchor.constraint(equalToConstant: 20),

            fileNameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            fileNameLabel.leadingAnchor.constraint(equalTo: starButton.trailingAnchor, constant: 4),
            fileNameLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -4),

            subtitleLabel.topAnchor.constraint(equalTo: fileNameLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: starButton.trailingAnchor, constant: 4),
            subtitleLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -4),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 20),
            removeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    public func configure(file: ImageFile, isBase: Bool, onSetBase: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.onSetBase = onSetBase
        self.onRemove = onRemove

        fileNameLabel.stringValue = file.name
        subtitleLabel.stringValue = file.subtitle

        starButton.title = isBase ? "★" : "☆"
        if isBase {
            starButton.attributedTitle = NSAttributedString(
                string: "★",
                attributes: [.foregroundColor: NSColor.systemYellow, .font: NSFont.boldSystemFont(ofSize: 13)]
            )
        } else {
            starButton.attributedTitle = NSAttributedString(
                string: "☆",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)]
            )
        }
    }

    @objc private func onStarClicked() {
        onSetBase?()
    }

    @objc private func onRemoveClicked() {
        onRemove?()
    }
}
