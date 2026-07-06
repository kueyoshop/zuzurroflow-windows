import AppKit
import Carbon.HIToolbox

/// Lee el texto SELECCIONADO en la app activa (para Command Mode).
/// 1º Accesibilidad (instantáneo); 2º fallback ⌘C con portapapeles
/// preservado (para apps que no exponen la selección por AX).
@MainActor
enum SelectionReader {

    static func readSelectedText() -> String? {
        // Vía AX: atributo AXSelectedText del elemento con foco.
        if let element = FocusedFieldInspector.focusedElement() {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXSelectedText" as CFString, &ref) == .success,
               let text = ref as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        // Fallback: ⌘C simulado con snapshot/restore del portapapeles.
        return copySelectionViaClipboard()
    }

    private static func copySelectionViaClipboard() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pb = NSPasteboard.general

        // Snapshot completo.
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        let markerCount = pb.changeCount
        pb.clearContents()

        // ⌘C (keycode de C según layout: C suele ser 8 en QWERTY; resolver
        // como hacemos con V sería ideal — usar 8 con fallback razonable).
        let src = CGEventSource(stateID: .privateState)
        let cKey: CGKeyCode = 8
        let down = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Espera breve a que la app escriba el portapapeles.
        let deadline = Date().addingTimeInterval(0.35)
        var text: String?
        while Date() < deadline {
            if pb.changeCount != markerCount, let s = pb.string(forType: .string), !s.isEmpty {
                text = s
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }

        // Restaurar el portapapeles original.
        pb.clearContents()
        if !saved.isEmpty {
            let items = saved.map { entries -> NSPasteboardItem in
                let it = NSPasteboardItem()
                entries.forEach { it.setData($0.1, forType: $0.0) }
                return it
            }
            pb.writeObjects(items)
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? text : nil
    }
}
