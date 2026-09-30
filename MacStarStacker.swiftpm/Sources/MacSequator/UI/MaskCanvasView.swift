import Cocoa
import Accelerate

/// 中央の画像プレビューおよびマスクブラシ描画を行うカスタムNSView（macOS 14+）
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

    /// 表示倍率（0.25〜10倍）。変わるたびに onZoomChanged で知らせる（ツールバーの倍率表示用）
    public var zoomScale: CGFloat = 1.0 {
        didSet {
            // didSet 内での代入は didSet を再度呼ばないため、範囲に収めたうえでそのまま通知する
            let clamped = min(Self.maximumZoom, max(Self.minimumZoom, zoomScale))
            if clamped != zoomScale { zoomScale = clamped }
            needsDisplay = true
            onZoomChanged?(zoomScale)
        }
    }
    public static let minimumZoom: CGFloat = 0.25
    public static let maximumZoom: CGFloat = 10.0
    public var onZoomChanged: ((CGFloat) -> Void)?

    /// マスクの表示の濃さ。マスクには塗った色を不透明で記録し（自動判定の結果もブラシも同じ）、表示だけ半透明にする
    static let overlayOpacity: CGFloat = 0.35

    /// 境界ぼかしの半径（元画像のpx）。合成と同じだけぼかしてマスクを表示し、なだらかに薄くなる範囲が分かるようにする
    public var maskFeatherRadius: CGFloat = 0 {
        didSet {
            guard oldValue != maskFeatherRadius else { return }
            updateOverlayImage()
            needsDisplay = true
        }
    }

    public var panOffset: CGPoint = .zero {
        didSet {
            needsDisplay = true
        }
    }

    /// OFF の間はマスク用フル解像度バッファもマウス追跡描画も行わない。
    public var isMaskEditingEnabled: Bool = false {
        didSet {
            guard oldValue != isMaskEditingEnabled else { return }
            isDragging = false
            lastImagePt = nil
            hoverViewPt = nil
            if isMaskEditingEnabled {
                updateImageContext()
                synchronizeMask(from: StackingStateController.shared.maskBitmap)
            } else {
                maskCtx = nil
                overlayCGImage = nil
                synchronizedMaskIdentifier = nil
            }
            updateCursorIfMouseInside()
            needsDisplay = true
        }
    }

    // マスクコンテキスト（元画像のピクセル解像度）
    private var maskCtx: CGContext? = nil {
        didSet { previewNeedsRebuild = true }
    }
    /// ぼかして表示するための縮小マスク（ブラシは両方に描く）。元のマスクを置き換えたときは作り直す
    private var previewMaskCtx: CGContext?
    private var previewScale: CGFloat = 1
    private var previewNeedsRebuild = true
    private var overlayCGImage: CGImage? = nil
    private var lastImagePt: CGPoint? = nil
    private var hoverViewPt: CGPoint? = nil
    private var isDragging: Bool = false
    private var isSpacePressed: Bool = false
    /// 画像をつかんで動かしている最中か
    private var isPanning: Bool = false
    private var lastDragPoint: CGPoint = .zero
    private var synchronizedMaskIdentifier: ObjectIdentifier? = nil

    private var imagePixelWidth: Int = 0
    private var imagePixelHeight: Int = 0
    var hasAllocatedMaskBuffer: Bool { maskCtx != nil }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // macOS 14 以降は既定でビューの外にも描画されるため、拡大した画像がツールバーに重ならないよう切り取る
        clipsToBounds = true
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

        let dimensionsChanged = W != imagePixelWidth || H != imagePixelHeight
        imagePixelWidth = W
        imagePixelHeight = H

        guard isMaskEditingEnabled else {
            if dimensionsChanged {
                maskCtx = nil
                overlayCGImage = nil
                synchronizedMaskIdentifier = nil
            }
            return
        }

        if dimensionsChanged || maskCtx == nil {
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
            synchronizedMaskIdentifier = nil
            synchronizeMask(from: StackingStateController.shared.maskBitmap)
            updateOverlayImage()
        }
    }

    /// 外部の「マスクをクリア」とキャンバス内のバッファを同期する。
    public func synchronizeMask(from mask: NSImage?) {
        guard isMaskEditingEnabled, let ctx = maskCtx else { return }
        let identifier = mask.map(ObjectIdentifier.init)
        guard identifier != synchronizedMaskIdentifier else { return }

        ctx.clear(CGRect(x: 0, y: 0, width: imagePixelWidth, height: imagePixelHeight))
        previewNeedsRebuild = true
        if let mask = mask,
           let cg = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: imagePixelWidth, height: imagePixelHeight))
        }
        synchronizedMaskIdentifier = identifier
        updateOverlayImage()
        needsDisplay = true
    }

    public func clearMask() {
        if let ctx = maskCtx {
            ctx.clear(CGRect(x: 0, y: 0, width: imagePixelWidth, height: imagePixelHeight))
            previewNeedsRebuild = true
            updateOverlayImage()
            synchronizedMaskIdentifier = nil
            StackingStateController.shared.maskBitmap = nil
            needsDisplay = true
        }
    }

    /// 表示用のマスク。境界ぼかしがあるときは、縮小した画像を合成と同じ強さ（標準偏差＝半径）でぼかす
    private func updateOverlayImage() {
        guard let maskCtx else {
            overlayCGImage = nil
            previewMaskCtx = nil
            return
        }
        guard maskFeatherRadius >= 0.5 else {
            overlayCGImage = maskCtx.makeImage()
            return
        }
        if previewNeedsRebuild || previewMaskCtx == nil {
            rebuildPreviewMask(from: maskCtx)
        }
        guard let preview = previewMaskCtx, let previewData = preview.data else {
            overlayCGImage = maskCtx.makeImage()
            return
        }
        let width = preview.width, height = preview.height
        let scale = previewScale
        // 縮小マスクはブラシで描き足していくため、写しをぼかす
        guard let small = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = small.data else {
            overlayCGImage = maskCtx.makeImage()
            return
        }
        memcpy(data, previewData, width * height * 4)
        // 箱形のぼかしを3回重ねるとガウスぼかしに近くなる（分散は1回あたり (b^2 - 1) / 12）
        let sigma = Double(maskFeatherRadius * scale)
        var box = Int((4 * sigma * sigma + 1).squareRoot().rounded())
        if box % 2 == 0 { box += 1 }
        if box >= 3 {
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            buffer.withUnsafeMutableBytes { temporary in
                var source = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                           rowBytes: width * 4)
                var destination = vImage_Buffer(data: temporary.baseAddress, height: vImagePixelCount(height),
                                                width: vImagePixelCount(width), rowBytes: width * 4)
                for _ in 0..<3 {
                    vImageBoxConvolve_ARGB8888(&source, &destination, nil, 0, 0, UInt32(box), UInt32(box), nil,
                                               vImage_Flags(kvImageEdgeExtend))
                    swap(&source, &destination)
                }
                // 3回目の結果は source 側（入れ替え後）にある。元のコンテキストに戻す
                if source.data != data { memcpy(data, source.data, width * height * 4) }
            }
        }
        overlayCGImage = small.makeImage() ?? maskCtx.makeImage()
    }

    private func rebuildPreviewMask(from maskCtx: CGContext) {
        let scale = min(1.0, Self.overlayBlurMaxSide / CGFloat(max(maskCtx.width, maskCtx.height)))
        let width = max(1, Int((CGFloat(maskCtx.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(maskCtx.height) * scale).rounded()))
        guard let preview = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let full = maskCtx.makeImage() else {
            previewMaskCtx = nil
            return
        }
        preview.interpolationQuality = .medium
        preview.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        previewMaskCtx = preview
        previewScale = CGFloat(width) / CGFloat(maskCtx.width)
        previewNeedsRebuild = false
    }

    /// 表示しているマスク（テスト用）
    var displayedOverlay: CGImage? { overlayCGImage }

    /// ぼかして表示するマスクの長辺（px）。ブラシで塗るたびに作り直すため、軽い大きさにする
    private static let overlayBlurMaxSide: CGFloat = 1600

    func exportMaskBitmap() {
        guard let cg = maskCtx?.makeImage() else { return }
        let nsImg = NSImage(cgImage: cg, size: NSSize(width: imagePixelWidth, height: imagePixelHeight))
        synchronizedMaskIdentifier = ObjectIdentifier(nsImg)
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

    /// ブラシの中心の元画像での位置。中心が画像の外でも、ブラシの円が画像に掛かっていれば返す（画像の端まで塗れる）
    func brushImagePoint(_ viewPt: CGPoint) -> CGPoint? {
        let rect = imageDrawRect()
        guard rect.width > 0 && rect.height > 0 else { return nil }
        let radius = StackingStateController.shared.brushSize / 2.0
        guard rect.insetBy(dx: -radius, dy: -radius).contains(viewPt) else { return nil }
        let u = (viewPt.x - rect.origin.x) / rect.width
        let v = (viewPt.y - rect.origin.y) / rect.height
        return CGPoint(x: u * CGFloat(imagePixelWidth), y: v * CGFloat(imagePixelHeight))
    }

    func viewToImagePoint(_ viewPt: CGPoint) -> CGPoint? {
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
        if isMaskEditingEnabled, let overlay = overlayCGImage {
            ctx.saveGState()
            ctx.setAlpha(Self.overlayOpacity) // 半透明オーバーレイ
            ctx.translateBy(x: drawRect.origin.x, y: drawRect.origin.y + drawRect.height)
            ctx.scaleBy(x: 1.0, y: -1.0)
            ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: drawRect.width, height: drawRect.height))
            ctx.restoreGState()
        }

        // 3. ブラシカーソルリング描画
        if isMaskEditingEnabled, let hoverPt = hoverViewPt,
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
            updateCursor()
            needsDisplay = true
        } else {
            super.keyUp(with: event)
        }
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPt = convert(event.locationInWindow, from: nil)
        lastDragPoint = viewPt

        if isPanModifierActive(event) || (!isMaskEditingEnabled && currentImage != nil) {
            isPanning = true
            NSCursor.closedHand.set()
            return
        }

        // マスク描画モードの場合
        if isMaskEditingEnabled {
            if let imgPt = brushImagePoint(viewPt) {
                isDragging = true
                paint(at: imgPt, from: imgPt)
                lastImagePt = imgPt
            }
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        let viewPt = convert(event.locationInWindow, from: nil)

        if isPanning {
            let dx = viewPt.x - lastDragPoint.x
            let dy = viewPt.y - lastDragPoint.y
            panOffset = CGPoint(x: panOffset.x + dx, y: panOffset.y + dy)
            lastDragPoint = viewPt
            return
        }

        if isDragging, isMaskEditingEnabled {
            if let imgPt = brushImagePoint(viewPt) {
                paint(at: imgPt, from: lastImagePt ?? imgPt)
                lastImagePt = imgPt
            }
        }

        if isMaskEditingEnabled {
            hoverViewPt = viewPt
            needsDisplay = true
        }
    }

    override public func mouseUp(with event: NSEvent) {
        let completedMaskStroke = isDragging && isMaskEditingEnabled
        isDragging = false
        isPanning = false
        lastImagePt = nil
        updateCursor()
        if completedMaskStroke { exportMaskBitmap() }
        needsDisplay = true
    }

    override public func mouseMoved(with event: NSEvent) {
        updateCursor()
        guard isMaskEditingEnabled else { return }
        hoverViewPt = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override public func mouseExited(with event: NSEvent) {
        guard isMaskEditingEnabled else { return }
        hoverViewPt = nil
        needsDisplay = true
    }

    override public func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    /// 画像はカーソルでつかんで動かす（マスク編集中は Space または Option を押しながらドラッグ）
    private func isPanModifierActive(_ event: NSEvent) -> Bool {
        isSpacePressed || event.modifierFlags.contains(.option)
    }

    private func updateCursor() {
        if isPanning {
            NSCursor.closedHand.set()
        } else if isSpacePressed || (!isMaskEditingEnabled && currentImage != nil) {
            NSCursor.openHand.set()
        } else if isMaskEditingEnabled {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// マウスがキャンバス上にあるときだけカーソルを切り替える（外にあるときに変えると他の場所の表示が変わる）
    private func updateCursorIfMouseInside() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point) { updateCursor() }
    }

    override public func scrollWheel(with event: NSEvent) {
        // スクロールでは画像を動かさない（つかんで動かす）。Cmd + スクロールでズームする
        guard event.modifierFlags.contains(.command) else { return }
        zoomScale += event.deltaY * 0.05
    }

    /// トラックパッドのピンチでズームする
    override public func magnify(with event: NSEvent) {
        zoomScale *= 1 + event.magnification
    }

    // MARK: - ペイントロジック

    /// ブラシの1区間を描く（空=青、地上=緑は塗った色で置き換え、消しゴムは透明にする）
    private func stroke(in ctx: CGContext, from start: CGPoint, to end: CGPoint, width: CGFloat) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width)

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
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.restoreGState()
    }

    func paint(at currentPt: CGPoint, from previousPt: CGPoint) {
        guard let ctx = maskCtx else { return }

        let rect = imageDrawRect()
        let scaleFactor = CGFloat(imagePixelWidth) / max(1.0, rect.width)
        let brushRadius = (StackingStateController.shared.brushSize * scaleFactor) / 2.0

        // MaskCanvasViewは上原点、ビットマップCGContextは下原点なのでY軸を変換する。
        // ここを変換しないと、ポインタ位置の上下反対へマスクが描かれる。
        let contextCurrentPt = CGPoint(
            x: currentPt.x,
            y: CGFloat(imagePixelHeight) - currentPt.y
        )
        let contextPreviousPt = CGPoint(
            x: previousPt.x,
            y: CGFloat(imagePixelHeight) - previousPt.y
        )
        stroke(in: ctx, from: contextPreviousPt, to: contextCurrentPt, width: brushRadius * 2.0)
        // ぼかして表示するための縮小マスクにも同じように描く（毎回元の解像度から縮小すると重いため）
        if let preview = previewMaskCtx, !previewNeedsRebuild {
            let scale = previewScale
            stroke(in: preview,
                   from: CGPoint(x: contextPreviousPt.x * scale, y: contextPreviousPt.y * scale),
                   to: CGPoint(x: contextCurrentPt.x * scale, y: contextCurrentPt.y * scale),
                   width: brushRadius * 2.0 * scale)
        }

        updateOverlayImage()
        needsDisplay = true
    }
}
