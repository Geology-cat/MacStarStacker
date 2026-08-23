import Cocoa

/// アプリケーションのメインウィンドウコントローラ（macOS 14+）
public class MainWindowController: NSWindowController {

    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacStarStacker - 星景写真スタッキング"
        window.minSize = NSSize(width: 1050, height: 640)
        window.center()
        window.setFrameAutosaveName("MacStarStackerMainWindow")

        // ダークアピアランス
        if #available(macOS 10.14, *) {
            window.appearance = NSAppearance(named: .darkAqua)
        } else {
            window.appearance = NSAppearance(named: .vibrantDark)
        }

        self.init(window: window)

        let splitVC = MainSplitViewController()
        self.contentViewController = splitVC
    }
}
