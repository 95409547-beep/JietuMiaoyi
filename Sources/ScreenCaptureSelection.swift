import Cocoa
import ScreenCaptureKit

/// 框选完成后的执行动作
enum CaptureSelectionAction {
    case translate
    case pin
    case copyImage
}

/// 选区截图结果
struct CapturedRegionResult {
    let croppedImage: CGImage
    let globalScreenRect: NSRect
    let scaleFactor: CGFloat
    let action: CaptureSelectionAction
}

/// 负责瞬间定格屏幕并弹出高颜值框选遮罩
@MainActor
final class ScreenCaptureSelector {
    static let shared = ScreenCaptureSelector()

    private var activeSelectionWindow: RegionSelectionWindow?
    private var isCapturing = false

    func startSelection(completion: @escaping (CapturedRegionResult?) -> Void) {
        if let win = activeSelectionWindow {
            win.cancelSelection()
            activeSelectionWindow = nil
            isCapturing = false
            completion(nil)
            return
        }
        guard !isCapturing else { return }

        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        guard let screen = targetScreen else {
            completion(nil)
            return
        }

        isCapturing = true
        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()

        Task { @MainActor in
            do {
                let fullCGImage = try await Self.captureFullDisplay(displayID: displayID, pointSize: screenFrame.size, scale: scale)
                self.isCapturing = false
                self.presentSelectionWindow(on: screen, snapshot: fullCGImage, scale: scale, completion: completion)
            } catch {
                self.isCapturing = false
                self.showPermissionGuideAlert()
                completion(nil)
            }
        }
    }

    private static func captureFullDisplay(displayID: CGDirectDisplayID, pointSize: NSSize, scale: CGFloat) async throws -> CGImage {
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = shareable.displays.first(where: { $0.displayID == displayID }) ?? shareable.displays.first else {
            throw NSError(domain: "JietuMiaoyi", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到可用显示器"])
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = max(1, Int((pointSize.width * scale).rounded()))
        config.height = max(1, Int((pointSize.height * scale).rounded()))
        config.showsCursor = false
        config.capturesAudio = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func presentSelectionWindow(
        on screen: NSScreen,
        snapshot: CGImage,
        scale: CGFloat,
        completion: @escaping (CapturedRegionResult?) -> Void
    ) {
        let win = RegionSelectionWindow(screen: screen, snapshot: snapshot) { [weak self] selectedTopLeftRect, action in
            guard let self = self else { return }
            self.activeSelectionWindow = nil

            guard let localRect = selectedTopLeftRect,
                  let action = action,
                  localRect.width >= 8,
                  localRect.height >= 8 else {
                completion(nil)
                return
            }

            let actualScaleX = CGFloat(snapshot.width) / screen.frame.width
            let actualScaleY = CGFloat(snapshot.height) / screen.frame.height

            let pixelCropRect = CGRect(
                x: (localRect.origin.x * actualScaleX).rounded(.down),
                y: (localRect.origin.y * actualScaleY).rounded(.down),
                width: max(1, (localRect.width * actualScaleX).rounded(.up)),
                height: max(1, (localRect.height * actualScaleY).rounded(.up))
            ).intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))

            guard !pixelCropRect.isEmpty, let cropped = snapshot.cropping(to: pixelCropRect) else {
                completion(nil)
                return
            }

            let globalX = screen.frame.origin.x + localRect.origin.x
            let globalY = screen.frame.origin.y + (screen.frame.height - localRect.origin.y - localRect.height)
            let globalRect = NSRect(x: globalX, y: globalY, width: localRect.width, height: localRect.height)

            completion(CapturedRegionResult(
                croppedImage: cropped,
                globalScreenRect: globalRect,
                scaleFactor: scale,
                action: action
            ))
        }

        activeSelectionWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func showPermissionGuideAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "请为「截图秒译」开启屏幕录制权限"
        alert.informativeText = "只需开启一次：在「系统设置 → 隐私与安全性 → 录屏与系统录音」中打开「截图秒译」开关，即可随时框选屏幕原位秒译。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// 全屏定格框选窗口
final class RegionSelectionWindow: NSPanel {
    private var onComplete: ((CGRect?, CaptureSelectionAction?) -> Void)?
    private weak var canvasView: RegionSelectionCanvasView?

    init(screen: NSScreen, snapshot: CGImage, onComplete: @escaping (CGRect?, CaptureSelectionAction?) -> Void) {
        self.onComplete = onComplete
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver
        self.isOpaque = true
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = true
        self.isReleasedWhenClosed = false

        let view = RegionSelectionCanvasView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            snapshot: snapshot
        ) { [weak self] rect, action in
            self?.finish(with: rect, action: action)
        }
        self.canvasView = view
        self.contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func cancelSelection() {
        finish(with: nil, action: nil)
    }

    private func finish(with rect: CGRect?, action: CaptureSelectionAction?) {
        NSCursor.arrow.set()
        let cb = onComplete
        onComplete = nil
        self.orderOut(nil)
        self.close()
        cb?(rect, action)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finish(with: nil, action: nil)
            return
        }
        if let canvas = canvasView, canvas.handleKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }
}

/// 现代感全屏框选画布（十字导引线 + 双层发光描边 + 四角精致白色锚点 + 选区极简动作工具条）
final class RegionSelectionCanvasView: NSView {
    override var isFlipped: Bool { true }

    private enum ToolbarButtonKind {
        case translate
        case pin
        case copyImage
        case cancel
    }

    private struct ToolbarButtonItem {
        let kind: ToolbarButtonKind
        let title: String?
        let symbolName: String
        let rect: NSRect
        let isPrimary: Bool
    }

    private let nsSnapshot: NSImage
    private let onFinish: (CGRect?, CaptureSelectionAction?) -> Void
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var hoverPoint: NSPoint?
    private var trackingArea: NSTrackingArea?

    private var isSelectionLocked = false
    private var isDraggingSelection = false
    private var toolbarRect: NSRect = .zero
    private var toolbarButtons: [ToolbarButtonItem] = []
    private var hoveredButton: ToolbarButtonKind?

    init(frame: NSRect, snapshot: CGImage, onFinish: @escaping (CGRect?, CaptureSelectionAction?) -> Void) {
        self.nsSnapshot = NSImage(cgImage: snapshot, size: frame.size)
        self.onFinish = onFinish
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NSCursor.crosshair.set()
    }

    private var selectionRect: NSRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return NSRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(c.x - s.x),
            height: abs(c.y - s.y)
        )
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isSelectionLocked, let sel = selectionRect, sel.width >= 8, sel.height >= 8 else {
            return false
        }
        switch event.keyCode {
        case 36, 76, 49: // Return / Enter / Space
            onFinish(sel, .translate)
            return true
        case 35: // P
            onFinish(sel, .pin)
            return true
        case 8: // C
            onFinish(sel, .copyImage)
            return true
        default:
            return false
        }
    }

