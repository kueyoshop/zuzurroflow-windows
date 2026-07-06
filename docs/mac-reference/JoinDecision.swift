import Foundation

/// Decide cómo unir el dictado nuevo con lo que ya hay antes del cursor,
/// a partir de los ÚLTIMOS caracteres del campo (ventana, no un solo char).
/// Lógica pura — testeable en dev-tests.
///
/// Por qué ventana: en campos web/Electron (Claude, WhatsApp Web…) la
/// lectura por Accesibilidad a veces devuelve un espacio o carácter corrido
/// donde en realidad acaba una palabra. Con una ventana, el ESPACIO se
/// decide por el último carácter tal cual (un espacio real evita duplicar),
/// pero la MAYÚSCULA se decide por el último carácter SIGNIFICATIVO
/// (saltando espacios) — así "…va mejorando " continúa en minúscula aunque
/// el campo reporte un espacio fantasma al final.
enum JoinDecision {

    static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "¿", "¡",
                                          "«", "-", "—", "/", "@", "#"]

    /// window = últimos caracteres antes del cursor ("" = campo vacío).
    static func decide(before window: String) -> (space: Bool, lowercase: Bool) {
        guard let lastRaw = window.last else { return (false, false) }

        let space = !lastRaw.isWhitespace && !lastRaw.isNewline
            && !openers.contains(lastRaw)

        // Carácter significativo: saltar espacios/tabs (no saltos de línea —
        // línea nueva = bloque nuevo = mayúscula).
        var t = Substring(window)
        while let l = t.last, l == " " || l == "\t" { t = t.dropLast() }
        guard let sig = t.last, !sig.isNewline else { return (space, false) }

        let lowercase = sig.isLetter || sig.isNumber
            || sig == "," || sig == ";" || sig == ":"
        return (space, lowercase)
    }
}
