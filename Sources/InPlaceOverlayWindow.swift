import Cocoa
import CoreText

/// 管理屏幕上所有原位翻译覆盖窗口
@MainActor
final class InPlaceOverlayManager {
    static let shared = InPlaceOverlayManager()

    private var overlays: [InPlaceOverlayWindow] = []
    private var globalEscMonitor: Any?
    private var localEscMonitor: Any?

    private init() {
        setupEscMonitors()
    }

    private func setupEscMonitors() {
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self = self, !self.overlays.isEmpty {
                self.closeMostRecent()
                return nil
            }
            return event
        }
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.closeMostRecent()
                }
            }
        }
    }

    func createAndTranslate(capture: CapturedRegionResult) {
        let win = InPlaceOverlayWindow(capture: capture) { [weak self] closedWin in
            self?.overlays.removeAll(where: { $0 === closedWin })
        }
        overlays.append(win)
        win.orderFrontRegardless()
        win.runOCRAndTranslation()
    }

    func closeMostRecent() {
        guard let last = overlays.popLast() else { return }
        last.dismissOverlay()
    }

    func closeAll() {
        let list = overlays
        overlays.removeAll()
        for w in list {
            w.dismissOverlay()
        }
    }

    func closeAllForWindow(_ target: InPlaceOverlayWindow) {
        target.dismissOverlay()
    }
}

/// 渲染用块结构
struct RenderedReplacementBlock {
    let viewRect: NSRect
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let originalText: String
    let translatedText: String
    let lineCount: Int
}

/// 像素色彩边缘中位数采样器 + 前景主色对比计算
final class ImageColorSampler {
    private let width: Int
    private let height: Int
    private let pixels: [UInt8]

    init?(cgImage: CGImage) {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        self.width = w
        self.height = h

        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.pixels = buf
    }

    func sampleColors(normalizedTopLeftRect norm: CGRect) -> (bg: NSColor, fg: NSColor) {
        let pxRect = CGRect(
            x: norm.minX * CGFloat(width),
            y: norm.minY * CGFloat(height),
            width: norm.width * CGFloat(width),
            height: norm.height * CGFloat(height)
        )

        let margin: CGFloat = 3.0
        let leftX = max(0, min(width - 1, Int((pxRect.minX - margin).rounded())))
        let rightX = max(0, min(width - 1, Int((pxRect.maxX + margin).rounded())))
        let topY = max(0, min(height - 1, Int((pxRect.minY - margin).rounded())))
        let bottomY = max(0, min(height - 1, Int((pxRect.maxY + margin).rounded())))

        var rs: [UInt8] = []
        var gs: [UInt8] = []
        var bs: [UInt8] = []

        let stepsX = max(8, min(32, (rightX - leftX) / 4))
        let stepsY = max(4, min(20, (bottomY - topY) / 4))

        func addSample(_ x: Int, _ y: Int) {
            let cx = max(0, min(width - 1, x))
            let cy = max(0, min(height - 1, y))
            let idx = (cy * width + cx) * 4
            rs.append(pixels[idx])
            gs.append(pixels[idx + 1])
            bs.append(pixels[idx + 2])
        }

        if rightX > leftX {
            for i in 0...stepsX {
                let x = leftX + (rightX - leftX) * i / stepsX
                addSample(x, topY)
                addSample(x, bottomY)
            }
        }
        if bottomY > topY {
            for j in 0...stepsY {
                let y = topY + (bottomY - topY) * j / stepsY
                addSample(leftX, y)
                addSample(rightX, y)
            }
        }

        if rs.isEmpty {
            addSample(Int(pxRect.midX), topY)
        }

        rs.sort()
        gs.sort()
        bs.sort()
        let mid = rs.count / 2
        let r = CGFloat(rs[mid]) / 255.0
        let g = CGFloat(gs[mid]) / 255.0
        let b = CGFloat(bs[mid]) / 255.0

        let bg = NSColor(srgbRed: r, green: g, blue: b, alpha: 0.985)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        let fg: NSColor
        if luminance > 0.54 {
            fg = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1.0)
        } else {
            fg = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1.0)
        }
        return (bg, fg)
    }
}

