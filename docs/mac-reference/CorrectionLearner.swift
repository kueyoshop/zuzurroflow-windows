import AppKit

/// Auto-aprendizaje de correcciones (patrón `postEditsCallbacks` extraído del
/// binario de Wispr Flow, docs/research/02 §8):
///
/// 1. Al pegar, retenemos el campo enfocado (AXUIElement) + el texto insertado.
/// 2. Al SIGUIENTE dictado, releemos el campo: si el usuario cambió a mano una
///    palabra nuestra por otra parecida (typo del ASR corregido), la aprendemos:
///    palabra corregida → diccionario con ✨, y "lo que escribimos" como
///    equivalencia para que no vuelva a pasar.
///
/// Limitación conocida: campos que no exponen su texto por Accesibilidad
/// (algunas apps Electron) no permiten aprender — se ignoran en silencio.
@MainActor
final class CorrectionLearner {

    private struct Pending {
        let element: AXUIElement
        let insertedText: String
        let timestamp: Date
    }

    private var pending: Pending?
    private var checkWorkItems: [DispatchWorkItem] = []

    /// Llamar justo después de pegar (con el campo destino aún enfocado).
    /// Programa comprobaciones a los 6/15/40s: así caza la corrección aunque
    /// el usuario envíe/limpie el campo antes del siguiente dictado (lección
    /// del caso «Menzo»: el harvest al siguiente dictado llegó tarde).
    func recordPaste(_ text: String, store: HistoryStore,
                     notify: @escaping ([(correct: String, heard: String, id: Int64)]) -> Void) {
        cancelScheduledChecks()
        guard text.count > 3, let element = FocusedFieldInspector.focusedElement() else {
            pending = nil
            return
        }
        if FocusedFieldInspector.value(of: element) == nil {
            // Truco de Chromium/Electron: activar su árbol de accesibilidad
            // a demanda (AXManualAccessibility) y reintentar en un momento.
            Self.enableManualAccessibilityOnFrontApp()
            let textCopy = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self,
                      let retry = FocusedFieldInspector.focusedElement(),
                      FocusedFieldInspector.value(of: retry) != nil else {
                    Log.info("[Dictionary] El campo no expone su texto (AX) ni con AXManualAccessibility — sin aprendizaje aquí")
                    return
                }
                Log.info("[Dictionary] Árbol AX activado (Electron) — aprendizaje disponible")
                self.pending = Pending(element: retry, insertedText: textCopy, timestamp: Date())
                self.scheduleChecks(store: store, notify: notify)
            }
            return
        }
        pending = Pending(element: element, insertedText: text, timestamp: Date())
        scheduleChecks(store: store, notify: notify)
    }

    private func scheduleChecks(store: HistoryStore,
                                notify: @escaping ([(correct: String, heard: String, id: Int64)]) -> Void) {
        for delay in [6.0, 15.0, 40.0] {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let added = self.attemptHarvest(into: store, final: false)
                    if !added.isEmpty { notify(added) }
                }
            }
            checkWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Chromium/Electron construyen su árbol AX solo si un cliente lo pide:
    /// AXManualAccessibility=true en el elemento de la APP frontal lo fuerza.
    private static func enableManualAccessibilityOnFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func cancelScheduledChecks() {
        checkWorkItems.forEach { $0.cancel() }
        checkWorkItems.removeAll()
    }

    /// Llamar al empezar el siguiente dictado (comprobación final).
    @discardableResult
    func harvestCorrections(into store: HistoryStore) -> [(correct: String, heard: String, id: Int64)] {
        let added = attemptHarvest(into: store, final: true)
        cancelScheduledChecks()
        return added
    }

    /// Núcleo: evalúa el campo y aprende si hay correcciones.
    /// `final`: si true, el pending se consume pase lo que pase.
    private func attemptHarvest(into store: HistoryStore, final: Bool) -> [(correct: String, heard: String, id: Int64)] {
        guard let pending else { return [] }
        defer { if final { self.pending = nil } }

        // Ventana razonable: correcciones hechas en los últimos 10 min.
        guard Date().timeIntervalSince(pending.timestamp) < 600 else {
            self.pending = nil
            return []
        }
        guard let current = FocusedFieldInspector.value(of: pending.element) else {
            // Campo ilegible ahora (¿ventana cerrada?): esperar a otra pasada.
            return []
        }

        // Intacto → aún sin corrección; seguir esperando.
        guard !current.contains(pending.insertedText) else { return [] }

        // ¿El campo se vació/cambió por completo (mensaje enviado)? → abandonar.
        let insertedWords = Set(pending.insertedText.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 })
        let currentLower = current.lowercased()
        let present = insertedWords.filter { currentLower.contains($0) }
        if !insertedWords.isEmpty, Double(present.count) / Double(insertedWords.count) < 0.3 {
            self.pending = nil
            cancelScheduledChecks()
            return []
        }

        let learned = Self.findCorrections(inserted: pending.insertedText, current: current)
        guard !learned.isEmpty else { return [] }

        // Aprendido: consumir el pending (una corrección por pegado).
        self.pending = nil
        cancelScheduledChecks()

        var added: [(String, String, Int64)] = []
        for (correct, heard) in learned {
            if let id = store.addDictWord(correct, replacement: heard, autoLearned: true) {
                Log.info("[Dictionary] ✨ Aprendido: «\(heard)» → «\(correct)»")
                added.append((correct, heard, id))
            }
        }
        return added
    }

    // MARK: - Detección (pura, testeable)

    /// Palabras de `inserted` que desaparecieron del campo y tienen una
    /// "gemela" nueva muy parecida en `current` → corrección manual del usuario.
    static func findCorrections(inserted: String, current: String) -> [(correct: String, heard: String)] {
        let insertedWords = words(inserted)
        let currentWords = words(current)
        let currentSet = Set(currentWords.map { $0.lowercased() })
        let insertedSet = Set(insertedWords.map { $0.lowercased() })

        // Palabras nuestras que ya no están (candidatas a "mal oídas").
        let vanished = insertedWords.filter { w in
            w.count >= 4 && !currentSet.contains(w.lowercased())
        }
        // Palabras del campo que nosotros no escribimos (candidatas a "correctas").
        let novel = currentWords.filter { w in
            w.count >= 4 && !insertedSet.contains(w.lowercased())
        }
        guard !vanished.isEmpty, !novel.isEmpty else { return [] }

        var results: [(String, String)] = []
        var usedNovel = Set<String>()
        var consumedHeard = Set<String>()

        // Pasada 1: pares adyacentes fusionados ("Cueyo Shop" → "Kueyoshop").
        let vanishedSet = Set(vanished)
        for i in 0..<insertedWords.count - 1 where results.count < 3 {
            let w1 = insertedWords[i], w2 = insertedWords[i + 1]
            guard vanishedSet.contains(w1), vanishedSet.contains(w2),
                  !consumedHeard.contains(w1), !consumedHeard.contains(w2) else { continue }
            let joined = (w1 + w2).lowercased()
            for candidate in novel where !usedNovel.contains(candidate) {
                let d = levenshtein(joined, candidate.lowercased())
                if d <= max(2, joined.count / 4) {
                    usedNovel.insert(candidate)
                    consumedHeard.insert(w1)
                    consumedHeard.insert(w2)
                    results.append((correct: candidate, heard: "\(w1) \(w2)"))
                    break
                }
            }
        }

        // Pasada 2: palabra a palabra.
        for heard in vanished where !consumedHeard.contains(heard) {
            var best: (word: String, distance: Int)?
            for candidate in novel where !usedNovel.contains(candidate) {
                let d = levenshtein(heard.lowercased(), candidate.lowercased())
                // Parecidas pero no iguales: typo de ASR corregido.
                if d > 0, d <= max(2, heard.count / 4), (best == nil || d < best!.distance) {
                    best = (candidate, d)
                }
            }
            if let best {
                usedNovel.insert(best.word)
                results.append((correct: best.word, heard: heard))
            }
            if results.count >= 3 { break }  // prudencia: máx 3 por dictado
        }
        return results
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aa = Array(a), bb = Array(b)
        if aa.isEmpty { return bb.count }
        if bb.isEmpty { return aa.count }
        var prev = Array(0...bb.count)
        var curr = [Int](repeating: 0, count: bb.count + 1)
        for i in 1...aa.count {
            curr[0] = i
            for j in 1...bb.count {
                let cost = aa[i-1] == bb[j-1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bb.count]
    }
}
