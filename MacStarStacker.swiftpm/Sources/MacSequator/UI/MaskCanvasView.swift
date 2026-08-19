import Cocoa

/// 中央の画像プレビューおよびマスクブラシ描画を行うカスタムNSView（macOS 10.12+ 互換）
public class MaskCanvasView: NSView {

    // ── 表示・描画状態 ──
    public var currentImage: NSImage? {
        didSet {
            if currentImage !== oldValue {
                updateImageContext()
                needsDisplay = true
            }
        }
    }

    public var zoomScale: CGFloat = 1.0 {
        didSet {
            needsDisplay = true
        }
    }

    public var panOffset: CGPoint = .zero {
        didSet {
            needsDisplay = true
        }
    }

    // マスクコンテキスト（元画像のピクセル解像度）
    private var maskCtx: CGContext? = nil
    private var overlayCGImage: CGImage? = nil
    private var lastImagePt: CGPoint? = nil
    private var hoverViewPt: CGPoint? = nil
    private var isDragging: Bool = false
    private var isSpacePressed: Bool = false
    private var lastDragPoint: CGPoint = .zero

    private var imagePixelWidth: Int = 0
    private var imagePixelHeight: Int = 0

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTrackingArea()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    // MARK: - マスクコンテキスト管理

    private func updateImageContext() {
        guard let img = currentImage,
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            maskCtx = nil
            overlayCGImage = nil
            imagePixelWidth = 0
            imagePixelHeight = 0
            return
        }

        let W = cg.width
        let H = cg.height

