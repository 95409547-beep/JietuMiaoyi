import Cocoa

/// 管理屏幕上所有「图钉置顶贴图」窗口
@MainActor
final class PinnedImageManager {
    static let shared = PinnedImageManager()

    private var pinnedWindows: [PinnedImageWindow] = []
    var onCountChanged: (() -> Void)?

    var count: Int { pinnedWindows.count }

    private init() {}

    func pin(capture: CapturedRegionResult) {
        let win = PinnedImageWindow(capture: capture) { [weak self] closedWin in
            self?.pinnedWindows.removeAll(where: { $0 === closedWin })
            self?.onCountChanged?()
        }
        pinnedWindows.append(win)
        win.orderFrontRegardless()
        onCountChanged?()
    }

    func closeAll() {
        let list = pinnedWindows
        pinnedWindows.removeAll()
        for win in list {
            win.dismissPin()
        }
        onCountChanged?()
    }
}

/// 可自由拖拽、始终置顶（跨桌面/全屏可见）的悬浮贴图窗口
final class PinnedImageWindow: NSPanel {
    private var onClosed: ((PinnedImageWindow) -> Void)?
    private var isDismissed = false

    init(capture: CapturedRegionResult, onClosed: @escaping (PinnedImageWindow) -> Void) {
        self.onClosed = onClosed
        super.init(
            contentRect: capture.globalScreenRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.acceptsMouseMovedEvents = true
        self.hidesOnDeactivate = false

        let content = PinnedImageContentView(
            frame: NSRect(origin: .zero, size: capture.globalScreenRect.size),
            cgImage: capture.croppedImage,
            onClose: { [weak self] in
                self?.dismissPin()
            },
            onCloseAll: {
                Task { @MainActor in
                    PinnedImageManager.shared.closeAll()
                }
            }
        )
        self.contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func dismissPin() {
        guard !isDismissed else { return }
        isDismissed = true
        let cb = onClosed
        onClosed = nil
        self.orderOut(nil)
        self.close()
        cb?(self)
    }
}

/// 贴图内容视图：高清渲染截图 + 任意位置一拖即走 + 悬停关闭按钮 + 右键菜单
private final class PinnedImageContentView: NSView {
    private let cgImage: CGImage
    private let nsImage: NSImage
    private let onClose: () -> Void
    private let onCloseAll: () -> Void

    private var isHovering = false
    private var isCloseHovered = false
    private var trackingArea: NSTrackingArea?
    private let closeButtonSize: CGFloat = 22
    private let closeButtonMargin: CGFloat = 7

    init(
        frame: NSRect,
        cgImage: CGImage,
        onClose: @escaping () -> Void,
        onCloseAll: @escaping () -> Void
    ) {
        self.cgImage = cgImage
        self.nsImage = NSImage(cgImage: cgImage, size: frame.size)
        self.onClose = onClose
        self.onCloseAll = onCloseAll
        super.init(frame: frame)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private var closeButtonRect: NSRect {
        NSRect(
            x: bounds.maxX - closeButtonSize - closeButtonMargin,
            y: bounds.maxY - closeButtonSize - closeButtonMargin,
            width: closeButtonSize,
            height: closeButtonSize
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        let pt = convert(event.locationInWindow, from: nil)
        isCloseHovered = closeButtonRect.contains(pt)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isCloseHovered = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let nowCloseHovered = closeButtonRect.contains(pt)
        if nowCloseHovered != isCloseHovered {
            isCloseHovered = nowCloseHovered
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if isHovering && closeButtonRect.contains(pt) {
            onClose()
            return
        }
        // 直接使用系统原生窗口拖拽，非激活态下也可一次拖走
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "复制图片", action: #selector(handleCopyImage), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "关闭此贴图", action: #selector(handleCloseSelf), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        let closeAllItem = NSMenuItem(title: "清空全部贴图", action: #selector(handleCloseAll), keyEquivalent: "")
        closeAllItem.target = self
        menu.addItem(closeAllItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func handleCopyImage() {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        } else {
            pb.writeObjects([nsImage])
        }
    }

    @objc private func handleCloseSelf() {
        onClose()
    }

    @objc private func handleCloseAll() {
        onCloseAll()
    }

    override func draw(_ dirtyRect: NSRect) {
        let cornerRadius: CGFloat = 6.0
        let clipPath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)

        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()
        nsImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        // 常态下极细微描边，确保浅色图在浅色背景上也有清晰边界；悬停时青蓝高亮
        let borderRect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: cornerRadius, yRadius: cornerRadius)
        if isHovering {
            borderPath.lineWidth = 1.8
            NSColor(calibratedRed: 0.22, green: 0.66, blue: 1.0, alpha: 0.92).setStroke()
        } else {
            borderPath.lineWidth = 1.0
            NSColor.black.withAlphaComponent(0.22).setStroke()
        }
        borderPath.stroke()

        // 悬停时显示右上角关闭按钮
        if isHovering && bounds.width >= 36 && bounds.height >= 36 {
            let btnRect = closeButtonRect
            let circle = NSBezierPath(ovalIn: btnRect)
            if isCloseHovered {
                NSColor(calibratedRed: 0.92, green: 0.28, blue: 0.26, alpha: 0.95).setFill()
            } else {
                NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.15, alpha: 0.78).setFill()
            }
            circle.fill()

            NSColor.white.withAlphaComponent(0.28).setStroke()
            circle.lineWidth = 0.8
            circle.stroke()

            let xInset: CGFloat = 6.5
            let xPath = NSBezierPath()
            xPath.lineWidth = 1.6
            xPath.lineCapStyle = .round
            xPath.move(to: NSPoint(x: btnRect.minX + xInset, y: btnRect.minY + xInset))
            xPath.line(to: NSPoint(x: btnRect.maxX - xInset, y: btnRect.maxY - xInset))
            xPath.move(to: NSPoint(x: btnRect.maxX - xInset, y: btnRect.minY + xInset))
            xPath.line(to: NSPoint(x: btnRect.minX + xInset, y: btnRect.maxY - xInset))
            NSColor.white.setStroke()
            xPath.stroke()
        }
    }
}