    private func rebuildToolbarLayout() {
        guard isSelectionLocked, let sel = selectionRect, sel.width >= 8, sel.height >= 8 else {
            toolbarRect = .zero
            toolbarButtons = []
            hoveredButton = nil
            return
        }

        let barHeight: CGFloat = 38
        let padX: CGFloat = 6
        let gap: CGFloat = 5
        let btnHeight: CGFloat = 28

        let specs: [(ToolbarButtonKind, String?, String, CGFloat, Bool)] = [
            (.translate, "翻译", "character.bubble.fill", 72, true),
            (.pin, "图钉", "pin.fill", 72, false),
            (.copyImage, "复制", "doc.on.doc", 70, false),
            (.cancel, nil, "xmark", 30, false)
        ]

        let totalButtonsWidth = specs.reduce(CGFloat(0)) { $0 + $1.3 } + gap * CGFloat(specs.count - 1)
        let barWidth = totalButtonsWidth + padX * 2

        let margin: CGFloat = 10
        var barX = sel.maxX - barWidth
        if barX < margin {
            barX = sel.minX
        }
        barX = max(margin, min(barX, bounds.width - barWidth - margin))

        let barY: CGFloat
        if sel.maxY + 10 + barHeight <= bounds.height - margin {
            barY = sel.maxY + 10
        } else if sel.minY - 10 - barHeight >= margin {
            barY = sel.minY - 10 - barHeight
        } else {
            barY = max(margin, min(sel.maxY - barHeight - 10, bounds.height - barHeight - margin))
        }

        toolbarRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)