        if W != imagePixelWidth || H != imagePixelHeight || maskCtx == nil {
            imagePixelWidth = W
            imagePixelHeight = H

            let cs = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(
                data: nil,
                width: W,
                height: H,
                bitsPerComponent: 8,
                bytesPerRow: W * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            ctx?.clear(CGRect(x: 0, y: 0, width: W, height: H))
            maskCtx = ctx

            // 既存のマスクビットマップがあれば読み込む
            if let existingMask = StackingStateController.shared.maskBitmap,
               let existingCG = existingMask.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx?.draw(existingCG, in: CGRect(x: 0, y: 0, width: W, height: H))
            }

            updateOverlayImage()
        }
    }

    public func clearMask() {
        if let ctx = maskCtx {
            ctx.clear(CGRect(x: 0, y: 0, width: imagePixelWidth, height: imagePixelHeight))
            updateOverlayImage()
            exportMaskBitmap()
            needsDisplay = true
        }
    }

    private func updateOverlayImage() {
        overlayCGImage = maskCtx?.makeImage()
    }

    private func exportMaskBitmap() {
        guard let cg = maskCtx?.makeImage() else { return }
        let nsImg = NSImage(cgImage: cg, size: NSSize(width: imagePixelWidth, height: imagePixelHeight))
        StackingStateController.shared.maskBitmap = nsImg
    }

    // MARK: - 座標変換

    private func imageDrawRect() -> CGRect {
        guard imagePixelWidth > 0 && imagePixelHeight > 0 else { return .zero }

        let viewW = bounds.width
        let viewH = bounds.height
        let imgAspect = CGFloat(imagePixelWidth) / CGFloat(imagePixelHeight)
        let viewAspect = viewW / viewH

        var fitW: CGFloat
        var fitH: CGFloat
        if viewAspect > imgAspect {
            fitH = viewH
            fitW = viewH * imgAspect
        } else {
            fitW = viewW
            fitH = viewW / imgAspect
        }

        let scaledW = fitW * zoomScale
        let scaledH = fitH * zoomScale
        let originX = (viewW - scaledW) / 2.0 + panOffset.x
        let originY = (viewH - scaledH) / 2.0 + panOffset.y

        return CGRect(x: originX, y: originY, width: scaledW, height: scaledH)
    }

    private func viewToImagePoint(_ viewPt: CGPoint) -> CGPoint? {
        let rect = imageDrawRect()
        guard rect.width > 0 && rect.height > 0 else { return nil }

        let u = (viewPt.x - rect.origin.x) / rect.width
        let v = (viewPt.y - rect.origin.y) / rect.height

        guard u >= 0 && u <= 1 && v >= 0 && v <= 1 else { return nil }

        let imgX = u * CGFloat(imagePixelWidth)
        let imgY = v * CGFloat(imagePixelHeight)
        return CGPoint(x: imgX, y: imgY)
    }

    // MARK: - 描画処理

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 背景描画（ダークトーン）
        ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor)
        ctx.fill(bounds)

        guard let img = currentImage,
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            drawPlaceholder(in: bounds)
            return
        }

        let drawRect = imageDrawRect()

        // 1. 画像描画
        ctx.saveGState()
        // AppKit isFlipped 座標系での描画
        ctx.translateBy(x: drawRect.origin.x, y: drawRect.origin.y + drawRect.height)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: drawRect.width, height: drawRect.height))
        ctx.restoreGState()

        // 2. マスクオーバーレイ描画
        if StackingStateController.shared.compositingMode == "SkyGround",
           let overlay = overlayCGImage {
            ctx.saveGState()
            ctx.setAlpha(0.5) // 半透明オーバーレイ
            ctx.translateBy(x: drawRect.origin.x, y: drawRect.origin.y + drawRect.height)
            ctx.scaleBy(x: 1.0, y: -1.0)
            ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: drawRect.width, height: drawRect.height))
            ctx.restoreGState()
        }

        // 3. ブラシカーソルリング描画
        if StackingStateController.shared.compositingMode == "SkyGround",
           let hoverPt = hoverViewPt,
           !isSpacePressed {
            let brushSize = StackingStateController.shared.brushSize
            let ringRect = CGRect(
                x: hoverPt.x - brushSize / 2.0,
                y: hoverPt.y - brushSize / 2.0,
                width: brushSize,
                height: brushSize
            )
            ctx.setLineWidth(1.5)
            switch StackingStateController.shared.brushMode {
            case .sky:
                ctx.setStrokeColor(NSColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 0.9).cgColor)
            case .ground:
                ctx.setStrokeColor(NSColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 0.9).cgColor)
            case .erase:
                ctx.setStrokeColor(NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 0.9).cgColor)
            }
            ctx.strokeEllipse(in: ringRect)
        }
    }

    private func drawPlaceholder(in rect: CGRect) {
        let text = "画像をドロップするか左のリストでファイルを選択\n（Sony, Canon, Nikon, Fuji, OM, Lumix, DNG 等の各社RAW対応）"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                return p
            }()
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let strSize = str.size()
        let strRect = CGRect(
            x: (rect.width - strSize.width) / 2.0,
            y: (rect.height - strSize.height) / 2.0,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: strRect)
    }

    // MARK: - マウス & キーイベント

    override public func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // Space
            isSpacePressed = true
            NSCursor.openHand.set()
        } else {
            super.keyDown(with: event)
        }
    }

    override public func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { // Space
            isSpacePressed = false
            NSCursor.arrow.set()
            needsDisplay = true
        } else {
            super.keyUp(with: event)
        }
    }

    override public func mouseDown(with event: NSEvent) {
        let viewPt = convert(event.locationInWindow, from: nil)
        lastDragPoint = viewPt

        if isSpacePressed || event.modifierFlags.contains(.option) {
            NSCursor.closedHand.set()
            return
        }

        // マスク描画モードの場合
        if StackingStateController.shared.compositingMode == "SkyGround" {
            if let imgPt = viewToImagePoint(viewPt) {
                isDragging = true
                paint(at: imgPt, from: imgPt)
                lastImagePt = imgPt
            }
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        let viewPt = convert(event.locationInWindow, from: nil)

        if isSpacePressed || event.modifierFlags.contains(.option) {
            let dx = viewPt.x - lastDragPoint.x
            let dy = viewPt.y - lastDragPoint.y
            panOffset = CGPoint(x: panOffset.x + dx, y: panOffset.y + dy)
            lastDragPoint = viewPt
            return
        }

        if isDragging, StackingStateController.shared.compositingMode == "SkyGround" {
            if let imgPt = viewToImagePoint(viewPt) {
                paint(at: imgPt, from: lastImagePt ?? imgPt)
                lastImagePt = imgPt
            }
        }

        hoverViewPt = viewPt
        needsDisplay = true
    }

    override public func mouseUp(with event: NSEvent) {
        isDragging = false
        lastImagePt = nil
        if isSpacePressed {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
        exportMaskBitmap()
        needsDisplay = true
    }

    override public func mouseMoved(with event: NSEvent) {
        hoverViewPt = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override public func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // Cmd + スクロールでズーム
            let zoomDelta = event.deltaY * 0.05
            let newScale = max(0.25, min(10.0, zoomScale + zoomDelta))
            zoomScale = newScale
        } else {
            // パン操作
            panOffset = CGPoint(x: panOffset.x + event.deltaX * 2.0, y: panOffset.y + event.deltaY * 2.0)
        }
    }

    // MARK: - ペイントロジック

    private func paint(at currentPt: CGPoint, from previousPt: CGPoint) {
        guard let ctx = maskCtx else { return }

        let rect = imageDrawRect()
        let scaleFactor = CGFloat(imagePixelWidth) / max(1.0, rect.width)
        let brushRadius = (StackingStateController.shared.brushSize * scaleFactor) / 2.0

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(brushRadius * 2.0)

        switch StackingStateController.shared.brushMode {
        case .sky:
            // 空マスク: 青成分（Red=0, Green=0, Blue=255）
            ctx.setBlendMode(.copy)
            ctx.setStrokeColor(NSColor(red: 0.0, green: 0.2, blue: 1.0, alpha: 1.0).cgColor)
        case .ground:
            // 地上マスク: 緑成分（Red=0, Green=255, Blue=0）
            ctx.setBlendMode(.copy)
            ctx.setStrokeColor(NSColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0).cgColor)
        case .erase:
            ctx.setBlendMode(.clear)
        }

        ctx.beginPath()
        ctx.move(to: previousPt)
        ctx.addLine(to: currentPt)
        ctx.strokePath()
        ctx.restoreGState()

        updateOverlayImage()
        needsDisplay = true
    }
}
