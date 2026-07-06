import Foundation

/// Contexto del campo destino (estilo Wispr): al dictar, la app mira el texto
/// que YA está escrito donde vas a pegar y respeta sus nombres propios,
/// siglas y marcas sin necesidad de tenerlos en el diccionario.
/// 1. `extractTerms`: qué términos con grafía "especial" hay en el campo.
/// 2. `applyTerms`: corrige el transcript de forma determinista con ellos.
/// Lógica pura, sin AX ni modelo — testeable en dev-tests/run-context.sh.
enum FieldContext {

    /// Máximo de contexto considerado (el final del campo = lo más reciente).
    static let maxContextChars = 6000

    // MARK: - Extracción de términos

    /// Términos "especiales" del texto ya presente en el campo:
    /// siglas (VPS), mayúsculas internas (ZuzurroFlow, iPhone), mezcla
    /// letra+dígito (GPT4) y nombres propios — capitalizados FUERA de inicio
    /// de oración (ahí la mayúscula es gramática, no nombre). Los pares
    /// adyacentes capitalizados se agrupan ("Wispr Flow", "Kueyo Shop").
    /// Devuelve los más recientes, la última grafía vista gana.
    static func extractTerms(from context: String, maxTerms: Int = 40) -> [String] {
        let text = String(context.suffix(maxContextChars))

        var tokens: [(text: String, sentenceStart: Bool)] = []
        var i = text.startIndex
        var atSentenceStart = true
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber {
                let start = i
                while i < text.endIndex, text[i].isLetter || text[i].isNumber {
                    i = text.index(after: i)
                }
                tokens.append((String(text[start..<i]), atSentenceStart))
                atSentenceStart = false
            } else {
                if ".!?…:\n".contains(c) { atSentenceStart = true }
                i = text.index(after: i)
            }
        }

        func isCandidate(_ t: String, sentenceStart: Bool) -> Bool {
            guard t.count >= 2 else { return false }
            let letters = t.filter(\.isLetter)
            guard !letters.isEmpty else { return false }
            // Sigla corta toda en mayúsculas (VPS, IA, VSL)
            if letters.count >= 2, t.count <= 6, letters.allSatisfy(\.isUppercase) {
                return true
            }
            // Mayúscula interna: marcas/CamelCase (ZuzurroFlow, iPhone)
            if t.dropFirst().contains(where: \.isUppercase), t.contains(where: \.isLowercase) {
                return true
            }
            // Letras y dígitos mezclados (GPT4, A2, m3max)
            if t.contains(where: \.isNumber), letters.count >= 2 { return true }
            // Nombre propio: Capitalizado fuera de inicio de oración
            if !sentenceStart, t.count >= 4,
               let f = t.first, f.isUppercase,
               t.dropFirst().allSatisfy({ $0.isLowercase || $0.isNumber }) {
                return true
            }
            return false
        }

        var terms: [String] = []
        for (idx, entry) in tokens.enumerated() {
            guard isCandidate(entry.text, sentenceStart: entry.sentenceStart) else { continue }
            // Par "Nombre Apellido"/"Marca Palabra": el siguiente token
            // capitalizado se agrupa como término compuesto.
            if idx + 1 < tokens.count {
                let nxt = tokens[idx + 1].text
                if nxt.count >= 2, let f = nxt.first, f.isUppercase {
                    addTerm(entry.text + " " + nxt, to: &terms)
                }
            }
            addTerm(entry.text, to: &terms)
        }
        return Array(terms.suffix(maxTerms))
    }

    private static func addTerm(_ term: String, to terms: inout [String]) {
        let key = normalize(term)
        guard key.count >= 2 else { return }
        // La aparición más reciente decide la grafía.
        if let existing = terms.firstIndex(where: { normalize($0) == key }) {
            terms.remove(at: existing)
        }
        terms.append(term)
    }

    // MARK: - Corrección del transcript

    /// Corrige el transcript con los términos del campo (determinista):
    /// - coincidencia exacta ignorando mayúsculas/acentos → grafía del campo
    ///   ("vps" → "VPS", "eduardo" → "Eduardo")
    /// - coincidencia difusa ESTRICTA (Levenshtein ≤1 con ≥5 letras, ≤2 con
    ///   ≥8) → término del campo ("cueyoshop" → "Kueyoshop")
    /// - también fusionando pares adyacentes ("cueyo shop" → "Kueyoshop")
    /// Guarda anti-falso-positivo: si la palabra dictada existe tal cual como
    /// palabra normal del contexto, no se le aplica difusa (es una palabra
    /// real, no un nombre mal oído).
    static func applyTerms(to transcript: String, terms: [String], context: String) -> String {
        guard !terms.isEmpty, !transcript.isEmpty else { return transcript }

        let byNorm: [(norm: String, term: String)] = terms.compactMap {
            let n = normalize($0)
            return n.count >= 2 ? (n, $0) : nil
        }
        let contextWords = Set(
            String(context.suffix(maxContextChars))
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )

        // Tokens del transcript con sus rangos (para cirugía de texto).
        var tokens: [(norm: String, range: Range<String.Index>)] = []
        var i = transcript.startIndex
        while i < transcript.endIndex {
            if transcript[i].isLetter || transcript[i].isNumber {
                let start = i
                while i < transcript.endIndex, transcript[i].isLetter || transcript[i].isNumber {
                    i = transcript.index(after: i)
                }
                tokens.append((normalize(String(transcript[start..<i])), start..<i))
            } else {
                i = transcript.index(after: i)
            }
        }

        var replacements: [(Range<String.Index>, String)] = []
        var consumed = Set<Int>()
        for idx in 0..<tokens.count {
            guard !consumed.contains(idx) else { continue }
            // Par fusionado (dos palabras oídas = un término del campo).
            // Ambas partes con entidad (≥2): que "a ramon" no se coma la "a".
            if idx + 1 < tokens.count,
               tokens[idx].norm.count >= 2, tokens[idx + 1].norm.count >= 2 {
                let pairNorm = tokens[idx].norm + tokens[idx + 1].norm
                if let term = matchTerm(pairNorm, in: byNorm, contextWords: contextWords) {
                    let range = tokens[idx].range.lowerBound..<tokens[idx + 1].range.upperBound
                    if transcript[range] != Substring(term) {
                        replacements.append((range, term))
                    }
                    consumed.insert(idx)
                    consumed.insert(idx + 1)
                    continue
                }
            }
            // Palabra individual.
            let range = tokens[idx].range
            if let term = matchTerm(tokens[idx].norm, in: byNorm, contextWords: contextWords),
               transcript[range] != Substring(term) {
                replacements.append((range, term))
                consumed.insert(idx)
            }
        }

        var result = transcript
        for (range, term) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: term)
        }
        return result
    }

    private static func matchTerm(_ norm: String,
                                  in byNorm: [(norm: String, term: String)],
                                  contextWords: Set<String>) -> String? {
        guard norm.count >= 2 else { return nil }
        if let hit = byNorm.first(where: { $0.norm == norm }) { return hit.term }
        // Difusa: solo palabras con entidad y que NO sean vocabulario normal
        // del propio contexto.
        guard norm.count >= 5, !contextWords.contains(norm) else { return nil }
        let maxDist = norm.count >= 8 ? 2 : 1
        var best: (dist: Int, term: String)?
        for (n, term) in byNorm {
            guard abs(n.count - norm.count) <= maxDist else { continue }
            let d = levenshtein(norm, n)
            if d > 0, d <= maxDist, best == nil || d < best!.dist {
                best = (d, term)
            }
        }
        return best?.term
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}
