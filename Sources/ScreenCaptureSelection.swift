import Cocoa
import ScreenCaptureKit

/// 选区截图结果
struct CapturedRegionResult {
    let croppedImage: CGImage
    let globalScreenRect: NSRect
    let scaleFactor: CGFloat
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
        let win = RegionSelectionWindow(screen: screen, snapshot: snapshot) { [weak self] selectedTopLeftRect in
            guard let self = self else { return }
            self.activeSelectionWindow = nil

            guard let localRect = selectedTopLeftRect, localRect.width >= 8, localRect.height >= 8 else {
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

            completion(CapturedRegionResult(croppedImage: cropped, globalScreenRect: globalRect, scaleFactor: scale))
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
    private var onComplete: ((CGRect?) -> Void)?

    init(screen: NSScreen, snapshot: CGImage, onComplete: @escaping (CGRect?) -> Void) {
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
        ) { [weak self] rect in
            self?.finish(with: rect)
        }
        self.contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func cancelSelection() {
        finish(with: nil)
    }

    private func finish(with rect: CGRect?) {
        NSCursor.arrow.set()
        let cb = onComplete
        onComplete = nil
        self.orderOut(nil)
        self.close()
        cb?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finish(with: nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 现代感全屏框选画布（十字导引线 + 双层发光描边 + 四角精致白色锚点）
final class RegionSelectionCanvasView: NSView {
    override var isFlipped: Bool { true }

    private let nsSnapshot: NSImage
    private let onFinish: (CGRect?) -> Void
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var hoverPoint: NSPoint?
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, snapshot: CGImage, onFinish: @escaping (CGRect?) -> Void) {
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

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        if startPoint == nil {
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        startPoint = pt
        currentPoint = pt
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        onFinish(selectionRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish(nil)
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
            let tip = "✦  截图秒译  ｜  拖拽框选区域即可原位替换中文   ·   右键或 Esc 取消" as NSString
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

    private func drawGlassBadge(in rect: NSRect, radius: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.15, alpha: 0.82).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let strokePath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        strokePath.lineWidth = 0.8
        NSColor.white.withAlphaComponent(0.24).setStroke()
        strokePath.stroke()
    }
}
