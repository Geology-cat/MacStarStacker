import Cocoa

/// 「すべてクリア」の確認ダイアログ。ボタンとメニューの両方から同じ手順で呼び出す。
enum ResetAllConfirmation {
    static func run(for window: NSWindow?) {
        let state = StackingStateController.shared
        guard state.canResetAll else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "すべてクリアしますか？"
        alert.informativeText = "読み込んだ画像（Light / Dark / Flat / Bias）、スタック結果、マスク、各種設定を破棄して起動時の状態に戻します。この操作は取り消せません。"
        alert.addButton(withTitle: "すべてクリア")
        alert.addButton(withTitle: "キャンセル")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            StackingStateController.shared.resetAll()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}

/// 左ペインのファイル一覧・管理ビューコントローラ（macOS 14+）
public class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// プログラムから選択し直している間は、選択の変更をプレビューの切り替えとして扱わない
    private var isSyncingSelection = false

    private let segmentedTypePicker = NSSegmentedControl()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "ファイルリスト")
    private let addButton = NSButton()
    private let clearButton = NSButton()
    private let resetAllButton = NSButton()
    private let baseInfoView = NSView()
    private let baseInfoLabel = NSTextField(labelWithString: "")

    private var currentType: ImageType = .light

    /// 一覧の行。Light タブでは、地上固定フレームがあれば一番上に「地上固定フレーム」の見出しと行を出す
    private enum Row {
        case header(String)
        case file(ImageFile, ImageType)
    }

    private var rows: [Row] {
        let state = StackingStateController.shared
        let files = state.images[currentType] ?? []
        let groundFixed = currentType == .light ? (state.images[.groundFixed] ?? []) : []
        guard !groundFixed.isEmpty else { return files.map { .file($0, currentType) } }
        return [.header("地上固定フレーム（\(groundFixed.count)）")] + groundFixed.map { .file($0, .groundFixed) }
            + [.header("Light（\(files.count)）")] + files.map { .file($0, .light) }
    }
    private var stateChangeObserver: NSObjectProtocol?
    private var stateResetObserver: NSObjectProtocol?

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
        stateResetObserver = NotificationCenter.default.addObserver(
            forName: .stackingStateDidReset,
            object: StackingStateController.shared,
            queue: .main
        ) { [weak self] _ in
            // 起動時と同じくLightタブ表示に戻す。
            self?.currentType = .light
            self?.segmentedTypePicker.selectedSegment = 0
            self?.tableView.deselectAll(nil)
            self?.updateUI()
        }

        updateUI()
    }

    deinit {
        for observer in [stateChangeObserver, stateResetObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupUI() {
        // 1. タイトル
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = NSFont.boldSystemFont(ofSize: 13)
        view.addSubview(headerLabel)

        resetAllButton.translatesAutoresizingMaskIntoConstraints = false
        resetAllButton.title = "すべてクリア"
        resetAllButton.bezelStyle = .roundRect
        resetAllButton.font = NSFont.systemFont(ofSize: 11)
        if #available(macOS 10.14, *) {
            resetAllButton.contentTintColor = .systemRed
        }
        resetAllButton.toolTip = "画像・結果・マスク・設定をすべて破棄して起動時の状態に戻します"
        resetAllButton.target = self
        resetAllButton.action = #selector(onResetAllClicked)
        view.addSubview(resetAllButton)

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
        clearButton.title = "リストをクリア"
        clearButton.toolTip = "表示中の種類（Light / Dark / Flat / Bias）の画像だけを削除します"
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
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: resetAllButton.leadingAnchor, constant: -8),

            resetAllButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            resetAllButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

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
            clearButton.widthAnchor.constraint(equalToConstant: 96),

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

        resetAllButton.isEnabled = state.canResetAll

        tableView.reloadData()
        selectDisplayedRow()
    }

    /// プレビューに表示中のファイル（スタック結果を表示中は nil）。キャンバスと同じ決め方
    private var displayedFile: ImageFile? {
        let state = StackingStateController.shared
        if state.showResult, state.stackedResult != nil { return nil }
        return state.previewImage ?? state.nightscapeReferenceImage
    }

    /// 再読み込みで消える選択を、プレビューに表示中のファイルの行に戻す
    private func selectDisplayedRow() {
        let rows = self.rows
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        if let displayed = displayedFile, let row = rows.firstIndex(where: {
            if case .file(let file, _) = $0 { return file.id == displayed.id }
            return false
        }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        let rows = self.rows
        guard row < rows.count, case .header = rows[row] else { return false }
        return true
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let rows = self.rows
        guard row < rows.count, case .header = rows[row] else { return tableView.rowHeight }
        return 22
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return !self.tableView(tableView, isGroupRow: row)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rows = self.rows
        guard row < rows.count else { return nil }
        let file: ImageFile, type: ImageType
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.boldSystemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            return label
        case .file(let rowFile, let rowType):
            file = rowFile
            type = rowType
        }

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
            canBeBase: type != .groundFixed,
            isDisplayed: displayedFile?.id == file.id,
            onSetBase: { [weak self] in
                StackingStateController.shared.baseImage = file
                StackingStateController.shared.previewImage = file
                self?.updateUI()
            },
            onRemove: {
                StackingStateController.shared.remove(file: file, from: type)
            }
        )

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = tableView.selectedRow
        let rows = self.rows
        guard row >= 0, row < rows.count, case .file(let file, _) = rows[row] else { return }
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
        selectDisplayedRow()
    }

    @objc private func onAddClicked() {
        let panel = ImageImportSupport.makeOpenPanel(title: "\(currentType.rawValue)画像を選択")
        panel.begin { [weak self] response in
            guard response == .OK, let self = self else { return }
            StackingStateController.shared.add(urls: panel.urls, to: self.currentType)
        }
    }

    @objc private func onResetAllClicked() {
        ResetAllConfirmation.run(for: view.window)
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
    /// プレビューに表示中の行の目印（左端の帯）
    private let displayedMarker = NSView()

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
        displayedMarker.translatesAutoresizingMaskIntoConstraints = false
        displayedMarker.wantsLayer = true
        displayedMarker.layer?.backgroundColor = NSColor.systemBlue.cgColor
        displayedMarker.layer?.cornerRadius = 1.5
        displayedMarker.isHidden = true
        addSubview(displayedMarker)

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
            displayedMarker.leadingAnchor.constraint(equalTo: leadingAnchor),
            displayedMarker.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            displayedMarker.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            displayedMarker.widthAnchor.constraint(equalToConstant: 3),

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

    public func configure(file: ImageFile, isBase: Bool, canBeBase: Bool = true, isDisplayed: Bool,
                          onSetBase: @escaping () -> Void, onRemove: @escaping () -> Void) {
        // 地上固定フレームは基準画像にできないため ★ を出さない
        starButton.isHidden = !canBeBase
        self.onSetBase = onSetBase
        self.onRemove = onRemove

        fileNameLabel.stringValue = file.name
        // プレビューに表示中のファイルは、左端の帯と太字で示す
        displayedMarker.isHidden = !isDisplayed
        fileNameLabel.font = isDisplayed ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 11)
        toolTip = isDisplayed ? "プレビューに表示中" : nil
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