/// 统一设计语言的线性矢量图标枚举（全部采用 1.4pt 等线宽、圆头圆角几何美学）
enum UnifiedToolbarIcon {
    case eye        // 原文对比
    case copy       // 复制译文
    case check      // 复制成功
    case passthrough// 鼠标穿透
    case close      // 关闭图层

    /// 在指定 13x13 图标框内用 CoreGraphics 原生矢量路径绘制，保证 Retina 下绝对锐利且风格 100% 统一
    func draw(in box: CGRect, color: NSColor, context cg: CGContext) {
        cg.saveGState()
        cg.setStrokeColor(color.cgColor)
        cg.setFillColor(color.cgColor)
        cg.setLineWidth(1.38)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        let cx = box.midX
        let cy = box.midY

        switch self {
        case .eye:
            // 对称圆润明眸轮廓 + 实心瞳孔圆点
            let w: CGFloat = 11.4
            let h: CGFloat = 6.8
            let left = CGPoint(x: cx - w / 2, y: cy)
            let right = CGPoint(x: cx + w / 2, y: cy)
            let path = CGMutablePath()
            path.move(to: left)
            path.addQuadCurve(to: right, control: CGPoint(x: cx, y: cy - h))
            path.addQuadCurve(to: left, control: CGPoint(x: cx, y: cy + h))
            path.closeSubpath()
            cg.addPath(path)
            cg.strokePath()

            let pupilR: CGFloat = 1.65
            cg.fillEllipse(in: CGRect(x: cx - pupilR, y: cy - pupilR, width: pupilR * 2, height: pupilR * 2))

        case .copy:
            // 标准坐标系（Y向上）：前层圆角实框在右下，后层 L 形圆角衬框在左上
            let frontRect = CGRect(x: cx - 2.6, y: cy - 5.2, width: 7.4, height: 7.4)
            let frontPath = CGPath(roundedRect: frontRect, cornerWidth: 1.8, cornerHeight: 1.8, transform: nil)
            cg.addPath(frontPath)
            cg.strokePath()

            let back = CGMutablePath()
            back.move(to: CGPoint(x: cx - 2.6, y: cy - 1.0))
            back.addLine(to: CGPoint(x: cx - 3.6, y: cy - 1.0))
            back.addArc(tangent1End: CGPoint(x: cx - 5.0, y: cy - 1.0), tangent2End: CGPoint(x: cx - 5.0, y: cy + 0.6), radius: 1.6)
            back.addLine(to: CGPoint(x: cx - 5.0, y: cy + 3.4))
            back.addArc(tangent1End: CGPoint(x: cx - 5.0, y: cy + 5.0), tangent2End: CGPoint(x: cx - 3.4, y: cy + 5.0), radius: 1.6)
            back.addLine(to: CGPoint(x: cx + 0.4, y: cy + 5.0))
            back.addArc(tangent1End: CGPoint(x: cx + 1.8, y: cy + 5.0), tangent2End: CGPoint(x: cx + 1.8, y: cy + 3.6), radius: 1.4)
            cg.addPath(back)
            cg.strokePath()

        case .check:
            // 标准坐标系（Y向上）：圆润饱满的对勾
            let p = CGMutablePath()
            p.move(to: CGPoint(x: cx - 4.3, y: cy + 0.2))
            p.addLine(to: CGPoint(x: cx - 1.2, y: cy - 3.1))
            p.addLine(to: CGPoint(x: cx + 4.5, y: cy + 3.3))
            cg.addPath(p)
            cg.strokePath()

        case .passthrough:
            // 虚线圆角透视层 + 右上穿透箭头
            let r = CGRect(x: cx - 5.0, y: cy - 5.0, width: 10.0, height: 10.0)
            cg.saveGState()
            cg.setLineDash(phase: 0, lengths: [2.2, 2.1])
            let dashBox = CGPath(roundedRect: r, cornerWidth: 2.3, cornerHeight: 2.3, transform: nil)
            cg.addPath(dashBox)
            cg.strokePath()
            cg.restoreGState()

            let arrow = CGMutablePath()
            arrow.move(to: CGPoint(x: cx - 2.0, y: cy - 2.0))
            arrow.addLine(to: CGPoint(x: cx + 2.1, y: cy + 2.1))
            arrow.move(to: CGPoint(x: cx - 0.8, y: cy + 2.1))
            arrow.addLine(to: CGPoint(x: cx + 2.1, y: cy + 2.1))
            arrow.addLine(to: CGPoint(x: cx + 2.1, y: cy - 0.8))
            cg.addPath(arrow)
            cg.strokePath()

        case .close:
            // 圆角外环 + 居中微叉号（与其它图标共享相同的圆角几何体积感）
            let ring = CGRect(x: cx - 5.1, y: cy - 5.1, width: 10.2, height: 10.2)
            cg.strokeEllipse(in: ring)
            let d: CGFloat = 2.15
            let xPath = CGMutablePath()
            xPath.move(to: CGPoint(x: cx - d, y: cy - d))
            xPath.addLine(to: CGPoint(x: cx + d, y: cy + d))
            xPath.move(to: CGPoint(x: cx + d, y: cy - d))
            xPath.addLine(to: CGPoint(x: cx - d, y: cy + d))
            cg.addPath(xPath)
            cg.strokePath()
        }

        cg.restoreGState()
    }
}

