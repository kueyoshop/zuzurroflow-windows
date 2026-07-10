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

        var tokens: [(text: String, sentenceStart: Bool, afterPunct: Bool)] = []
        var i = text.startIndex
        var atSentenceStart = true
        var punctSinceLast = false
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber {
                let start = i
                while i < text.endIndex, text[i].isLetter || text[i].isNumber {
                    i = text.index(after: i)
                }
                tokens.append((String(text[start..<i]), atSentenceStart, punctSinceLast))
                atSentenceStart = false
                punctSinceLast = false
            } else {
                if ".!?…:\n".contains(c) { atSentenceStart = true }
                if !c.isWhitespace { punctSinceLast = true }
                i = text.index(after: i)
            }
        }

        // Formas en minúsculas presentes en el campo: si «para» DOMINA sobre
        // «Para», la mayúscula es gramática/énfasis, no marca — no cosecharla
        // (caso real: «Para» del campo re-capitalizaba el dictado entero;
        // «EASY/NOT/MOST» eran énfasis). Conteo, no Set binario: un «Brief»
        // usado 3 veces como título no se pierde por un «brief» suelto.
        var lowerCount: [String: Int] = [:]
        var upperCount: [String: Int] = [:]
        for t in tokens {
            let n = normalize(t.text)
            if t.text.allSatisfy({ $0.isLowercase || $0.isNumber }) {
                lowerCount[n, default: 0] += 1
            } else if let f = t.text.first, f.isUppercase, !t.sentenceStart {
                upperCount[n, default: 0] += 1
            }
        }
        func lowercaseDominates(_ t: String) -> Bool {
            let n = normalize(t)
            let lower = lowerCount[n, default: 0]
            return lower > 0 && lower >= upperCount[n, default: 0]
        }

        func isCandidate(_ t: String, sentenceStart: Bool) -> Bool {
            guard t.count >= 2 else { return false }
            // Basura tipo ID (Drive/Firebase/hex): sin tope de longitud se
            // colaban «1XJSVfRHruHgthdsqhBykUHg55TE09TRs» y hasta secretos.
            guard t.count <= 20 else { return false }
            let letters = t.filter(\.isLetter)
            guard !letters.isEmpty else { return false }
            // Sigla corta toda en mayúsculas (VPS, IA, VSL) — solo si su
            // forma minúscula no es vocabulario del propio campo.
            if letters.count >= 2, t.count <= 6, letters.allSatisfy(\.isUppercase) {
                return !lowercaseDominates(t)
            }
            // Mayúscula interna: marcas/CamelCase (ZuzurroFlow, iPhone)
            if t.dropFirst().contains(where: \.isUppercase), t.contains(where: \.isLowercase) {
                return true
            }
            // Letras y dígitos mezclados (GPT4, A2, m3max) — cortos: los IDs
            // largos con dígitos («e4bc12c4e74b…», «U6pe» pasa por corto pero
            // la difusa lo ignora) no son términos.
            if t.contains(where: \.isNumber), letters.count >= 2 { return t.count <= 8 }
            // Nombre propio: Capitalizado fuera de inicio de oración, y cuya
            // forma minúscula NO circula también por el campo.
            if !sentenceStart, t.count >= 4,
               let f = t.first, f.isUppercase,
               t.dropFirst().allSatisfy({ $0.isLowercase || $0.isNumber }) {
                return !lowercaseDominates(t)
            }
            return false
        }

        var terms: [String] = []
        for (idx, entry) in tokens.enumerated() {
            guard isCandidate(entry.text, sentenceStart: entry.sentenceStart) else { continue }
            // Par "Nombre Apellido"/"Marca Palabra": el siguiente token
            // capitalizado se agrupa como término compuesto — solo si están
            // pegados de verdad (sin cruzar punto ni coma: «…de Anthony.
            // Quiero…» generaba el término absurdo «Anthony Quiero»).
            if idx + 1 < tokens.count {
                let nxtEntry = tokens[idx + 1]
                let nxt = nxtEntry.text
                if nxt.count >= 2, let f = nxt.first, f.isUppercase,
                   !nxtEntry.sentenceStart, !nxtEntry.afterPunct, nxt.count <= 20 {
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
    static func applyTerms(to transcript: String, terms: [String], context: String,
                           fuzzy: Bool = true) -> String {
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
            // Y NINGUNA puede ser palabra función: «de Anthony» → «Anthony»
            // se comía la preposición y «anthony es» → «Anthony» el verbo.
            // Difuso de par: distancia ≤1 (la fusión ya es la hipótesis).
            if idx + 1 < tokens.count,
               tokens[idx].norm.count >= 2, tokens[idx + 1].norm.count >= 2,
               !functionWords.contains(tokens[idx].norm),
               !functionWords.contains(tokens[idx + 1].norm) {
                let pairNorm = tokens[idx].norm + tokens[idx + 1].norm
                if let term = matchTerm(pairNorm, in: byNorm, contextWords: contextWords, allowFuzzy: fuzzy),
                   levenshtein(pairNorm, normalize(term)) <= 1 {
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
            if let term = matchTerm(tokens[idx].norm, in: byNorm, contextWords: contextWords, allowFuzzy: fuzzy),
               transcript[range] != Substring(term) {
                // Cambio SOLO de mayúsculas sobre palabra función («para» →
                // «Para» ×5 en un dictado real): la grafía del campo era
                // gramática/énfasis, no marca — no tocar.
                if normalize(term) == tokens[idx].norm,
                   functionWords.contains(tokens[idx].norm) {
                    continue
                }
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

    /// Candidatos DIFUSOS sin aplicar: pares (token oído → término) para que
    /// el llamador los filtre antes de reemplazar — p. ej. con el corrector
    /// del sistema, para que "dictador" (palabra real) nunca se convierta en
    /// "Dictator" aunque estén a distancia 1.
    static func fuzzyCandidates(in transcript: String, terms: [String]) -> [(token: String, term: String)] {
        guard !terms.isEmpty, !transcript.isEmpty else { return [] }
        let byNorm: [(norm: String, term: String)] = terms.compactMap {
            let n = normalize($0)
            return n.count >= 2 ? (n, $0) : nil
        }
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
        var out: [(String, String)] = []
        var seen = Set<String>()
        func add(_ token: String, _ term: String) {
            let key = token.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out.append((token, term))
        }
        for idx in 0..<tokens.count {
            // Par fusionado (stoplist de palabras función como applyTerms;
            // aquí SÍ se admite distancia 2 — los llamadores filtran cada
            // candidato con el corrector del sistema antes de aplicar, que
            // es la red real: «deserenium» → «Serenium» sigue vivo).
            if idx + 1 < tokens.count,
               tokens[idx].norm.count >= 2, tokens[idx + 1].norm.count >= 2,
               !functionWords.contains(tokens[idx].norm),
               !functionWords.contains(tokens[idx + 1].norm) {
                let pairNorm = tokens[idx].norm + tokens[idx + 1].norm
                if byNorm.first(where: { $0.norm == pairNorm }) == nil,
                   let term = matchTerm(pairNorm, in: byNorm, contextWords: []) {
                    let text = String(transcript[tokens[idx].range.lowerBound..<tokens[idx + 1].range.upperBound])
                    add(text, term)
                }
            }
            let norm = tokens[idx].norm
            // Solo difusos: los exactos van por applyTerms(fuzzy: false).
            if byNorm.first(where: { $0.norm == norm }) == nil,
               let term = matchTerm(norm, in: byNorm, contextWords: []) {
                add(String(transcript[tokens[idx].range]), term)
            }
        }
        return out
    }

    /// Palabras función que jamás deben fusionarse como primera parte de un
    /// par ni recibir el casing del campo cuando el cambio es solo de
    /// mayúsculas (casos reales: «de Anthony»→«Anthony», «para»→«Para»).
    private static let functionWords: Set<String> = [
        "de", "la", "el", "en", "al", "los", "las", "del", "un", "una",
        "y", "o", "u", "a", "que", "con", "por", "para", "se", "su", "mi",
        "no", "si", "es", "the", "of", "in", "at", "on", "to", "for",
        "and", "or", "not", "most", "with", "from", "this", "that",
    ]

    private static func matchTerm(_ norm: String,
                                  in byNorm: [(norm: String, term: String)],
                                  contextWords: Set<String>,
                                  allowFuzzy: Bool = true) -> String? {
        guard norm.count >= 2 else { return nil }
        if let hit = byNorm.first(where: { $0.norm == norm }) { return hit.term }
        // Difusa: solo palabras con entidad y que NO sean vocabulario normal
        // del propio contexto.
        guard allowFuzzy, norm.count >= 5, !contextWords.contains(norm) else { return nil }
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
