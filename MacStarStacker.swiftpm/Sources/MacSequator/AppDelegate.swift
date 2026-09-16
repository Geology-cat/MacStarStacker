import Cocoa

/// アプリケーションデリゲート（macOS 14+）
public class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?

    public func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMainMenu()

        let mainWindowController = MainWindowController()
        self.mainWindowController = mainWindowController
        mainWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - メニューバー構築

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. アプリケーションメニュー
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = "MacStarStacker"
        appMenu.addItem(withTitle: "\(appName) について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "\(appName) を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "ほかを隠す", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "すべてを表示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "\(appName) を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. ファイルメニュー
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(withTitle: "Light 画像を追加...", action: #selector(onAddLightFiles), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "スタック結果を書き出す...", action: #selector(onExportResult), keyEquivalent: "s")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 3. 編集メニュー
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: #selector(onUndo), keyEquivalent: "z")
        editMenu.addItem(NSMenuItem.separator())
        // 標準レスポンダーチェーンへ渡す。NSOpenPanel 内でも ⌘A が有効になる。
        editMenu.addItem(withTitle: "切り取り", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "貼り付け", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "マスクをクリア", action: #selector(onClearMask), keyEquivalent: "k")
        editMenu.addItem(withTitle: "すべてクリア…", action: #selector(onResetAll), keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 4. 処理メニュー
        let processMenuItem = NSMenuItem()
        let processMenu = NSMenu(title: "処理")
        let startItem = NSMenuItem(title: "スタッキング開始", action: #selector(onStartStack), keyEquivalent: "r")
        processMenu.addItem(startItem)
        processMenuItem.submenu = processMenu
        mainMenu.addItem(processMenuItem)

        // 5. ウィンドウメニュー
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウィンドウ")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "拡大/縮小", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - メニューアクション

    @objc private func onAddLightFiles() {
        let panel = ImageImportSupport.makeOpenPanel(title: "Light画像を選択")
        panel.begin { response in
            guard response == .OK else { return }
            StackingStateController.shared.add(urls: panel.urls, to: .light)
        }
    }

    @objc private func onExportResult() {
        let state = StackingStateController.shared
        guard let img = state.stackedResult ?? state.loadNSImage(from: state.previewImage) else { return }
        ImageExporter.export(
            image: img,
            format: state.exportFormat,
            metadata: state.getEffectiveMetadata(),
            embedLensProfile: state.embedLensProfile,
            // スタック結果を書き出すときだけRAW合成結果を使う（プレビュー画像の書き出しでは使わない）
            rawResult: state.stackedResult != nil ? state.stackedRawResult : nil
        )
    }

    @objc private func onUndo() {
        StackingStateController.shared.undo()
    }

    @objc private func onClearMask() {
        guard StackingStateController.shared.enableSkyGroundMask else { return }
        StackingStateController.shared.maskBitmap = nil
    }

    @objc private func onResetAll() {
        ResetAllConfirmation.run(for: NSApp.mainWindow)
    }

    @objc private func onStartStack() {
        StackingStateController.shared.startStacking()
    }
}