/// 现代毛玻璃灵动悬浮原位覆盖窗口
final class InPlaceOverlayWindow: NSPanel {
    private let capture: CapturedRegionResult
    private let onCloseCallback: (InPlaceOverlayWindow) -> Void
    private let toolbarReserveHeight: CGFloat = 38.0
    private let toolbarPlacedOutsideTop: Bool

    private var rootView: OverlayRootContainerView!
    private var canvasView: OverlayImageCanvasView!
    private var toolbarContainer: GlassToolbarCapsuleView!
    private var spinner: NSProgressIndicator!
    private var statusBadge: NSTextField!
    private var divider1: NSView!

    private var compareBtn: ModernPillButton!
    private var copyBtn: ModernPillButton!
    private var passThroughBtn: ModernPillButton!
    private var closeBtn: ModernPillButton!

    private var translationTask: Task<Void, Never>?
    private var autoDimWorkItem: DispatchWorkItem?
    private var allTranslatedText: String = ""
    private var isClickThrough: Bool = false
    private var isTranslatingDone: Bool = false

    static let barWidth: CGFloat = 258.0
    static let barHeight: CGFloat = 30.0

    init(capture: CapturedRegionResult, onClose: @escaping (InPlaceOverlayWindow) -> Void) {
        self.capture = capture
        self.onCloseCallback = onClose

        let screenMaxY = NSScreen.screens.first(where: { $0.frame.intersects(capture.globalScreenRect) })?.frame.maxY ?? 99999
        let canPlaceOutside = (capture.globalScreenRect.maxY + toolbarReserveHeight) <= screenMaxY
        self.toolbarPlacedOutsideTop = canPlaceOutside

        let minWinWidth: CGFloat = Self.barWidth + 4
        let windowRect = NSRect(
            x: capture.globalScreenRect.origin.x,
            y: capture.globalScreenRect.origin.y,
            width: max(capture.globalScreenRect.width, minWinWidth),
            height: capture.globalScreenRect.height + (canPlaceOutside ? toolbarReserveHeight : 0)
        )

        super.init(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false

        setupModernUI(windowSize: windowRect.size)
    }

    override var canBecomeKey: Bool { false }

    private func setupModernUI(windowSize: NSSize) {
        rootView = OverlayRootContainerView(frame: NSRect(origin: .zero, size: windowSize))
        rootView.onHoverStateChanged = { [weak self] hovering in
            self?.handleHoverChanged(hovering)
        }
        self.contentView = rootView

        let canvasOriginY: CGFloat = toolbarPlacedOutsideTop ? toolbarReserveHeight : 0.0
        let canvasFrame = NSRect(
            x: 0,
            y: canvasOriginY,
            width: capture.globalScreenRect.width,
            height: capture.globalScreenRect.height
        )

        canvasView = OverlayImageCanvasView(frame: canvasFrame, cgImage: capture.croppedImage)
        canvasView.isLoading = true
        rootView.addSubview(canvasView)

        // 右上角精致磨砂黑晶胶囊工具条（统一「图标 + 文字」四按钮结构）
        let bw = Self.barWidth
        let bh = Self.barHeight
        let barX = max(0, min(windowSize.width - bw, capture.globalScreenRect.width - bw))
        let barY: CGFloat = toolbarPlacedOutsideTop ? 4 : 6

        toolbarContainer = GlassToolbarCapsuleView(frame: NSRect(x: barX, y: barY, width: bw, height: bh))
        rootView.addSubview(toolbarContainer)

        // 加载态组件
        spinner = NSProgressIndicator(frame: NSRect(x: 13, y: 7, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .vibrantDark)
        spinner.startAnimation(nil)
        toolbarContainer.contentHolder.addSubview(spinner)

        statusBadge = NSTextField(labelWithString: "正在秒译…")
        statusBadge.font = NSFont(name: "PingFangSC-Medium", size: 11.5) ?? NSFont.systemFont(ofSize: 11.5, weight: .medium)
        statusBadge.textColor = NSColor.white.withAlphaComponent(0.92)
        statusBadge.frame = NSRect(x: 34, y: 6, width: 146, height: 18)
        toolbarContainer.contentHolder.addSubview(statusBadge)

        // 完成态四个等高等风格「图标 + 文字」按钮：[👁 原文] [❐ 复制] [⬚ 穿透] | [⊗ 关闭]
        let btnY: CGFloat = 3.5
        let btnH: CGFloat = 23.0

        compareBtn = ModernPillButton(
            frame: NSRect(x: 5, y: btnY, width: 58, height: btnH),
            title: "原文",
            icon: .eye,
            isHoldMode: true
        )
        compareBtn.toolTip = "按住透视对比原图，松开恢复中文"
        compareBtn.isHidden = true
        compareBtn.onHoldChanged = { [weak self] holding in
            self?.canvasView.showOriginalOnly = holding
        }
        toolbarContainer.contentHolder.addSubview(compareBtn)

        copyBtn = ModernPillButton(
            frame: NSRect(x: 65, y: btnY, width: 58, height: btnH),
            title: "复制",
            icon: .copy
        )
        copyBtn.toolTip = "复制全部译文到剪贴板"
        copyBtn.isHidden = true
        copyBtn.onClick = { [weak self] in
            self?.handleCopy()
        }
        toolbarContainer.contentHolder.addSubview(copyBtn)

        passThroughBtn = ModernPillButton(
            frame: NSRect(x: 125, y: btnY, width: 58, height: btnH),
            title: "穿透",
            icon: .passthrough
        )
        passThroughBtn.toolTip = "开启鼠标穿透操作下方窗口（按 Esc 随时关闭）"
        passThroughBtn.isHidden = true
        passThroughBtn.onClick = { [weak self] in
            self?.handleTogglePassThrough()
        }
        toolbarContainer.contentHolder.addSubview(passThroughBtn)

        // 精致竖向微分割线（隔开常规操作与关闭按钮）
        divider1 = NSView(frame: NSRect(x: 188, y: 9, width: 1, height: 12))
        divider1.wantsLayer = true
        divider1.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        toolbarContainer.contentHolder.addSubview(divider1)

        closeBtn = ModernPillButton(
            frame: NSRect(x: 194, y: btnY, width: 59, height: btnH),
            title: "关闭",
            icon: .close,
            isDestructiveHover: true
        )
        closeBtn.toolTip = "关闭翻译覆盖层（快捷键 Esc 或右键点击）"
        closeBtn.onClick = { [weak self] in
            self?.handleDismissOverlay()
        }
        toolbarContainer.contentHolder.addSubview(closeBtn)
    }

    private func handleHoverChanged(_ hovering: Bool) {
        guard isTranslatingDone, !isClickThrough else { return }
        autoDimWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            toolbarContainer.animator().alphaValue = hovering ? 1.0 : 0.42
        }
    }

    private func scheduleToolbarAutoDim() {
        autoDimWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isTranslatingDone, !self.rootView.isMouseInside else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                self.toolbarContainer.animator().alphaValue = 0.42
            }
        }
        autoDimWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: item)
    }

    func runOCRAndTranslation() {
        let cgImg = capture.croppedImage
        let imgViewSize = capture.globalScreenRect.size

        translationTask = Task { @MainActor in
            do {
                let blocks = try await OCRAndParagraphEngine.recognizeBlocks(in: cgImg)
                if Task.isCancelled { return }

                guard !blocks.isEmpty else {
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    self.canvasView.isLoading = false
                    self.statusBadge.frame = NSRect(x: 14, y: 6, width: 168, height: 18)
                    self.statusBadge.stringValue = "未检测到可翻译文字"
                    self.statusBadge.textColor = .systemYellow
                    return
                }

                self.statusBadge.stringValue = "正在秒译 \(blocks.count) 处…"
                let originals = blocks.map { $0.originalText }
                let translatedList = try await MultiSourceTranslator.translateBlocks(originals)
                if Task.isCancelled { return }

                let sampler = ImageColorSampler(cgImage: cgImg)
                var rendered: [RenderedReplacementBlock] = []
                var copyLines: [String] = []

                for (i, blk) in blocks.enumerated() {
                    let trans = (i < translatedList.count ? translatedList[i] : blk.originalText)
                    copyLines.append(trans)

                    let norm = blk.normalizedTopLeftRect
                    let viewRect = NSRect(
                        x: norm.origin.x * imgViewSize.width,
                        y: norm.origin.y * imgViewSize.height,
                        width: norm.width * imgViewSize.width,
                        height: norm.height * imgViewSize.height
                    )
                    let colors = sampler?.sampleColors(normalizedTopLeftRect: norm) ?? (
                        bg: NSColor.white.withAlphaComponent(0.97),
                        fg: NSColor.black
                    )

                    rendered.append(
                        RenderedReplacementBlock(
                            viewRect: viewRect,
                            backgroundColor: colors.bg,
                            foregroundColor: colors.fg,
                            originalText: blk.originalText,
                            translatedText: trans,
                            lineCount: blk.lineCount
                        )
                    )
                }

                self.allTranslatedText = copyLines.joined(separator: "\n")
                self.canvasView.isLoading = false
                self.canvasView.updateRenderedBlocks(rendered)

                let extraBottom = self.canvasView.requiredExtraBottomHeight
                if extraBottom > 1 {
                    var winFrame = self.frame
                    winFrame.origin.y -= extraBottom
                    winFrame.size.height += extraBottom
                    self.setFrame(winFrame, display: true)
                    self.rootView.frame = NSRect(origin: .zero, size: winFrame.size)
                    var cvFrame = self.canvasView.frame
                    cvFrame.size.height += extraBottom
                    self.canvasView.frame = cvFrame
                }

                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
                self.statusBadge.isHidden = true
                self.compareBtn.isHidden = false
                self.copyBtn.isHidden = false
                self.passThroughBtn.isHidden = false
                self.isTranslatingDone = true
                self.scheduleToolbarAutoDim()
            } catch {
                if !Task.isCancelled {
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    self.canvasView.isLoading = false
                    self.statusBadge.frame = NSRect(x: 14, y: 6, width: 168, height: 18)
                    self.statusBadge.stringValue = "网络繁忙，请重试"
                    self.statusBadge.textColor = .systemOrange
                }
            }
        }
    }

    private func handleCopy() {
        guard !allTranslatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allTranslatedText, forType: .string)
        let emerald = NSColor(calibratedRed: 0.30, green: 0.92, blue: 0.56, alpha: 1.0)
        copyBtn.updateDisplay(title: "已复制", icon: .check, accent: emerald)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyBtn.updateDisplay(title: "复制", icon: .copy, accent: nil)
        }
    }

    private func handleTogglePassThrough() {
        isClickThrough.toggle()
        if isClickThrough {
            self.ignoresMouseEvents = true
            self.alphaValue = 0.96
            toolbarContainer.alphaValue = 0.28
        } else {
            self.ignoresMouseEvents = false
            self.alphaValue = 1.0
            toolbarContainer.alphaValue = 1.0
        }
    }

    @objc fileprivate func handleDismissOverlay() {
        InPlaceOverlayManager.shared.closeAllForWindow(self)
    }

    func dismissOverlay() {
        autoDimWorkItem?.cancel()
        translationTask?.cancel()
        translationTask = nil
        self.orderOut(nil)
        self.close()
        onCloseCallback(self)
    }
}

