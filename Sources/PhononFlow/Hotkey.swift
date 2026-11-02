import Cocoa

/// A global hotkey: either a lone modifier key (fn, right ⌥ …) or a key + modifiers combo.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64      // required ⌘⌥⌃⇧ flags (combos only)
    var modifierOnly: Bool
    var display: String

    static let `default` = Hotkey(keyCode: 63, modifiers: 0, modifierOnly: true, display: "fn")

    static let relevantMask: UInt64 =
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    /// Modifier key codes → (flag that is set while held, display name)
    static let modifierKeys: [UInt16: (UInt64, String)] = [
        63: (CGEventFlags.maskSecondaryFn.rawValue, "fn"),
        55: (CGEventFlags.maskCommand.rawValue, "Left ⌘"),
        54: (CGEventFlags.maskCommand.rawValue, "Right ⌘"),
        58: (CGEventFlags.maskAlternate.rawValue, "Left ⌥"),
        61: (CGEventFlags.maskAlternate.rawValue, "Right ⌥"),
        59: (CGEventFlags.maskControl.rawValue, "Left ⌃"),
        62: (CGEventFlags.maskControl.rawValue, "Right ⌃"),
        56: (CGEventFlags.maskShift.rawValue, "Left ⇧"),
        60: (CGEventFlags.maskShift.rawValue, "Right ⇧"),
    ]

    static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static func symbols(_ flags: UInt64) -> String {
        var s = ""
        if flags & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if flags & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if flags & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        return s
    }

    static func load() -> Hotkey {
        if let data = UserDefaults.standard.data(forKey: "hotkey"),
           let hk = try? JSONDecoder().decode(Hotkey.self, from: data) { return hk }
        return .default
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "hotkey") }
    }
}

/// Watches the keyboard through a CGEvent tap (needs Accessibility access).
final class HotkeyMonitor {
    var hotkey: Hotkey
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Another key was pressed while a modifier-only hotkey was held (user meant a shortcut).
    var onOtherKey: () -> Void = {}
    /// Escape pressed; return true to swallow it.
    var onEscape: () -> Bool = { false }

    private var tap: CFMachPort?
    private var isDown = false
    private var captureHandler: ((Hotkey?) -> Void)?
    private var captureCandidate: UInt16?

    init(hotkey: Hotkey) { self.hotkey = hotkey }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Captures the next key / modifier pressed and returns it as a hotkey (nil = cancelled with Esc).
    func capture(_ handler: @escaping (Hotkey?) -> Void) {
        isDown = false
        captureCandidate = nil
        captureHandler = handler
    }

    func cancelCapture() { captureHandler = nil }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue

        if captureHandler != nil { return handleCapture(type: type, event: event, keyCode: keyCode, flags: flags) }

        if hotkey.modifierOnly {
            if type == .flagsChanged, keyCode == hotkey.keyCode, let (flag, _) = Hotkey.modifierKeys[keyCode] {
                let down = flags & flag != 0
                if down && !isDown { isDown = true; onPress() }
                else if !down && isDown { isDown = false; onRelease() }
                return pass
            }
            if type == .keyDown && isDown {
                isDown = false
                onOtherKey()
            }
        } else {
            if keyCode == hotkey.keyCode {
                if type == .keyDown && (flags & Hotkey.relevantMask) == hotkey.modifiers {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && !isDown {
                        isDown = true
                        onPress()
                    }
                    return nil
                }
                if type == .keyUp && isDown {
                    isDown = false
                    onRelease()
                    return nil
                }
            }
        }

        if type == .keyDown && keyCode == 53 && onEscape() { return nil }
        return pass
    }

    private func handleCapture(type: CGEventType, event: CGEvent, keyCode: UInt16, flags: UInt64) -> Unmanaged<CGEvent>? {
        switch type {
        case .flagsChanged:
            if let (flag, name) = Hotkey.modifierKeys[keyCode] {
                if flags & flag != 0 {
                    captureCandidate = keyCode
                } else if captureCandidate == keyCode {
                    finishCapture(Hotkey(keyCode: keyCode, modifiers: 0, modifierOnly: true, display: name))
                }
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            captureCandidate = nil
            let mods = flags & Hotkey.relevantMask
            if keyCode == 53 && mods == 0 { finishCapture(nil); return nil }
            let isFKey = Hotkey.specialKeys[keyCode]?.hasPrefix("F") == true
            guard mods != 0 || isFKey else { NSSound.beep(); return nil }  // bare letters would block typing
            let name = Hotkey.specialKeys[keyCode]
                ?? NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.uppercased()
                ?? "Key \(keyCode)"
            finishCapture(Hotkey(keyCode: keyCode, modifiers: mods, modifierOnly: false,
                                 display: Hotkey.symbols(mods) + name))
            return nil
        case .keyUp:
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func finishCapture(_ hk: Hotkey?) {
        let handler = captureHandler
        captureHandler = nil
        DispatchQueue.main.async { handler?(hk) }
    }
}
