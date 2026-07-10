import Foundation
import NaturalLanguage

/// Higiene de idioma para el modo Auto multiidioma. Lógica PURA (testeable):
/// el motor la usa para decidir qué segmentos re-transcribir forzados.
///
/// Dos síntomas distintos del mismo mal (el LID de Parakeet derrapa):
/// 1. Segmento ENTERO en el idioma equivocado → lo detecta el idioma
///    dominante del texto (apparent) y el arbitraje por mayoría.
/// 2. Deriva A MITAD de segmento ("…la editora también isa for me, como
///    siempre we have…" — caso real del log): el texto sigue siendo
///    español-dominante, así que hace falta detectar la CONTAMINACIÓN:
///    palabras funcionales inequívocas del otro idioma incrustadas.
enum LanguageHygiene {

    /// Idioma aparente de un texto (es/en) según su contenido.
    static func apparent(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .english]
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    /// Palabras funcionales INGLESAS que no existen en español (se excluyen
    /// las ambiguas: "me", "no", "he", "a", "as", "i"…).
    private static let englishFunctionWords: Set<String> = [
        "the", "we", "you", "your", "have", "has", "is", "are", "was", "were",
        "but", "with", "from", "they", "this", "that", "what", "when", "how",
        "always", "sometimes", "for", "and", "of", "to", "it", "its", "do",
        "does", "did", "will", "would", "can", "could", "should", "my", "our",
        "them", "there", "not", "be", "been", "get", "got",
        "in", "on", "at", "those", "these", "if",
        "done", "doing", "then", "than", "here", "why", "which",
        "who", "whose", "some", "any", "just",
    ]

    /// Palabras funcionales ESPAÑOLAS que no existen en inglés.
    private static let spanishFunctionWords: Set<String> = [
        "el", "la", "los", "las", "de", "del", "que", "es", "y", "por",
        "con", "para", "una", "pero", "como", "siempre", "tambien", "esta",
        "muy", "cuando", "porque", "donde", "hay", "ya", "mas", "este",
        "eso", "esto", "ser", "estar", "tener", "hacer",
    ]

    /// ¿El texto (cuyo idioma dominante es `majority`) contiene palabras
    /// funcionales incrustadas del OTRO idioma? Umbral: ≥2 en una ventana
    /// de 5 palabras, o ≥3 en total.
    static func hasForeignContamination(_ text: String, majority: NLLanguage) -> Bool {
        let foreign: Set<String>
        switch majority {
        case .spanish: foreign = englishFunctionWords
        case .english: foreign = spanishFunctionWords
        default: return false
        }
        // Guiones colapsados: «check-in»/«add-on» son anglicismos LÉXICOS
        // legítimos — troceados daban «in»/«on» funcionales y falsos rescates.
        let words = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "-", with: "")
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard words.count >= 3 else { return false }

        var total = 0
        var hits: [Int] = []
        for (idx, w) in words.enumerated() where foreign.contains(w) {
            total += 1
            hits.append(idx)
        }
        if total >= 3 { return true }
        // ¿Dos aciertos cercanos (ventana de 5)?
        for (a, b) in zip(hits, hits.dropFirst()) where b - a < 5 {
            return true
        }
        return false
    }

    /// CODE-SWITCH intra-segmento (ventana ancha): ≥2 funcionales del otro
    /// idioma en 12 tokens. Verificado contra el corpus de la auditoría
    /// definitiva: 0 falsos positivos con la jerga del usuario (adset,
    /// brief, prompt… son léxicas, no funcionales). Caza los derrapes tipo
    /// «test that he's done haciendo» que la ventana de 5 dejaba pasar.
    static func hasCodeSwitch(_ text: String, majority: NLLanguage) -> Bool {
        let foreign: Set<String>
        switch majority {
        case .spanish: foreign = englishFunctionWords
        case .english: foreign = spanishFunctionWords
        default: return false
        }
        // Guiones colapsados: «check-in»/«add-on» son anglicismos LÉXICOS
        // legítimos — troceados daban «in»/«on» funcionales y falsos rescates.
        let words = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "-", with: "")
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        var hits: [Int] = []
        for (idx, w) in words.enumerated() where foreign.contains(w) {
            hits.append(idx)
        }
        for (a, b) in zip(hits, hits.dropFirst()) where b - a < 12 {
            return true
        }
        return false
    }

    /// Firma característica de SpeechTranscriber al inventar palabras:
    /// sílabas duplicadas al final («grabaciónbación», «videosdeos»,
    /// «estecepto.cepto»). token = A+B con B ≥ 3 chars y B == sufijo de A.
    static func duplicatedSyllableNonWord(_ token: String) -> Bool {
        let t = token.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .filter { $0.isLetter }
        guard t.count >= 8 else { return false }
        let chars = Array(t)
        for bLen in 3...min(6, chars.count / 2) {
            let b = chars.suffix(bLen)
            let a = chars.dropLast(bLen)
            if a.count >= bLen, Array(a.suffix(bLen)) == Array(b) {
                return true
            }
        }
        return false
    }

    /// ¿El tramo contiene alguna palabra con la firma ST de invención?
    static func hasDuplicatedSyllableSignature(_ span: String) -> Bool {
        span.split(whereSeparator: { $0.isWhitespace })
            .contains { duplicatedSyllableNonWord(String($0)) }
    }

    // MARK: - Polaridad (inversiones de sentido entre motores)

    private static let negators: Set<String> = [
        "no", "ni", "nunca", "jamas", "sin", "tampoco",
    ]
    /// Pares peligrosos confirmados en el corpus (fonéticamente vecinos con
    /// sentido opuesto). Solo raíces frecuentes — la regla des-/de+s cubre
    /// el resto.
    private static let dangerPairs: [(String, String)] = [
        ("pagado", "apagado"), ("pagar", "apagar"), ("pago", "apago"),
        ("pagas", "apagas"), ("pague", "apague"), ("pagando", "apagando"),
    ]

    /// ¿Dos tramos alineados (uno por motor) difieren en POLARIDAD?
    /// Devuelve una descripción corta si hay señal, nil si no. Señales:
    /// (a) conteo distinto de negadores; (b) prefijo des-/de+s presente en
    /// uno y ausente en el otro («desaturado»↔«saturado» — la s colapsa);
    /// (c) pares peligrosos tipo pagar↔apagar. NUNCA se auto-corrige: el
    /// motor correcto varía (4 de PK y 4 de ST en el corpus) — solo AVISO.
    static func polarityMismatch(_ spanA: String, _ spanB: String) -> String? {
        func words(_ s: String) -> [String] {
            s.lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        }
        let a = words(spanA)
        let b = words(spanB)
        guard !a.isEmpty || !b.isEmpty else { return nil }

        let negA = a.filter { negators.contains($0) }.count
        let negB = b.filter { negators.contains($0) }.count
        if negA != negB {
            return "negación presente en un motor y no en el otro"
        }

        func desMatch(_ wa: String, _ wb: String) -> Bool {
            if wa == "des" + wb { return true }
            // «desaturado» = de + saturado (colapso de la s).
            if wb.first == "s", wa == "de" + wb { return true }
            return false
        }
        for wa in a where wa.count >= 6 {
            for wb in b where desMatch(wa, wb) || desMatch(wb, wa) {
                return "prefijo des- en un motor y no en el otro («\(wa)» ↔ «\(wb)»)"
            }
        }
        for (x, y) in dangerPairs {
            if (a.contains(x) && b.contains(y)) || (a.contains(y) && b.contains(x)) {
                return "par peligroso «\(x)» ↔ «\(y)»"
            }
        }
        return nil
    }
}