/// 带立体悬浮柔光阴影与磨砂内高光描边的胶囊容器
final class GlassToolbarCapsuleView: NSView {
    override var isFlipped: Bool { true }
    let contentHolder: NSView

    override init(frame frameRect: NSRect) {
        self.contentHolder = NSView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.masksToBounds = false

        // 外层柔和悬浮阴影（确保在浅色和深色网页上都有高级悬浮层次）
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        self.shadow = shadow

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: frameRect.size))
        effect.material = .hudWindow
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = frameRect.height / 2
        effect.layer?.masksToBounds = true
        effect.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 0.72).cgColor
        effect.layer?.borderWidth = 0.8
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        addSubview(effect)

        contentHolder.frame = NSRect(origin: .zero, size: frameRect.size)
        addSubview(contentHolder)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 跟踪鼠标悬停状态的根容器视图
final class OverlayRootContainerView: NSView {
    override var isFlipped: Bool { true }
    var onHoverStateChanged: ((Bool) -> Void)?
    private(set) var isMouseInside: Bool = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        onHoverStateChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        onHoverStateChanged?(false)
    }
}

/// 精致统一的「线性矢量图标 + 像素级居中文字」胶囊按钮
final class ModernPillButton: NSView {
    var onClick: (() -> Void)?
    var onHoldChanged: ((Bool) -> Void)?

