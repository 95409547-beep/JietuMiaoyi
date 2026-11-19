import Cocoa
import CoreText
import ServiceManagement

@main
struct JietuMiaoyiMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        let resident = SettingsWindowController.isMenuBarResidentEnabled
        app.setActivationPolicy(resident ? .accessory : .regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBarMenu()
        applyMenuBarResidentMode()

        SettingsWindowController.shared.onSettingsChanged = { [weak self] in
            self?.applyMenuBarResidentMode()
            self?.rebuildMenu()
        }

        PinnedImageManager.shared.onCountChanged = { [weak self] in
            self?.rebuildMenu()
        }

        HotKeyManager.shared.onTriggerCapture = { [weak self] in
            Task { @MainActor in
                self?.triggerInPlaceCapture()
            }
        }
        HotKeyManager.shared.registerConfiguredHotKeys()
        OCRAndParagraphEngine.warmUpInBackground()

        if !UserDefaults.standard.bool(forKey: "v2_welcome_shown") || !SettingsWindowController.isMenuBarResidentEnabled {
            UserDefaults.standard.set(true, forKey: "v2_welcome_shown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                SettingsWindowController.shared.showSettings()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.showSettings()
        return true
    }

    private func applyMenuBarResidentMode() {
        let resident = SettingsWindowController.isMenuBarResidentEnabled
        statusItem.isVisible = resident
        if resident {
            NSApp.setActivationPolicy(.accessory)
            if SettingsWindowController.shared.window?.isVisible == true {
                NSApp.activate(ignoringOtherApps: true)
                SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
            }
        } else {
            // 关闭菜单栏常驻时，在程序坞保留图标，双击随时可重新唤起设置窗口
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func setupStatusBarMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.title = ""
            button.image = Self.makeMenuBarTemplateIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "截图秒译（按 Option + S 框选原位秒译）"
        }
        rebuildMenu()
    }

    /// 绘制状态栏专属单色矢量模板图标：圆角取景框 + 光学居中的翻译「文」字图案
    private static func makeMenuBarTemplateIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { box in
            guard let cgCtx = NSGraphicsContext.current?.cgContext else { return false }
            let color = NSColor.black
            color.setStroke()

            let m: CGFloat = 1.6
            let len: CGFloat = 4.4
            let rad: CGFloat = 2.0
            let lw: CGFloat = 1.55

            func corner(cx: CGFloat, cy: CGFloat, dx: CGFloat, dy: CGFloat) {
                let p = NSBezierPath()
                p.lineWidth = lw
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.move(to: NSPoint(x: cx, y: cy + dy * len))
                p.appendArc(from: NSPoint(x: cx, y: cy), to: NSPoint(x: cx + dx * len, y: cy), radius: rad)
                p.line(to: NSPoint(x: cx + dx * len, y: cy))
                p.stroke()
            }

            corner(cx: box.minX + m, cy: box.minY + m, dx: 1, dy: 1)
            corner(cx: box.maxX - m, cy: box.minY + m, dx: -1, dy: 1)
            corner(cx: box.minX + m, cy: box.maxY - m, dx: 1, dy: -1)
            corner(cx: box.maxX - m, cy: box.maxY - m, dx: -1, dy: -1)

            let font = NSFont(name: "PingFangSC-Semibold", size: 9.2) ?? NSFont.boldSystemFont(ofSize: 9.2)
            let attrStr = NSAttributedString(string: "文", attributes: [
                .font: font,
                .foregroundColor: color
            ])
            let line = CTLineCreateWithAttributedString(attrStr)
            cgCtx.saveGState()
            cgCtx.textMatrix = .identity
            cgCtx.textPosition = .zero
            let inkBounds = CTLineGetImageBounds(line, cgCtx)
            let drawX = box.midX - inkBounds.midX
            let drawY = box.midY - inkBounds.midY
            cgCtx.textPosition = CGPoint(x: drawX, y: drawY)
            CTLineDraw(line, cgCtx)
            cgCtx.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let currentPreset = HotKeyManager.presets.first(where: { $0.id == HotKeyManager.shared.currentPresetID }) ?? HotKeyManager.presets[0]
        let captureItem = NSMenuItem(
            title: "开始截图（\(currentPreset.title)）",
            action: #selector(handleStartCapture),
            keyEquivalent: ""
        )
        captureItem.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        captureItem.target = self
        menu.addItem(captureItem)

        let clearItem = NSMenuItem(
            title: "清空翻译层（Esc）",
            action: #selector(handleClearOverlays),
            keyEquivalent: ""
        )
        clearItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        clearItem.target = self
        menu.addItem(clearItem)

        let pinnedCount = PinnedImageManager.shared.count
        let clearPinsTitle = pinnedCount > 0 ? "清空全部贴图（\(pinnedCount)）" : "清空全部贴图"
        let clearPinsItem = NSMenuItem(
            title: clearPinsTitle,
            action: #selector(handleClearPins),
            keyEquivalent: ""
        )
        clearPinsItem.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
        clearPinsItem.target = self
        clearPinsItem.isEnabled = pinnedCount > 0
        menu.addItem(clearPinsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "偏好设置…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 截图秒译", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func handleStartCapture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.triggerInPlaceCapture()
        }
    }

    private func triggerInPlaceCapture() {
        ScreenCaptureSelector.shared.startSelection { result in
            guard let captured = result else { return }
            Task { @MainActor in
                switch captured.action {
                case .translate:
                    InPlaceOverlayManager.shared.createAndTranslate(capture: captured)
                case .pin:
                    PinnedImageManager.shared.pin(capture: captured)
                case .copyImage:
                    let rep = NSBitmapImageRep(cgImage: captured.croppedImage)
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    if let png = rep.representation(using: .png, properties: [:]) {
                        pb.setData(png, forType: .png)
                    } else {
                        let img = NSImage(cgImage: captured.croppedImage, size: captured.globalScreenRect.size)
                        pb.writeObjects([img])
                    }
                }
            }
        }
    }

    @objc private func handleClearOverlays() {
        InPlaceOverlayManager.shared.closeAll()
    }

    @objc private func handleClearPins() {
        PinnedImageManager.shared.closeAll()
    }

    @objc private func handleOpenSettings() {
        SettingsWindowController.shared.showSettings()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}
