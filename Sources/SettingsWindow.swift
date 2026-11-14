import Cocoa
import ServiceManagement

/// macOS 原生系统设置风格「截图秒译 · 偏好设置」面板（全 Auto Layout 精准对齐）
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    var onSettingsChanged: (() -> Void)?

    static var isMenuBarResidentEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "menubar_resident_enabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "menubar_resident_enabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "menubar_resident_enabled")
        }
    }

    private var shortcutPopUp: NSPopUpButton!
    private var secondarySwitch: NSSwitch!
    private var targetLangPopUp: NSPopUpButton!
    private var ocrSegment: NSSegmentedControl!
    private var launchAtLoginSwitch: NSSwitch!
    private var menuBarResidentSwitch: NSSwitch!
    private var permDotView: NSView!
    private var permStatusLabel: NSTextField!

    private init() {
        let rect = NSRect(x: 0, y: 0, width: 456, height: 452)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "截图秒译"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.center()

        super.init(window: win)
        buildAutoLayoutUI(in: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showSettings() {
        refreshValues()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildAutoLayoutUI(in win: NSWindow) {
        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: win.frame.size))
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .active
        win.contentView = root

        // 1. 顶部品牌头部区域
        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerContainer)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        headerContainer.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "截图秒译")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont(name: "PingFangSC-Semibold", size: 20) ?? NSFont.boldSystemFont(ofSize: 20)
        titleLabel.textColor = .labelColor
        headerContainer.addSubview(titleLabel)

        let subLabel = NSTextField(labelWithString: "框选外文，原位秒译")
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = NSFont.systemFont(ofSize: 12.5)
        subLabel.textColor = .secondaryLabelColor
        headerContainer.addSubview(subLabel)

        let startCaptureBtn = NSButton(title: "开始截图", target: self, action: #selector(handleStartCapture))
        startCaptureBtn.translatesAutoresizingMaskIntoConstraints = false
        startCaptureBtn.bezelStyle = .rounded
        startCaptureBtn.controlSize = .regular
        startCaptureBtn.keyEquivalent = "\r"
        if let sym = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil) {
            startCaptureBtn.image = sym
            startCaptureBtn.imagePosition = .imageLeading
        }
        headerContainer.addSubview(startCaptureBtn)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 34),
            headerContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            headerContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            headerContainer.heightAnchor.constraint(equalToConstant: 56),

            iconView.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: iconView.topAnchor, constant: 3),

            subLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            // 严格与「截图秒译」主标题处在同一条水平中心线上
            startCaptureBtn.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            startCaptureBtn.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            startCaptureBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        ])

        // 2. 分组卡片一：翻译与快捷键（4 个标准行）
        shortcutPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        shortcutPopUp.controlSize = .regular
        for p in HotKeyManager.presets {
            shortcutPopUp.addItem(withTitle: p.title)
        }
        shortcutPopUp.target = self
        shortcutPopUp.action = #selector(handleShortcutChanged)
        shortcutPopUp.widthAnchor.constraint(equalToConstant: 176).isActive = true

        // 备用热键右侧组合：⇧⌘2 标签 + 拨动开关
        let secRightStack = NSStackView()
        secRightStack.orientation = .horizontal
        secRightStack.alignment = .centerY
        secRightStack.spacing = 10
        let badgeLabel = NSTextField(labelWithString: "⇧ ⌘ 2")
        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        secondarySwitch = NSSwitch()
        secondarySwitch.controlSize = .small
        secondarySwitch.target = self
        secondarySwitch.action = #selector(handleSecondaryChanged)
        secRightStack.addArrangedSubview(badgeLabel)
        secRightStack.addArrangedSubview(secondarySwitch)

        targetLangPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        targetLangPopUp.controlSize = .regular
        for lang in MultiSourceTranslator.targetLanguages {
            targetLangPopUp.addItem(withTitle: lang.title)
        }
        targetLangPopUp.target = self
        targetLangPopUp.action = #selector(handleLangChanged)
        targetLangPopUp.widthAnchor.constraint(equalToConstant: 176).isActive = true

        ocrSegment = NSSegmentedControl(labels: ["极速识别", "深度多语"], trackingMode: .selectOne, target: self, action: #selector(handleOCRModeChanged))
        ocrSegment.segmentStyle = .rounded
        ocrSegment.widthAnchor.constraint(equalToConstant: 176).isActive = true

        let card1 = makeSettingsGroupCard(rows: [
            ("快捷键", shortcutPopUp),
            ("备用快捷键", secRightStack),
            ("目标语言", targetLangPopUp),
            ("识别引擎", ocrSegment)
        ])
        root.addSubview(card1)

        // 3. 分组卡片二：启动方式与系统权限（开机自启 + 菜单栏常驻 双开关 + 权限行）
        launchAtLoginSwitch = NSSwitch()
        launchAtLoginSwitch.controlSize = .small
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(handleLaunchAtLoginChanged)

        menuBarResidentSwitch = NSSwitch()
        menuBarResidentSwitch.controlSize = .small
        menuBarResidentSwitch.target = self
        menuBarResidentSwitch.action = #selector(handleMenuBarResidentChanged)

        let permRightStack = NSStackView()
        permRightStack.orientation = .horizontal
        permRightStack.alignment = .centerY
        permRightStack.spacing = 8

        permDotView = NSView()
        permDotView.translatesAutoresizingMaskIntoConstraints = false
        permDotView.wantsLayer = true
        permDotView.layer?.cornerRadius = 4
        NSLayoutConstraint.activate([
            permDotView.widthAnchor.constraint(equalToConstant: 8),
            permDotView.heightAnchor.constraint(equalToConstant: 8)
        ])

        permStatusLabel = NSTextField(labelWithString: "")
        permStatusLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)

        let openPermBtn = NSButton(title: "权限设置", target: self, action: #selector(handleOpenPermSettings))
        openPermBtn.bezelStyle = .rounded
        openPermBtn.controlSize = .small

        permRightStack.addArrangedSubview(permDotView)
        permRightStack.addArrangedSubview(permStatusLabel)
        permRightStack.addArrangedSubview(openPermBtn)

        let card2 = makeSettingsGroupCard(rows: [
            ("开机自启", launchAtLoginSwitch),
            ("菜单栏常驻", menuBarResidentSwitch),
            ("录屏权限", permRightStack)
        ])
        root.addSubview(card2)

        NSLayoutConstraint.activate([
            card1.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 18),
            card1.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            card1.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            card2.topAnchor.constraint(equalTo: card1.bottomAnchor, constant: 14),
            card2.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            card2.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24)
        ])
    }

    /// 构建标准 macOS 系统设置圆角分组卡片，每行严格水平两端对齐且垂直居中
    private func makeSettingsGroupCard(rows: [(String, NSView)]) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 0.6
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        let vStack = NSStackView()
        vStack.translatesAutoresizingMaskIntoConstraints = false
        vStack.orientation = .vertical
        vStack.spacing = 0
        vStack.alignment = .width
        card.addSubview(vStack)

        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
            vStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2),
            vStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vStack.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        ])

        for (index, (title, rightControl)) in rows.enumerated() {
            let rowView = NSView()
            rowView.translatesAutoresizingMaskIntoConstraints = false
            rowView.heightAnchor.constraint(equalToConstant: 42).isActive = true

            let titleLbl = NSTextField(labelWithString: title)
            titleLbl.translatesAutoresizingMaskIntoConstraints = false
            titleLbl.font = NSFont(name: "PingFangSC-Regular", size: 13.5) ?? NSFont.systemFont(ofSize: 13.5)
            titleLbl.textColor = .labelColor
            titleLbl.lineBreakMode = .byClipping

            rightControl.translatesAutoresizingMaskIntoConstraints = false

            rowView.addSubview(titleLbl)
            rowView.addSubview(rightControl)

            NSLayoutConstraint.activate([
                titleLbl.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 16),
                titleLbl.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),

                rightControl.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -16),
                rightControl.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
                rightControl.leadingAnchor.constraint(greaterThanOrEqualTo: titleLbl.trailingAnchor, constant: 12)
            ])

            vStack.addArrangedSubview(rowView)

            if index < rows.count - 1 {
                let sepWrap = NSView()
                sepWrap.translatesAutoresizingMaskIntoConstraints = false
                sepWrap.heightAnchor.constraint(equalToConstant: 1).isActive = true

                let line = NSView()
                line.translatesAutoresizingMaskIntoConstraints = false
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
                sepWrap.addSubview(line)

                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: sepWrap.leadingAnchor, constant: 16),
                    line.trailingAnchor.constraint(equalTo: sepWrap.trailingAnchor, constant: -16),
                    line.topAnchor.constraint(equalTo: sepWrap.topAnchor),
                    line.bottomAnchor.constraint(equalTo: sepWrap.bottomAnchor)
                ])
                vStack.addArrangedSubview(sepWrap)
            }
        }

        return card
    }

    func refreshValues() {
        if let idx = HotKeyManager.presets.firstIndex(where: { $0.id == HotKeyManager.shared.currentPresetID }) {
            shortcutPopUp.selectItem(at: idx)
        }
        secondarySwitch.state = HotKeyManager.shared.enableSecondaryCmdShift2 ? .on : .off

        if let langIdx = MultiSourceTranslator.targetLanguages.firstIndex(where: { $0.code == MultiSourceTranslator.currentTargetLanguage }) {
            targetLangPopUp.selectItem(at: langIdx)
        }
        ocrSegment.selectedSegment = OCRAndParagraphEngine.useAccurateMode ? 1 : 0
        launchAtLoginSwitch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menuBarResidentSwitch.state = Self.isMenuBarResidentEnabled ? .on : .off

        let granted = CGPreflightScreenCaptureAccess()
        permDotView.layer?.backgroundColor = (granted ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        permStatusLabel.stringValue = granted ? "已开启" : "未开启"
        permStatusLabel.textColor = granted ? .systemGreen : .systemOrange
    }

    @objc private func handleShortcutChanged() {
        let idx = shortcutPopUp.indexOfSelectedItem
        guard HotKeyManager.presets.indices.contains(idx) else { return }
        HotKeyManager.shared.currentPresetID = HotKeyManager.presets[idx].id
        onSettingsChanged?()
    }

    @objc private func handleSecondaryChanged() {
        HotKeyManager.shared.enableSecondaryCmdShift2 = (secondarySwitch.state == .on)
        onSettingsChanged?()
    }

    @objc private func handleLangChanged() {
        let idx = targetLangPopUp.indexOfSelectedItem
        guard MultiSourceTranslator.targetLanguages.indices.contains(idx) else { return }
        MultiSourceTranslator.currentTargetLanguage = MultiSourceTranslator.targetLanguages[idx].code
        onSettingsChanged?()
    }

    @objc private func handleOCRModeChanged() {
        OCRAndParagraphEngine.useAccurateMode = (ocrSegment.selectedSegment == 1)
        onSettingsChanged?()
    }

    @objc private func handleLaunchAtLoginChanged() {
        do {
            if launchAtLoginSwitch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {}
        refreshValues()
        onSettingsChanged?()
    }

    @objc private func handleMenuBarResidentChanged() {
        Self.isMenuBarResidentEnabled = (menuBarResidentSwitch.state == .on)
        onSettingsChanged?()
    }

    @objc private func handleOpenPermSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func handleStartCapture() {
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            ScreenCaptureSelector.shared.startSelection { result in
                guard let captured = result else { return }
                Task { @MainActor in
                    InPlaceOverlayManager.shared.createAndTranslate(capture: captured)
                }
            }
        }
    }
}