    private var titleText: String
    private var iconType: UnifiedToolbarIcon
    private let isHoldMode: Bool
    private let isDestructiveHover: Bool
    private var accentColor: NSColor?

    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(
        frame: NSRect,
        title: String,
        icon: UnifiedToolbarIcon,
        isHoldMode: Bool = false,
        isDestructiveHover: Bool = false
    ) {
        self.titleText = title
        self.iconType = icon
        self.isHoldMode = isHoldMode
        self.isDestructiveHover = isDestructiveHover
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateDisplay(title: String, icon: UnifiedToolbarIcon, accent: NSColor?) {
        self.titleText = title
        self.iconType = icon
        self.accentColor = accent
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true

        if isHoldMode {
            onHoldChanged?(true)
            var keepTracking = true
            while keepTracking {
                guard let nextEvent = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
                if nextEvent.type == .leftMouseUp {
                    keepTracking = false
                }
            }
            isPressed = false
            needsDisplay = true
            onHoldChanged?(false)
        } else {
            var inside = true
            var keepTracking = true
            while keepTracking {
                guard let nextEvent = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
                let pt = convert(nextEvent.locationInWindow, from: nil)
                inside = bounds.contains(pt)
                if nextEvent.type == .leftMouseUp {
                    keepTracking = false
                }
            }
            isPressed = false
            needsDisplay = true
            if inside {
                onClick?()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }

        // 1. 悬停与按下圆角胶囊高光底色
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: (bounds.height - 1) / 2, yRadius: (bounds.height - 1) / 2)
        if isPressed {
            if isDestructiveHover {
                NSColor(calibratedRed: 0.96, green: 0.28, blue: 0.30, alpha: 0.85).setFill()
            } else if isHoldMode {
                NSColor(calibratedRed: 0.14, green: 0.58, blue: 1.0, alpha: 0.88).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.26).setFill()
            }
            pill.fill()
        } else if isHovered {
            if isDestructiveHover {
                NSColor(calibratedRed: 0.98, green: 0.32, blue: 0.34, alpha: 0.32).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.15).setFill()
            }
            pill.fill()
        }

