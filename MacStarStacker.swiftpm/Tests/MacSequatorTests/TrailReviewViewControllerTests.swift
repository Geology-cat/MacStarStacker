import AppKit
import XCTest
@testable import MacSequator

final class TrailReviewViewControllerTests: XCTestCase {
    private func image(_ value: UInt8) -> NSImage {
        let pixels = [value, value, value, UInt8.max]
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: 1, height: 1))
    }

    private func makeItem(frameIndex: Int = 0) -> DetectedTrailItem {
        DetectedTrailItem(
            frameIndex: frameIndex,
            file: ImageFile(url: URL(fileURLWithPath: "/tmp/test-frame-\(frameIndex).png")),
            originalImage: image(20),
            maskImage: image(255),
            highlightedImage: image(180),
            repairedImage: image(40),
            detectedType: "人工衛星 (微弱直線)",
            confidenceScore: 0.8,
            isLikelyMeteor: false,
            isMarkedForRemoval: true
        )
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }

    func testReviewSheetUsesCompactScreenBoundedSize() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 620)
        let size = TrailReviewViewController.contentSize(for: visibleFrame)
        XCTAssertLessThanOrEqual(size.width, 720)
        XCTAssertLessThanOrEqual(size.height, 440)
        XCTAssertLessThanOrEqual(size.width, visibleFrame.width - 120)
        XCTAssertLessThanOrEqual(size.height, visibleFrame.height - 160)
    }

    func testHighlightToggleSelectsOriginalOrHighlightedImage() {
        let item = makeItem()
        XCTAssertTrue(TrailReviewViewController.previewImage(
            for: item, mode: 0, showsHighlight: true
        ) === item.highlightedImage)
        XCTAssertTrue(TrailReviewViewController.previewImage(
            for: item, mode: 0, showsHighlight: false
        ) === item.originalImage)
        XCTAssertTrue(TrailReviewViewController.previewImage(
            for: item, mode: 1, showsHighlight: false
        ) === item.repairedImage)
        XCTAssertTrue(TrailReviewViewController.previewImage(
            for: item, mode: 2, showsHighlight: false
        ) === item.maskImage)
    }

    func testReviewViewContainsEnabledHighlightCheckbox() {
        let item = makeItem()
        let controller = TrailReviewViewController(items: [item])
        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let checkbox = allSubviews(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "光跡ハイライトを表示" }
        let preview = allSubviews(of: controller.view)
            .compactMap { $0 as? NSImageView }
            .first
        XCTAssertNotNil(checkbox)
        XCTAssertEqual(checkbox?.state, .on)
        XCTAssertEqual(checkbox?.isEnabled, true)
        XCTAssertTrue(preview?.image === item.highlightedImage)

        checkbox?.performClick(nil)
        XCTAssertEqual(checkbox?.state, .off)
        XCTAssertTrue(preview?.image === item.originalImage)

        XCTAssertLessThanOrEqual(controller.view.frame.width, 720)
        XCTAssertLessThanOrEqual(controller.view.frame.height, 440)
        XCTAssertFalse(controller.view.hasAmbiguousLayout)
        for subview in controller.view.subviews {
            XCTAssertTrue(controller.view.bounds.contains(subview.frame), "\(subview) がシート外へはみ出しています")
        }
    }

    func testManyCandidatesDoNotIncreaseInitialWindowSize() {
        let items = (0..<60).map { makeItem(frameIndex: $0) }
        let controller = TrailReviewViewController(items: items)
        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(controller.view.frame.width, 720)
        XCTAssertLessThanOrEqual(controller.view.frame.height, 440)
    }

    func testPresentedReviewWindowStartsCompactAndCanBeResized() {
        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 620))
        let window = NSWindow(contentViewController: host)
        window.orderFront(nil)
        defer { window.close() }

        let items = (0..<60).map { makeItem(frameIndex: $0) }
        let controller = TrailReviewViewController(items: items)
        let reviewWindow = controller.makeReviewWindow()
        window.addChildWindow(reviewWindow, ordered: .above)
        reviewWindow.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        defer {
            window.removeChildWindow(reviewWindow)
            reviewWindow.close()
        }

        guard let presentedWindow = window.childWindows?.first else {
            return XCTFail("レビュー画面が表示されませんでした")
        }
        XCTAssertTrue(presentedWindow === reviewWindow)
        XCTAssertTrue(presentedWindow.styleMask.contains(.resizable))
        XCTAssertLessThanOrEqual(presentedWindow.frame.width, 820)
        XCTAssertLessThanOrEqual(presentedWindow.frame.height, 500)
        XCTAssertEqual(presentedWindow.contentMinSize, TrailReviewViewController.minimumContentSize)
        XCTAssertGreaterThan(presentedWindow.contentMaxSize.width, presentedWindow.contentLayoutRect.width)
        XCTAssertGreaterThan(presentedWindow.contentMaxSize.height, presentedWindow.contentLayoutRect.height)

        presentedWindow.setContentSize(TrailReviewViewController.minimumContentSize)
        presentedWindow.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.view.hasAmbiguousLayout)
        for subview in controller.view.subviews {
            XCTAssertTrue(controller.view.bounds.contains(subview.frame), "\(subview) が最小画面の外へはみ出しています")
        }

        let requestedSize = NSSize(
            width: min(980, presentedWindow.contentMaxSize.width),
            height: min(640, presentedWindow.contentMaxSize.height)
        )
        presentedWindow.setContentSize(requestedSize)
        guard let contentView = presentedWindow.contentView else {
            return XCTFail("レビュー画面の内容ビューがありません")
        }
        contentView.layoutSubtreeIfNeeded()
        XCTAssertEqual(contentView.frame.size.width, requestedSize.width, accuracy: 1)
        XCTAssertEqual(contentView.frame.size.height, requestedSize.height, accuracy: 1)
        XCTAssertFalse(controller.view.hasAmbiguousLayout)
        for subview in controller.view.subviews {
            XCTAssertTrue(controller.view.bounds.contains(subview.frame), "\(subview) が拡大後の画面外へはみ出しています")
        }
    }
}
