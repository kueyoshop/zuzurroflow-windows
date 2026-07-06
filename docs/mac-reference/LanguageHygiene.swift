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
        let words = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
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
}