        // 2. 计算前景色
        let fg: NSColor
        if let custom = accentColor {
            fg = custom
        } else if isDestructiveHover && isHovered && !isPressed {
            fg = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.58, alpha: 1.0)
        } else if isHovered || isPressed {
            fg = NSColor.white
        } else {
            fg = NSColor.white.withAlphaComponent(0.90)
        }

        // 3. 测量文字真实像素墨迹尺寸，与 13x13 图标作为一个整体绝对居中排列
        let font = NSFont(name: "PingFangSC-Medium", size: 11.5) ?? NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let attrStr = NSAttributedString(string: titleText, attributes: [
            .font: font,
            .foregroundColor: fg
        ])
        let ctLine = CTLineCreateWithAttributedString(attrStr)

        cg.saveGState()
        cg.textMatrix = .identity
        cg.textPosition = .zero
        let inkBounds = CTLineGetImageBounds(ctLine, cg)

        let iconBoxSize: CGFloat = 13.0
        let gap: CGFloat = 4.2
        let totalContentWidth = iconBoxSize + gap + inkBounds.width
        let startX = (bounds.width - totalContentWidth) / 2.0

        // 绘制左侧统一线性图标（垂直严格居中于按钮中心）
        let iconRect = CGRect(
            x: startX,
            y: (bounds.height - iconBoxSize) / 2.0,
            width: iconBoxSize,
            height: iconBoxSize
        )
        iconType.draw(in: iconRect, color: fg, context: cg)

        // 绘制右侧文字（墨迹中心与按钮垂直中心 bounds.midY 0 误差对齐）
        let textDrawX = startX + iconBoxSize + gap - inkBounds.minX
        let textDrawY = bounds.midY - inkBounds.midY
        cg.textPosition = CGPoint(x: textDrawX, y: textDrawY)
        CTLineDraw(ctLine, cg)
        cg.restoreGState()
    }
}