        var items: [ToolbarButtonItem] = []
        var cursorX = barX + padX
        let btnY = barY + (barHeight - btnHeight) / 2
        for spec in specs {
            let rect = NSRect(x: cursorX, y: btnY, width: spec.3, height: btnHeight)
            items.append(ToolbarButtonItem(
                kind: spec.0,
                title: spec.1,
                symbolName: spec.2,
                rect: rect,
                isPrimary: spec.4
            ))
            cursorX += spec.3 + gap
        }
        toolbarButtons = items
    }

    private func triggerButton(_ kind: ToolbarButtonKind) {
        guard let sel = selectionRect else { return }
        switch kind {
        case .translate:
            onFinish(sel, .translate)
        case .pin:
            onFinish(sel, .pin)
        case .copyImage:
            onFinish(sel, .copyImage)
        case .cancel:
            onFinish(nil, nil)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoverPoint = pt

        if isSelectionLocked {
            let hit = toolbarButtons.first(where: { $0.rect.contains(pt) })?.kind
            if toolbarRect.contains(pt) {
                NSCursor.arrow.set()
            } else {
                NSCursor.crosshair.set()
            }
            if hit != hoveredButton {
                hoveredButton = hit
                needsDisplay = true
            }
        } else if startPoint == nil {
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        if isSelectionLocked {
            if let hit = toolbarButtons.first(where: { $0.rect.contains(pt) }) {
                triggerButton(hit.kind)
                return
            }
            if toolbarRect.contains(pt) {
                return
            }
            // 双击已选区域内部快速触发默认翻译
            if event.clickCount == 2, let sel = selectionRect, sel.contains(pt) {
                onFinish(sel, .translate)
                return
            }
        }

        // 开始全新框选
        isSelectionLocked = false
        isDraggingSelection = true
        hoveredButton = nil
        toolbarRect = .zero
        toolbarButtons = []
        startPoint = pt
        currentPoint = pt
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingSelection else { return }
        isDraggingSelection = false
        currentPoint = convert(event.locationInWindow, from: nil)

        if let sel = selectionRect, sel.width >= 8, sel.height >= 8 {
            isSelectionLocked = true
            rebuildToolbarLayout()
            let pt = convert(event.locationInWindow, from: nil)
            hoveredButton = toolbarButtons.first(where: { $0.rect.contains(pt) })?.kind
            if toolbarRect.contains(pt) {
                NSCursor.arrow.set()
            }
        } else {
            startPoint = nil
            currentPoint = nil
            isSelectionLocked = false
            toolbarRect = .zero
            toolbarButtons = []
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish(nil, nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        nsSnapshot.draw(in: bounds)

        // 柔和深色遮罩，挖空选区
        let maskPath = NSBezierPath(rect: bounds)
        if let sel = selectionRect, sel.width > 1, sel.height > 1 {
            maskPath.append(NSBezierPath(roundedRect: sel, xRadius: 3, yRadius: 3))
            maskPath.windingRule = .evenOdd
        }
        NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.10, alpha: 0.36).setFill()
        maskPath.fill()

        if let sel = selectionRect, sel.width > 1, sel.height > 1 {
            // 外层青蓝柔光描边
            let outerGlow = NSBezierPath(roundedRect: sel.insetBy(dx: -1.5, dy: -1.5), xRadius: 4.5, yRadius: 4.5)
            outerGlow.lineWidth = 2.5
            NSColor(calibratedRed: 0.22, green: 0.66, blue: 1.0, alpha: 0.55).setStroke()
            outerGlow.stroke()

            // 内层锐利亮白高光细边
            let innerBorder = NSBezierPath(roundedRect: sel.insetBy(dx: -0.5, dy: -0.5), xRadius: 3.5, yRadius: 3.5)
            innerBorder.lineWidth = 1.2
            NSColor.white.withAlphaComponent(0.95).setStroke()
            innerBorder.stroke()

            // 四角精致圆点锚点手柄
            let corners = [
                NSPoint(x: sel.minX, y: sel.minY),
                NSPoint(x: sel.maxX, y: sel.minY),
                NSPoint(x: sel.minX, y: sel.maxY),
                NSPoint(x: sel.maxX, y: sel.maxY)
            ]
            for pt in corners {
                let handleRect = NSRect(x: pt.x - 4.0, y: pt.y - 4.0, width: 8.0, height: 8.0)
                let handle = NSBezierPath(ovalIn: handleRect)
                NSColor.white.setFill()
                handle.fill()
                NSColor(calibratedRed: 0.12, green: 0.56, blue: 0.98, alpha: 1.0).setStroke()
                handle.lineWidth = 1.6
                handle.stroke()
            }

            // 精致尺寸胶囊标签
            let sizeText = " \(Int(sel.width)) × \(Int(sel.height)) " as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let txtSize = sizeText.size(withAttributes: attrs)
            let pillY = sel.minY >= 30 ? (sel.minY - 27) : (sel.maxY + 7)
            let pillRect = NSRect(x: sel.minX, y: pillY, width: txtSize.width + 12, height: 22)
            drawGlassBadge(in: pillRect, radius: 11)
            sizeText.draw(at: NSPoint(x: pillRect.minX + 6, y: pillRect.minY + 3.5), withAttributes: attrs)

            // 选区松手后浮出极简操作工具条
            if isSelectionLocked && !toolbarButtons.isEmpty {
                drawActionToolbar()
            }
        } else {
            // 鼠标移动时绘制极细微的十字辅助参考线
            if let hp = hoverPoint {
                let crossPath = NSBezierPath()
                crossPath.move(to: NSPoint(x: 0, y: hp.y))
                crossPath.line(to: NSPoint(x: bounds.width, y: hp.y))
                crossPath.move(to: NSPoint(x: hp.x, y: 0))
                crossPath.line(to: NSPoint(x: hp.x, y: bounds.height))
                crossPath.lineWidth = 0.6
                NSColor.white.withAlphaComponent(0.28).setStroke()
                crossPath.stroke()
            }

            // 顶部居中高颜值引导胶囊
            let tip = "✦  截图秒译  ｜  拖拽框选区域 · 选择翻译或图钉贴图   ·   右键或 Esc 取消" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "PingFangSC-Medium", size: 13.5) ?? NSFont.systemFont(ofSize: 13.5, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let sz = tip.size(withAttributes: attrs)
            let pillRect = NSRect(
                x: (bounds.width - sz.width - 36) / 2,
                y: 52,
                width: sz.width + 36,
                height: 36
            )
            drawGlassBadge(in: pillRect, radius: 18)
            tip.draw(at: NSPoint(x: pillRect.minX + 18, y: pillRect.minY + 8), withAttributes: attrs)
        }
    }

    private func drawActionToolbar() {
        drawGlassBadge(in: toolbarRect, radius: 11)

        let font = NSFont(name: "PingFangSC-Medium", size: 12.5) ?? NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let symConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

        for item in toolbarButtons {
            let isHovered = (hoveredButton == item.kind)
            let btnPath = NSBezierPath(roundedRect: item.rect, xRadius: 7.5, yRadius: 7.5)

            if item.isPrimary {
                let fill = isHovered
                    ? NSColor(calibratedRed: 0.18, green: 0.62, blue: 1.0, alpha: 1.0)
                    : NSColor(calibratedRed: 0.11, green: 0.52, blue: 0.96, alpha: 0.95)
                fill.setFill()
                btnPath.fill()
            } else if isHovered {
                let fill = (item.kind == .cancel)
                    ? NSColor(calibratedRed: 0.90, green: 0.28, blue: 0.26, alpha: 0.85)
                    : NSColor.white.withAlphaComponent(0.18)
                fill.setFill()
                btnPath.fill()
            }

            let fgColor = NSColor.white.withAlphaComponent(item.isPrimary || isHovered ? 1.0 : 0.90)
            let symbolImg = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(symConfig)

            if let title = item.title {
                let nsTitle = title as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: fgColor
                ]
                let titleSize = nsTitle.size(withAttributes: attrs)
                let iconSize: CGFloat = 13
                let iconGap: CGFloat = 5
                let contentWidth = iconSize + iconGap + titleSize.width
                let startX = item.rect.minX + (item.rect.width - contentWidth) / 2

                if let img = symbolImg {
                    let tinted = tintedTemplateImage(img, color: fgColor)
                    let iconRect = NSRect(
                        x: startX,
                        y: item.rect.minY + (item.rect.height - iconSize) / 2,
                        width: iconSize,
                        height: iconSize
                    )
                    tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
                }

                let textOrigin = NSPoint(
                    x: startX + iconSize + iconGap,
                    y: item.rect.minY + (item.rect.height - titleSize.height) / 2 - 0.5
                )
                nsTitle.draw(at: textOrigin, withAttributes: attrs)
            } else if let img = symbolImg {
                let tinted = tintedTemplateImage(img, color: fgColor)
                let iconSize: CGFloat = 12
                let iconRect = NSRect(
                    x: item.rect.minX + (item.rect.width - iconSize) / 2,
                    y: item.rect.minY + (item.rect.height - iconSize) / 2,
                    width: iconSize,
                    height: iconSize
                )
                tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            }
        }
    }

    private func tintedTemplateImage(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private func drawGlassBadge(in rect: NSRect, radius: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.15, alpha: 0.86).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let strokePath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        strokePath.lineWidth = 0.8
        NSColor.white.withAlphaComponent(0.24).setStroke()
        strokePath.stroke()
    }
}
