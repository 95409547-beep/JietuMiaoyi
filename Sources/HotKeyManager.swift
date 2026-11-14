import Cocoa
import Carbon

/// 基于 Carbon RegisterEventHotKey 的全局快捷键管理器（无需申请辅助功能权限即可全局生效）
final class HotKeyManager {
    static let shared = HotKeyManager()

    struct ShortcutPreset: Equatable {
        let id: String
        let title: String
        let keyCode: UInt32
        let modifiers: UInt32
    }

    static let presets: [ShortcutPreset] = [
        ShortcutPreset(
            id: "opt_s",
            title: "Option + S",
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(optionKey)
        ),
        ShortcutPreset(
            id: "cmd_shift_2",
            title: "Shift + Command + 2",
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: UInt32(cmdKey | shiftKey)
        ),
        ShortcutPreset(
            id: "opt_f",
            title: "Option + F",
            keyCode: UInt32(kVK_ANSI_F),
            modifiers: UInt32(optionKey)
        ),
        ShortcutPreset(
            id: "ctrl_s",
            title: "Control + S",
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(controlKey)
        )
    ]

    var onTriggerCapture: (() -> Void)?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?

    private let userDefaultsKey = "selected_shortcut_preset_id"

    var currentPresetID: String {
        get {
            UserDefaults.standard.string(forKey: userDefaultsKey) ?? "opt_s"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
            registerConfiguredHotKeys()
        }
    }

    /// 是否同时启用备用快捷键 Shift+Command+2
    var enableSecondaryCmdShift2: Bool {
        get {
            if UserDefaults.standard.object(forKey: "enable_secondary_hotkey") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "enable_secondary_hotkey")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "enable_secondary_hotkey")
            registerConfiguredHotKeys()
        }
    }

    private init() {
        installCarbonHandlerIfNeeded()
    }

    private func installCarbonHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef = eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr && hotKeyID.signature == OSType(0x49505452) { // 'IPTR'
                DispatchQueue.main.async {
                    HotKeyManager.shared.onTriggerCapture?()
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    func registerConfiguredHotKeys() {
        unregisterAll()

        let primary = Self.presets.first(where: { $0.id == currentPresetID }) ?? Self.presets[0]
        registerSingle(id: 1, keyCode: primary.keyCode, modifiers: primary.modifiers)

        if enableSecondaryCmdShift2 && primary.id != "cmd_shift_2" {
            if let sec = Self.presets.first(where: { $0.id == "cmd_shift_2" }) {
                registerSingle(id: 2, keyCode: sec.keyCode, modifiers: sec.modifiers)
            }
        }
    }

    private func registerSingle(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x49505452), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let validRef = ref {
            hotKeyRefs.append(validRef)
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }
}
