import Foundation
import FoundationModels

/// Pulido IA del transcript. Dos motores:
/// - Apple Foundation Models (on-device, ~1s, gratis, offline) — DEFAULT
/// - Claude Haiku vía kie.ai (mejor calidad, 6-10s medidos, créditos kie)
/// Cualquier fallo/timeout → devuelve el texto crudo (nunca bloquea el dictado).
actor Formatter {

    /// Diccionario personal: [(palabra correcta, "se oye como" opcional)].
    /// Lo provee el AppDelegate desde la base de datos.
    private var dictionaryProvider: (@Sendable () -> [(String, String?)])?

    func setDictionaryProvider(_ provider: @escaping @Sendable () -> [(String, String?)]) {
        dictionaryProvider = provider
    }

    // MARK: - API principal

    func format(_ rawInput: String) async -> String {
        let engine = SettingsStore.shared.formatterEngine
        let level = SettingsStore.shared.cleanupLevel
        let dictionary = dictionaryProvider?() ?? []

        // Reemplazos TAMBIÉN antes del pulido: así el modelo ve la marca bien
        // escrita y no la vuelve a destrozar ("WhisperFlow"…).
        let raw = Self.applyDictionaryReplacements(to: rawInput, dictionary: dictionary)

        // Los reemplazos del diccionario aplican SIEMPRE, incluso sin IA.
        guard engine != .off, level != .none else {
            return Self.applyDictionaryReplacements(to: raw, dictionary: dictionary)
        }
        // Textos triviales: no vale la pena la pasada.
        guard raw.count >= 8 else {
            return Self.applyDictionaryReplacements(to: raw, dictionary: dictionary)
        }

        let t0 = Date()
        let result: String?
        switch engine {
        case .apple:
            result = await formatWithApple(raw, level: level, dictionary: dictionary)
        case .kie:
            result = await formatWithKie(raw, level: level, dictionary: dictionary)
        case .off:
            result = nil
        }

        guard var text = result?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            Log.info("[Formatter] Sin resultado → texto crudo")
            return raw
        }
        // Por si el modelo envolvió en fences, comillas o dejó las marcas.
        text = Self.stripWrapping(text)

        let dt = Date().timeIntervalSince(t0)

        // CANDADO: si el modelo añadió contenido no dictado (respondió al
        // texto en vez de corregirlo) o distorsionó la longitud → descartar.
        guard FormatterPrompt.validate(raw: raw, formatted: text) else {
            Log.error("[Formatter] Salida RECHAZADA por validación (contenido inventado) en \(String(format: "%.2f", dt))s → texto crudo")
            return raw
        }

        Log.info("[Formatter] \(engine.rawValue)/\(level.rawValue) en \(String(format: "%.2f", dt))s")

        // Pasada de auto-corrección (solo Apple, medium/high): si el CRUDO
        // trae señales de "no que diga…", resolver la corrección con una
        // pasada dedicada (la pasada 1 falla con repeticiones largas).
        if engine == .apple, level != .light, FormatterPrompt.needsBacktrackPass(rawDictation: raw) {
            if let resolved = await applyFocusedPass(
                text, instructions: FormatterPrompt.backtrackInstructions
            ), resolved.count < text.count,
               FormatterPrompt.validate(raw: raw, formatted: resolved) {
                Log.info("[Formatter] pasada de auto-corrección aplicada")
                text = resolved
            }
        }

        // Pasada 2 (solo motor Apple, niveles medium/high): si hay una
        // enumeración en prosa, formatearla como lista numerada.
        if engine == .apple, level != .light, FormatterPrompt.needsListPass(text) {
            if let listed = await applyListPass(text) {
                if FormatterPrompt.validate(raw: raw, formatted: listed) {
                    Log.info("[Formatter] pasada de listas aplicada")
                    text = listed
                } else {
                    Log.info("[Formatter] pasada de listas RECHAZADA por validación")
                }
            } else {
                Log.info("[Formatter] pasada de listas sin efecto (el modelo no listó)")
            }
        }

        // Reemplazos deterministas del diccionario personal (capa final:
        // corrige lo que ni el ASR ni el modelo escribieron bien).
        text = Self.applyDictionaryReplacements(to: text, dictionary: dictionary)

        // Primera letra en mayúscula (el modelo a veces la deja en minúscula).
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        return text
    }

    /// "se oye como" → palabra correcta, insensible a mayúsculas, con
    /// fronteras de palabra. Determinista: no depende de ningún modelo.
    /// El campo admite VARIAS variantes separadas por comas
    /// (ej: "Susurro Flow, Whisper Flow, Wispr Flow").
    static func applyDictionaryReplacements(to text: String, dictionary: [(String, String?)]) -> String {
        var result = text
        for (word, sounds) in dictionary {
            guard let sounds, !sounds.isEmpty else { continue }
            for sound in sounds.split(separator: ",") {
                let s = sound.trimmingCharacters(in: .whitespaces)
                guard !s.isEmpty, s.caseInsensitiveCompare(word) != .orderedSame else { continue }
                let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: s))\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                let replaced = regex.stringByReplacingMatches(
                    in: result, range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: word)
                )
                if replaced != result {
                    Log.info("[Dictionary] «\(s)» → «\(word)»")
                    result = replaced
                }
            }
        }
        return result
    }

    /// Pasada especializada genérica: una única transformación con su propia
    /// instrucción (listas, auto-corrección…). El modelo pequeño es fiable
    /// cuando tiene UNA sola tarea.
    private func applyFocusedPass(_ text: String, instructions: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let cap = max(150, Int(Double(text.count) / 3.0 * 1.6))
        let options = GenerationOptions(temperature: 0.0, maximumResponseTokens: cap)
        do {
            let task = Task {
                try await session.respond(to: FormatterPrompt.userMessage(text), options: options).content
            }
            let out = try await withTimeout(seconds: 6) { try await task.value }
            let clean = Self.stripWrapping(out.trimmingCharacters(in: .whitespacesAndNewlines))
            return clean.isEmpty ? nil : clean
        } catch {
            Log.error("[Formatter] pasada especializada falló: \(error)")
            return nil
        }
    }

    /// Pasada de listas: solo aceptar si de verdad produjo una lista.
    private func applyListPass(_ text: String) async -> String? {
        guard let out = await applyFocusedPass(text, instructions: FormatterPrompt.listInstructions)
        else { return nil }
        return (out.contains("1.") || out.contains("1)")) ? out : nil
    }

    /// Pre-carga el modelo de Apple para que el primer dictado no pague el frío.
    func prewarm() async {
        guard SettingsStore.shared.formatterEngine == .apple else { return }
        _ = await formatWithApple("hola", level: SettingsStore.shared.cleanupLevel, dictionary: [])
        Log.info("[Formatter] Apple FM precalentado")
    }

    // MARK: - Motor Apple (on-device)

    private func formatWithApple(_ raw: String, level: CleanupLevel,
                                 dictionary: [(String, String?)]) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else {
            Log.info("[Formatter] Apple FM no disponible en este equipo")
            return nil
        }

        // Sesión fresca por dictado (el modelo del sistema queda cargado a
        // nivel de proceso; crear la sesión es barato) con el vocabulario
        // personal actualizado.
        let instructions = FormatterPrompt.instructions(level: level)
            + FormatterPrompt.vocabularySection(dictionary)
        let session = LanguageModelSession(instructions: instructions)

        // Tope duro de generación: la salida no puede ser mucho más larga que
        // la entrada (impide que el modelo "redacte" ensayos por su cuenta).
        // ~1 token ≈ 3 chars en es/en.
        let cap = max(120, Int(Double(raw.count) / 3.0 * 1.8))
        let options = GenerationOptions(temperature: 0.1, maximumResponseTokens: cap)
        let prompt = FormatterPrompt.userMessage(raw)

        do {
            let task = Task {
                try await session.respond(to: prompt, options: options).content
            }
            // Timeout 6s: dictados normales tardan ~1s; si se atasca, crudo.
            let result = try await withTimeout(seconds: 6) { try await task.value }
            return result
        } catch {
            Log.error("[Formatter] Apple FM error: \(error)")
            return nil
        }
    }

    // MARK: - Motor Kie (Claude Haiku)

    private func formatWithKie(_ raw: String, level: CleanupLevel,
                               dictionary: [(String, String?)]) async -> String? {
        guard let apiKey = SettingsStore.shared.kieApiKey else {
            Log.error("[Formatter] Sin clave de kie.ai configurada")
            return nil
        }

        var request = URLRequest(url: URL(string: "https://api.kie.ai/claude/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": max(200, Int(Double(raw.count) / 3.0 * 1.8)),
            "system": FormatterPrompt.instructions(level: level)
                + FormatterPrompt.vocabularySection(dictionary),
            "messages": [["role": "user", "content": FormatterPrompt.userMessage(raw)]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.error("[Formatter] kie HTTP \(code): \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = json["content"] as? [[String: Any]] else { return nil }
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return text.isEmpty ? nil : text
        } catch {
            Log.error("[Formatter] kie error: \(error)")
            return nil
        }
    }

    // MARK: - Utilidades

    private static func stripWrapping(_ text: String) -> String {
        var t = text
        // Marcas de datos, por si el modelo las devolvió.
        t = t.replacingOccurrences(of: FormatterPrompt.transcriptOpen, with: "")
        t = t.replacingOccurrences(of: FormatterPrompt.transcriptClose, with: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```[a-z]*\n?", with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: "```", with: "")
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.count > 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
