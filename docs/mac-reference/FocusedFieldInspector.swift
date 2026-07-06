import AppKit
import ApplicationServices

/// Mira el campo de texto enfocado vía Accesibilidad para decidir el
/// espaciado inteligente: ¿qué carácter hay justo antes del cursor?
/// Devuelve nil si el campo no expone su contenido (apps Electron opacas…).
@MainActor
enum FocusedFieldInspector {

    /// Elemento de texto enfocado ahora mismo (o nil si no hay/AX opaco).
    static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            "AXFocusedUIElement" as CFString,
                                            &focusedRef) == .success,
              let focusedRaw = focusedRef,
              CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(focusedRaw as AnyObject, to: AXUIElement.self)
    }

    /// ¿El elemento con foco es un destino de TEXTO donde pegar?
    /// Regla: decide el ROL del elemento (el rango de selección da falsos
    /// positivos — p. ej. el escritorio del Finder lo expone). El rango solo
    /// se usa cuando el rol es desconocido. Registra SIEMPRE lo que vio.
    static func focusedTextElement() -> AXUIElement? {
        guard let element = focusedElement() else {
            Log.info("[AX] Sin elemento con foco → tarjeta")
            return nil
        }

        var roleRef: CFTypeRef?
        let role: String? = (AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleRef) == .success)
            ? roleRef as? String : nil

        var rangeRef: CFTypeRef?
        let hasRange = AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &rangeRef) == .success

        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField",
                                      "AXComboBox", "AXWebArea", "AXTerminal"]

        let isText: Bool
        if let role {
            isText = textRoles.contains(role)
        } else {
            // Rol ilegible (apps opacas): el rango es la única pista.
            isText = hasRange
        }

        Log.info("[AX] foco rol=\(role ?? "?") rango=\(hasRange ? "sí" : "no") → \(isText ? "PEGAR" : "TARJETA")")
        return isText ? element : nil
    }

    /// Contenido de texto de un elemento (nil si no lo expone).
    static func value(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }
        return text
    }

    /// ÚLTIMOS caracteres antes del cursor (ventana, hasta maxChars).
    /// "" = campo vacío (sabido con certeza). nil = campo opaco (no se pudo
    /// leer → usar la heurística de continuidad).
    /// Ventana y no un solo carácter: en campos web (Claude, ProseMirror…)
    /// la lectura puntual devolvía caracteres corridos (un espacio donde
    /// acababa "mejorando") y rompía la decisión de mayúsculas.
    static func textBeforeCaret(maxChars: Int = 6) -> String? {
        guard let focused = focusedElement() else { return nil }

        // Posición del cursor (inicio de la selección).
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused,
                                            "AXSelectedTextRange" as CFString,
                                            &rangeRef) == .success,
              let rangeRaw = rangeRef,
              CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(rangeRaw as AnyObject, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0 else { return nil }
        guard range.location > 0 else { return "" }   // principio del campo

        let count = min(maxChars, range.location)

        // Vía FIABLE: pedirle a la propia app el texto del rango previo
        // (AXStringForRange) — mismas coordenadas que el rango de selección
        // (crucial en AXWebArea/Electron, donde AXValue es de toda la página).
        var param = CFRange(location: range.location - count, length: count)
        if let paramValue = AXValueCreate(.cfRange, &param) {
            var strRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                focused, "AXStringForRange" as CFString, paramValue, &strRef) == .success,
               let s = strRef as? String, !s.isEmpty {
                return s
            }
        }

        // Fallback (apps sin AXStringForRange): indexar AXValue a mano, pero
        // SOLO en roles de campo de texto nativos, donde valor y rango
        // comparten coordenadas. En web areas es mentira → nil (mejor la
        // heurística de campo opaco que caracteres falsos).
        var roleRef: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(focused, "AXRole" as CFString, &roleRef) == .success)
            ? roleRef as? String : nil
        let safeRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField",
                                      "AXComboBox", "AXTerminal"]
        guard let role, safeRoles.contains(role) else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused,
                                            "AXValue" as CFString,
                                            &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return nil }

        let ns = text as NSString
        guard range.location <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: range.location - count, length: count))
    }
}
