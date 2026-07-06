import AppKit
import Carbon.HIToolbox

/// Combinación de teclas configurable por el usuario.
/// Dos formas: solo-modificador (Fn, Shift derecha… se mantiene para hablar)
/// o acorde tecla+modificadores (fn+Espacio, ⌃⌥D…).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var rawFlags: UInt64          // CGEventFlags relevantes
    var modifierOnly: Bool

    var flags: CGEventFlags { CGEventFlags(rawValue: rawFlags) }

    // MARK: - Modificadores por keycode (izq/dcha distinguidos por keycode)

    static let modifierKeyCodes: [UInt16: (flag: CGEventFlags, name: String)] = [
        54: (.maskCommand, "⌘ dcha"), 55: (.maskCommand, "⌘"),
        56: (.maskShift, "⇧"), 60: (.maskShift, "⇧ dcha"),
        58: (.maskAlternate, "⌥"), 61: (.maskAlternate, "⌥ dcha"),
        59: (.maskControl, "⌃"), 62: (.maskControl, "⌃ dcha"),
        63: (.maskSecondaryFn, "fn 🌐"),
    ]

    var modifierFlag: CGEventFlags? {
        Self.modifierKeyCodes[keyCode]?.flag
    }

    // MARK: - Presets

    static let rightShiftHold = KeyCombo(keyCode: 60, rawFlags: CGEventFlags.maskShift.rawValue, modifierOnly: true)
    static let fnHold = KeyCombo(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue, modifierOnly: true)
    static let fnSpace = KeyCombo(keyCode: 49, rawFlags: CGEventFlags.maskSecondaryFn.rawValue, modifierOnly: false)
    static let rightOptionHold = KeyCombo(keyCode: 61, rawFlags: CGEventFlags.maskAlternate.rawValue, modifierOnly: true)

    // MARK: - Nombre visible

    var displayName: String {
        if modifierOnly {
            return Self.modifierKeyCodes[keyCode]?.name ?? "tecla \(keyCode)"
        }
        var parts: [String] = []
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        parts.append(Self.keyName(keyCode))
        return parts.joined(separator: " ")
    }

    static func keyName(_ code: UInt16) -> String {
        switch code {
        case 49: return "Espacio"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 53: return "Esc"
        case 123: return "←"; case 124: return "→"
        case 125: return "↓"; case 126: return "↑"
        default: break
        }
        // Traducir por el layout activo.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "tecla \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return "tecla \(code)"
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return "tecla \(code)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