/// 羽化无痕融合原位中文画布
final class OverlayImageCanvasView: NSView {
    override var isFlipped: Bool { true }

    private let originalImage: NSImage
    private let originalCanvasSize: NSSize
    private var blocks: [RenderedReplacementBlock] = []
    private(set) var requiredExtraBottomHeight: CGFloat = 0

    var isLoading: Bool = false {
        didSet { needsDisplay = true }
    }

    var showOriginalOnly: Bool = false {
        didSet {
            if oldValue != showOriginalOnly {
                needsDisplay = true
            }
        }
    }

    init(frame: NSRect, cgImage: CGImage) {
        self.originalImage = NSImage(cgImage: cgImage, size: frame.size)
        self.originalCanvasSize = frame.size
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func rightMouseDown(with event: NSEvent) {
        if let overlayWin = self.window as? InPlaceOverlayWindow {
            overlayWin.handleDismissOverlay()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            (self.window as? InPlaceOverlayWindow)?.handleDismissOverlay()
        } else if event.modifierFlags.contains(.command) {
            self.window?.performDrag(with: event)
        }
    }

    func updateRenderedBlocks(_ newBlocks: [RenderedReplacementBlock]) {
        self.blocks = newBlocks
        var maxBottom: CGFloat = originalCanvasSize.height
        for blk in newBlocks {
            let layout = computeBlockLayout(for: blk)
            if layout.backgroundRect.maxY > maxBottom {
                maxBottom = layout.backgroundRect.maxY
            }
        }
        self.requiredExtraBottomHeight = max(0, ceil(maxBottom - originalCanvasSize.height))
        needsDisplay = true
    }

    private struct BlockLayout {
        let featherOuterRect: NSRect
        let backgroundRect: NSRect
        let textRect: NSRect
        let attributes: [NSAttributedString.Key: Any]
    }

    private func computeBlockLayout(for blk: RenderedReplacementBlock) -> BlockLayout {
        let rawRect = blk.viewRect
        let padX: CGFloat = 3.5
        let padY: CGFloat = 2.5
        let estimatedLineH = rawRect.height / CGFloat(max(1, blk.lineCount))
        let maxFont = min(32.0, max(11.5, estimatedLineH * 0.84))
        let minFont: CGFloat = 10.5

        let isHeading = (blk.lineCount == 1 && maxFont >= 17.5)
        let fontName = isHeading ? "PingFangSC-Semibold" : "PingFangSC-Medium"

        let targetWidth = max(26.0, rawRect.width + padX * 1.4)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = isHeading ? 1.0 : 2.0
        paragraphStyle.alignment = .left

        var chosenFont = NSFont.systemFont(ofSize: maxFont, weight: isHeading ? .semibold : .medium)
        var measuredRect = CGRect.zero
        var fontSize = maxFont

        while fontSize >= minFont {
            let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: isHeading ? .semibold : .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: blk.foregroundColor,
                .paragraphStyle: paragraphStyle
            ]
            let bound = (blk.translatedText as NSString).boundingRect(
                with: NSSize(width: targetWidth, height: 4000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            chosenFont = font
            measuredRect = bound
            if bound.height <= rawRect.height + padY * 2.0 {
                break
            }
            fontSize -= 0.75
        }

        let finalTextH = ceil(measuredRect.height)
        let finalBoxW = max(rawRect.width + padX * 2, min(targetWidth + padX * 2, ceil(measuredRect.width) + padX * 2))
        let finalBoxH = max(rawRect.height + padY * 2, finalTextH + padY * 2)

        let bgRect = NSRect(
            x: max(0, rawRect.minX - padX),
            y: max(0, rawRect.minY - padY),
            width: min(originalCanvasSize.width - max(0, rawRect.minX - padX), finalBoxW),
            height: finalBoxH
        )
        let outerRect = bgRect.insetBy(dx: -1.8, dy: -1.5).intersection(NSRect(x: 0, y: 0, width: originalCanvasSize.width, height: max(originalCanvasSize.height, bgRect.maxY + 4)))

        let textOffsetY = bgRect.minY + max(padY, (bgRect.height - finalTextH) / 2.0)
        let textDrawRect = NSRect(
            x: bgRect.minX + padX,
            y: textOffsetY,
            width: max(12, bgRect.width - padX * 2),
            height: finalTextH + 2
        )

        let finalAttrs: [NSAttributedString.Key: Any] = [
            .font: chosenFont,
            .foregroundColor: blk.foregroundColor,
            .paragraphStyle: paragraphStyle
        ]
        return BlockLayout(featherOuterRect: outerRect, backgroundRect: bgRect, textRect: textDrawRect, attributes: finalAttrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        let clip = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        originalImage.draw(in: NSRect(origin: .zero, size: originalCanvasSize))
        NSGraphicsContext.restoreGraphicsState()

        if !showOriginalOnly {
            let layouts = blocks.map { ($0, computeBlockLayout(for: $0)) }
            for (blk, layout) in layouts {
                let outerPatch = NSBezierPath(roundedRect: layout.featherOuterRect, xRadius: 5.5, yRadius: 5.5)
                blk.backgroundColor.withAlphaComponent(0.45).setFill()
                outerPatch.fill()

                let innerPatch = NSBezierPath(roundedRect: layout.backgroundRect, xRadius: 4.0, yRadius: 4.0)
                blk.backgroundColor.setFill()
                innerPatch.fill()
            }

            for (blk, layout) in layouts {
                (blk.translatedText as NSString).draw(
                    with: layout.textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: layout.attributes
                )
            }
        }

        let borderRect = bounds.insetBy(dx: 0.6, dy: 0.6)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 4, yRadius: 4)
        if isLoading {
            borderPath.lineWidth = 1.6
            NSColor(calibratedRed: 0.22, green: 0.68, blue: 1.0, alpha: 0.85).setStroke()
        } else {
            borderPath.lineWidth = 0.8
            NSColor(calibratedRed: 0.25, green: 0.72, blue: 1.0, alpha: 0.28).setStroke()
        }
        borderPath.stroke()
    }
}
