import Cocoa
import UniformTypeIdentifiers
import ObjectiveC

private var openPanelDelegateAssociationKey: UInt8 = 0

private final class ImageOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        return ImageImportSupport.isSupportedImage(url)
    }
}

/// アプリが受け付ける画像ファイルと、ファイル／フォルダ入力の展開処理を一元管理する。
enum ImageImportSupport {
    static let supportedExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "dng", "pef",
        "tif", "tiff", "fit", "fits", "jpg", "jpeg", "png", "heic"
    ]

    static let allowedFileTypes = supportedExtensions.sorted()

    static func isSupportedImage(_ url: URL) -> Bool {
        url.isFileURL && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 選択・ドロップされたフォルダを再帰的に展開し、画像だけを名前順で返す。
    static func expandedImageURLs(from urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        var candidates: [URL] = []

        func appendIfSupported(_ url: URL) {
            guard isSupportedImage(url), fileManager.isReadableFile(atPath: url.path) else { return }
            candidates.append(url.standardizedFileURL)
        }

        for inputURL in urls where inputURL.isFileURL {
            let url = inputURL.standardizedFileURL
            let values = try? url.resourceValues(forKeys: resourceKeys)
            if values?.isDirectory == true {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let childURL as URL in enumerator {
                    let childValues = try? childURL.resourceValues(forKeys: resourceKeys)
                    if childValues?.isRegularFile == true {
                        appendIfSupported(childURL)
                    }
                }
            } else {
                appendIfSupported(url)
            }
        }

        var seenPaths = Set<String>()
        return candidates
            .sorted {
                let nameOrder = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                if nameOrder == .orderedSame {
                    return $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
                return nameOrder == .orderedAscending
            }
            .filter { seenPaths.insert($0.path).inserted }
    }

    static func containsImportableItem(_ urls: [URL]) -> Bool {
        let fileManager = FileManager.default
        return urls.contains { url in
            guard url.isFileURL else { return false }
            var isDirectory: ObjCBool = false
            return isSupportedImage(url) || (fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
    }

    static func makeOpenPanel(title: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "画像を複数選択するか、画像が入ったフォルダを選択してください。"
        panel.prompt = "追加"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        // FITSはmacOSで未宣言の動的UTTypeになるため、.dataで受けて
        // delegate側で拡張子を厳密に絞る。通常画像とFITSを同時に正しく選択できる。
        panel.allowedContentTypes = [.data]
        let filterDelegate = ImageOpenPanelDelegate()
        panel.delegate = filterDelegate
        objc_setAssociatedObject(
            panel,
            &openPanelDelegateAssociationKey,
            filterDelegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return panel
    }
}

/// NSView自身がドラッグ先になることで、ViewControllerに届かなかったドロップを確実に処理する。
final class ImageDropView: NSView {
    var onImageURLsDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    private func droppedURLs(from sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] ?? []
        return objects.map { $0 as URL }.filter(\.isFileURL)
    }

    private func setDropHighlight(_ highlighted: Bool) {
        wantsLayer = true
        layer?.borderWidth = highlighted ? 2 : 0
        layer?.borderColor = highlighted ? NSColor.systemBlue.cgColor : NSColor.clear.cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = droppedURLs(from: sender)
        guard ImageImportSupport.containsImportableItem(urls) else { return [] }
        setDropHighlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageImportSupport.containsImportableItem(droppedURLs(from: sender)) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        let urls = ImageImportSupport.expandedImageURLs(from: droppedURLs(from: sender))
        guard !urls.isEmpty else { return false }
        onImageURLsDropped?(urls)
        return true
    }
}
