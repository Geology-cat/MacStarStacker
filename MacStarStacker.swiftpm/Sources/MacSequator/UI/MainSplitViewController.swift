import Cocoa

/// 3ペイン分割を管理するメインスプリットビューコントローラ（macOS 10.12+ 互換）
public class MainSplitViewController: NSSplitViewController {

    public let fileListVC = FileListViewController()
    public let canvasVC = CanvasViewController()
    public let settingsVC = SettingsViewController()

    override public func viewDidLoad() {
        super.viewDidLoad()

        // 1. 左ペイン (ファイルリスト)
        let leftItem = NSSplitViewItem(viewController: fileListVC)
        leftItem.minimumThickness = 220
        leftItem.maximumThickness = 320
        leftItem.holdingPriority = NSLayoutConstraint.Priority(260)
        addSplitViewItem(leftItem)

        // 2. 中央ペイン (キャンバス・プレビュー)
        let centerItem = NSSplitViewItem(viewController: canvasVC)
        centerItem.minimumThickness = 500
        centerItem.holdingPriority = NSLayoutConstraint.Priority(200)
        addSplitViewItem(centerItem)

        // 3. 右ペイン (設定)
        let rightItem = NSSplitViewItem(viewController: settingsVC)
        rightItem.minimumThickness = 280
        rightItem.maximumThickness = 380
        rightItem.holdingPriority = NSLayoutConstraint.Priority(260)
        addSplitViewItem(rightItem)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
    }
}
