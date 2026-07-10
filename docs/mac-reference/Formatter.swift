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

    /// Snippets: [(frase-gatillo, expansión)].
    private var snippetsProvider: (@Sendable () -> [(String, String)])?

    func setSnippetsProvider(_ provider: @escaping @Sendable () -> [(String, String)]) {
        snippetsProvider = provider
    }

    /// Contexto del campo destino (estilo Wispr): términos ya escritos donde
    /// se va a pegar + el texto en sí. Lo fija el AppDelegate AL EMPEZAR a
    /// grabar (así entra en la sesión precalentada) y caduca en cada dictado.
    private var contextTerms: [String] = []
    private var contextText: String = ""
    /// Tono según la app destino (chat casual / email formal / neutro).
    private var toneCategory: AppToneCategory = .neutral

    func setFieldContext(terms: [String], text: String) {
        contextTerms = terms
        contextText = text
    }

    func setToneCategory(_ category: AppToneCategory) {
        toneCategory = category
    }

    /// Frase-gatillo dictada → texto fijo. Case-insensitive, fronteras de
    /// palabra, gatillos más LARGOS primero (evita que uno corto pise a otro).
    /// La puntuación pegada al final del gatillo ("mi correo.") no estorba.
    static func applySnippets(to text: String, snippets: [(String, String)]) -> String {
        guard !snippets.isEmpty else { return text }
        var result = text
        for (trigger, expansion) in snippets.sorted(by: { $0.0.count > $1.0.count }) {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: trigger))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let replaced = regex.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: expansion)
            )
            if replaced != result {
                Log.info("[Snippet] «\(trigger)» expandido")
                result = replaced
            }
        }
        return result
    }

    // MARK: - Sesión precalentada EN PARALELO con la grabación
    // El grueso de la latencia era procesar las instrucciones (~700 tokens)
    // en cada dictado. Ahora la sesión se crea y precalienta MIENTRAS el
    // usuario habla — al soltar, el modelo solo tiene que generar.

    private var preparedSession: LanguageModelSession?
    private var preparedKey: String = ""

    private func sessionKey(level: CleanupLevel, dictionary: [(String, String?)]) -> String {
        level.rawValue + "|" + dictionary.map { $0.0 + ($0.1 ?? "") }.joined()
            + "|" + contextTerms.joined(separator: ",")
            + "|" + toneCategory.rawValue
    }

    /// Llamar al EMPEZAR a grabar: prepara la sesión del pulido en paralelo.
    func prepareForDictation() {
        guard SettingsStore.shared.formatterEngine == .apple,
              SettingsStore.shared.cleanupLevel != .none,
              case .available = SystemLanguageModel.default.availability else { return }

        let level = SettingsStore.shared.cleanupLevel
        let dictionary = dictionaryProvider?() ?? []
        let key = sessionKey(level: level, dictionary: dictionary)
        guard key != preparedKey || preparedSession == nil else { return }

        let instructions = FormatterPrompt.instructions(level: level)
            + FormatterPrompt.vocabularySection(dictionary)
            + FormatterPrompt.contextVocabularySection(contextTerms)
            + toneCategory.promptSection
        let session = LanguageModelSession(instructions: instructions)
        // prewarm CON prefijo: precalcula instrucciones + el arranque constante
        // del mensaje ("<dictado>\n") mientras el usuario habla — al soltar
        // solo queda procesar el transcript y GENERAR.
        session.prewarm(promptPrefix: Prompt(FormatterPrompt.transcriptOpen + "\n"))
        preparedSession = session
        preparedKey = key
    }

    // MARK: - API principal

    func format(_ rawInput: String) async -> String {
        let engine = SettingsStore.shared.formatterEngine
        let level = SettingsStore.shared.cleanupLevel
        let dictionary = dictionaryProvider?() ?? []

        // Grafías con inicial MINÚSCULA que el pipeline aplica a propósito
        // («qelara», «iPhone», «macOS»): el retoque final de mayúsculas no
        // debe pisarlas si caen tras un punto.
        let protectedCasings = Set(
            (dictionary.map(\.0) + contextTerms)
                .filter { $0.first?.isLowercase == true }
                .compactMap {
                    $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                        .first.map { String($0).lowercased() }
                })

        // Reemplazos TAMBIÉN antes del pulido: así el modelo ve la marca bien
        // escrita y no la vuelve a destrozar ("WhisperFlow"…).
        matchedDictWords.removeAll()
        var raw = applyDictionaryTracked(to: rawInput, dictionary: dictionary)

        // Muletillas fuera SIEMPRE (determinista — el modelo las quitaba
        // "a veces"). Antes del redo: un "eh" en medio rompía la alineación.
        let sinMuletillas = FormatterPrompt.stripFillers(raw)
        if sinMuletillas != raw {
            Log.info("[Formatter] muletillas eliminadas")
            raw = sinMuletillas
        }

        // Tartamudeos de palabras función ("y y", "las las", "en, en") fuera,
        // también determinista.
        let sinTartamudeos = FormatterPrompt.collapseStutters(raw)
        if sinTartamudeos != raw {
            Log.info("[Formatter] repeticiones involuntarias colapsadas")
            raw = sinTartamudeos
        }

        // (Los comandos hablados de formato se aplican DESPUÉS del modelo:
        // aplicados antes, el modelo se comía los \n simples al reescribir.)

        // Diccionario DIFUSO para nombres propios: variantes nuevas que no
        // están en "se oye como" ("Wisterflow" → "Wispr Flow"). Dos fases:
        // exactos (casing) directos, y difusos FILTRADOS por el corrector del
        // sistema — una palabra real del español/inglés nunca se convierte en
        // marca ("dictador" NO pasa a "Dictator" aunque estén a distancia 1).
        let properNouns = dictionary.map(\.0).filter { $0.first?.isUppercase == true }
        if !properNouns.isEmpty {
            let exact = FieldContext.applyTerms(to: raw, terms: properNouns,
                                                context: "", fuzzy: false)
            if exact != raw { raw = exact }

            let candidates = FieldContext.fuzzyCandidates(in: raw, terms: properNouns)
            if !candidates.isEmpty {
                let safe = await MainActor.run {
                    candidates.filter { candidate in
                        let parts = candidate.token.split(separator: " ").map(String.init)
                        // Permitido solo si ALGUNA parte NO es palabra real.
                        return !parts.allSatisfy { CorrectionLearner.isRealWord($0) }
                    }
                }
                for (token, term) in safe {
                    let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: token))\\b"
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    let range = NSRange(raw.startIndex..., in: raw)
                    let replaced = regex.stringByReplacingMatches(
                        in: raw, range: range,
                        withTemplate: NSRegularExpression.escapedTemplate(for: term))
                    if replaced != raw {
                        Log.info("[Dictionary] difuso «\(token)» → «\(term)»")
                        matchedDictWords.insert(term)
                        raw = replaced
                    }
                }
            }
        }

        // Corrección por REPETICIÓN (estilo Wispr): si el hablante re-dijo la
        // misma frase cambiando algo, gana la última versión. Determinista.
        // Las señales habladas ("que diga…") se QUITAN antes de medir — caso
        // real: "…para el lunes, que diga que, hemos decidido…" alargaba el
        // hueco y tiraba la similitud bajo el umbral.
        var redoResuelto = false
        let hadMarker = FormatterPrompt.needsBacktrackPass(rawDictation: raw)
        let redoInput = hadMarker ? FormatterPrompt.strippingBacktrackMarkers(raw) : raw
        if let redone = FormatterPrompt.resolveSpokenRedo(redoInput) {
            Log.info("[Formatter] redo por repetición resuelto (\(raw.count)→\(redone.count) chars)")
            raw = redone
            redoResuelto = true
        }

        // Términos del CAMPO destino (estilo Wispr): nombres/siglas que ya
        // están escritos donde vas a pegar se respetan sin diccionario.
        // Dos fases con guarda de palabra REAL — la difusa directa corrompía
        // dictados correctos con errores pegados antes («Media Library» →
        // «Medial Library» porque el campo contenía la grafía rota).
        if !contextTerms.isEmpty {
            raw = await applyContextTerms(to: raw)
        }

        let snippets = snippetsProvider?() ?? []

        // Los reemplazos del diccionario, contexto y snippets aplican
        // SIEMPRE, sin IA. (El diccionario ya se aplicó arriba.)
        guard engine != .off, level != .none, raw.count >= 8 else {
            var out = FormatterPrompt.applySpokenCommands(raw)
            if !contextTerms.isEmpty {
                out = await applyContextTerms(to: out)
            }
            return Self.finishTouches(Self.applySnippets(to: out, snippets: snippets),
                                      preserving: protectedCasings)
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
            return Self.finishTouches(raw, preserving: protectedCasings)
        }
        // Por si el modelo envolvió en fences, comillas o dejó las marcas.
        text = Self.stripWrapping(text)

        let dt = Date().timeIntervalSince(t0)

        // CANDADO: si el modelo añadió contenido no dictado (respondió al
        // texto en vez de corregirlo) o distorsionó la longitud → descartar.
        if let reason = FormatterPrompt.validationFailure(raw: raw, formatted: text) {
            // Registrar la REGLA que disparó y qué produjo el modelo — la
            // auditoría 2026-07-10 encontró 11/13 rechazos inauditables.
            Log.error("[Formatter] Salida RECHAZADA por validación en \(String(format: "%.2f", dt))s [\(reason)] (raw \(raw.count) chars). Candidato: «\(String(text.prefix(600)))…»")

            // Segunda oportunidad con instrucción MÍNIMA (como guardrail y
            // negativa): el modelo se desvió en ~7-13% de dictados-orden y
            // sin reintento el usuario pagaba la latencia Y recibía crudo.
            if engine == .apple,
               let retried = await minimalRetryForValidation(raw: raw),
               FormatterPrompt.validate(raw: raw, formatted: retried) {
                Log.info("[Formatter] reintento tras rechazo OK")
                text = retried
            } else {
                return Self.finishTouches(raw, preserving: protectedCasings)
            }
        }

        Log.info("[Formatter] \(engine.rawValue)/\(level.rawValue) en \(String(format: "%.2f", dt))s")

        // Comandos hablados de formato ("punto y aparte", "nueva línea",
        // "punto y seguido") — POST-modelo: el pulido ya no puede comerse el
        // salto insertado (caso real: se tragaba los \n simples).
        let conComandos = FormatterPrompt.applySpokenCommands(text)
        if conComandos != text {
            Log.info("[Formatter] comandos hablados de formato aplicados")
            text = conComandos
        }

        // Pasada de auto-corrección con MODELO: solo si había señal hablada
        // y el corte determinista no la resolvió ya.
        if engine == .apple, level != .light, hadMarker, !redoResuelto {
            if let resolved = await applyFocusedPass(
                text, instructions: FormatterPrompt.backtrackInstructions
            ), resolved.count < text.count,
               // lenient: esta pasada ENCOGE a propósito (borra el redo).
               FormatterPrompt.validate(raw: raw, formatted: resolved, lenient: true) {
                Log.info("[Formatter] pasada de auto-corrección aplicada")
                text = resolved
            }
        }

        // Listas habladas: formateo DETERMINISTA (el modelo de 3B numeraba
        // el párrafo entero o ignoraba la enumeración — fuera del circuito).
        if level != .light, FormatterPrompt.needsListPass(text) {
            if let listed = FormatterPrompt.formatSpokenList(text) {
                Log.info("[Formatter] lista numerada formateada (determinista)")
                text = listed
            } else {
                Log.info("[Formatter] enumeración detectada pero sin ítems fiables — se deja en prosa")
            }
        }

        // Series de tareas SIN numeración ("modernizar…, modificar…,
        // encontrar…") → bullets, también determinista (estilo Wispr).
        if level != .light, let bulleted = FormatterPrompt.formatSpokenBullets(text) {
            Log.info("[Formatter] serie de tareas → bullets (determinista)")
            text = bulleted
        }

        // Párrafos: partir la prosa larga en bloques legibles con línea en
        // blanco entre medias. Determinista, 0 ms — no toca palabras ni
        // añade latencia (no respeta listas/bullets, que ya traen saltos).
        if level != .light {
            let paragraphed = FormatterPrompt.paragraphize(text)
            if paragraphed != text {
                Log.info("[Formatter] prosa larga → párrafos")
                text = paragraphed
            }
        }

        // Reemplazos deterministas del diccionario personal (capa final:
        // corrige lo que ni el ASR ni el modelo escribieron bien) + términos
        // del campo (por si el modelo re-rompió una grafía) + snippets.
        text = applyDictionaryTracked(to: text, dictionary: dictionary)
        if !contextTerms.isEmpty {
            text = await applyContextTerms(to: text)
        }
        text = Self.applySnippets(to: text, snippets: snippets)

        return Self.finishTouches(text, preserving: protectedCasings)
    }

    /// Retoques deterministas FINALES — aplican en TODOS los caminos,
    /// incluidos los fallbacks a texto crudo (timeout/rechazo), que es donde
    /// más falta hacen: mayúscula tras punto (15% de los pegados de la
    /// auditoría llevaban «perfecto. haz…»), tartamudeos residuales y
    /// primera letra.
    static func finishTouches(_ input: String, preserving: Set<String> = []) -> String {
        var text = FormatterPrompt.collapseStutters(input)
        text = FormatterPrompt.capitalizeSentenceStarts(text, preserving: preserving)
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        return text
    }

    /// Términos del campo en DOS FASES con la misma guarda que el diccionario:
    /// exactos directos, difusos filtrados por el corrector del sistema — una
    /// palabra real («Media», «para») nunca se corrompe hacia un término del
    /// campo («Medial»). Caso real de la auditoría: el campo contenía «Medial
    /// Liberty» (error pegado antes) y la difusa convertía «Media Library»
    /// dictado BIEN en «Medial Library» (bucle de retroalimentación).
    private func applyContextTerms(to text: String) async -> String {
        var out = FieldContext.applyTerms(to: text, terms: contextTerms,
                                          context: contextText, fuzzy: false)
        if out != text {
            Log.info("[Contexto] transcript ajustado con términos del campo (exactos)")
        }
        let candidates = FieldContext.fuzzyCandidates(in: out, terms: contextTerms)
        if !candidates.isEmpty {
            let safe = await MainActor.run {
                candidates.filter { candidate in
                    let parts = candidate.token.split(separator: " ").map(String.init)
                    // Permitido solo si ALGUNA parte NO es palabra real.
                    return !parts.allSatisfy { CorrectionLearner.isRealWord($0) }
                }
            }
            for (token, term) in safe {
                let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: token))\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(out.startIndex..., in: out)
                let replaced = regex.stringByReplacingMatches(
                    in: out, range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: term))
                if replaced != out {
                    Log.info("[Contexto] difuso «\(token)» → «\(term)»")
                    out = replaced
                }
            }
        }
        return out
    }

    /// Palabras del diccionario que dispararon en el dictado en curso — para
    /// que el llamador persista usageCount (era un contador muerto: siempre 0).
    private var matchedDictWords: Set<String> = []

    /// Devuelve (y limpia) las palabras del diccionario usadas en el último
    /// dictado. El AppDelegate las persiste en usageCount.
    func consumeMatchedDictWords() -> [String] {
        let out = Array(matchedDictWords)
        matchedDictWords.removeAll()
        return out
    }

    private func applyDictionaryTracked(to text: String, dictionary: [(String, String?)]) -> String {
        var matched = Set<String>()
        let out = Self.applyDictionaryReplacements(to: text, dictionary: dictionary,
                                                   matched: &matched)
        matchedDictWords.formUnion(matched)
        return out
    }

    /// "se oye como" → palabra correcta, insensible a mayúsculas, con
    /// fronteras de palabra. Determinista: no depende de ningún modelo.
    /// El campo admite VARIAS variantes separadas por comas
    /// (ej: "Susurro Flow, Whisper Flow, Wispr Flow").
    static func applyDictionaryReplacements(to text: String, dictionary: [(String, String?)]) -> String {
        var matched = Set<String>()
        return applyDictionaryReplacements(to: text, dictionary: dictionary, matched: &matched)
    }

    static func applyDictionaryReplacements(to text: String, dictionary: [(String, String?)],
                                            matched: inout Set<String>) -> String {
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
                    matched.insert(word)
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
        let task = Task {
            try await session.respond(to: FormatterPrompt.userMessage(text), options: options).content
        }
        do {
            let out = try await withTimeout(seconds: 6) { try await task.value }
            let clean = Self.stripWrapping(out.trimmingCharacters(in: .whitespacesAndNewlines))
            return clean.isEmpty ? nil : clean
        } catch {
            task.cancel()   // matar la generación zombie (ocupaba el ANE)
            Log.error("[Formatter] pasada especializada falló: \(error)")
            return nil
        }
    }

    /// Pasada de listas: solo aceptar si de verdad produjo una lista.
    /// Pre-carga el modelo de Apple para que el primer dictado no pague el frío.
    func prewarm() async {
        guard SettingsStore.shared.formatterEngine == .apple else { return }
        let ok = await formatWithApple("hola", level: SettingsStore.shared.cleanupLevel, dictionary: [])
        // No mentir: con el sistema cargado el primer intento puede vencer el
        // watchdog — el log decía «precalentado» igualmente y confundía.
        Log.info(ok != nil ? "[Formatter] Apple FM precalentado"
                           : "[Formatter] prewarm no completó (frío al arrancar) — el primer dictado pagará el calentón")
    }

    // MARK: - Motor Apple (on-device)

    private func formatWithApple(_ raw: String, level: CleanupLevel,
                                 dictionary: [(String, String?)]) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else {
            Log.info("[Formatter] Apple FM no disponible en este equipo")
            return nil
        }

        // Usar la sesión PRECALENTADA durante la grabación si coincide
        // (instrucciones ya procesadas → solo falta generar). Si no, fresca.
        let key = sessionKey(level: level, dictionary: dictionary)
        let session: LanguageModelSession
        if let prepared = preparedSession, preparedKey == key, !prepared.isResponding {
            session = prepared
        } else {
            let instructions = FormatterPrompt.instructions(level: level)
                + FormatterPrompt.vocabularySection(dictionary)
                + FormatterPrompt.contextVocabularySection(contextTerms)
                + toneCategory.promptSection
            session = LanguageModelSession(instructions: instructions)
        }
        // Consumida: cada dictado usa sesión limpia (sin arrastrar contexto).
        preparedSession = nil
        preparedKey = ""

        // Tope duro de generación ALINEADO con validate() (acepta hasta
        // 1.45×+60): generar más solo pagaba latencia por texto que se iba a
        // tirar (caso real: 6.64s de ANE para un rechazo). ~1 token ≈ 3 chars.
        let cap = max(120, Int(Double(raw.count) / 3.0 * 1.5))
        let options = GenerationOptions(temperature: 0.1, maximumResponseTokens: cap)
        let prompt = FormatterPrompt.userMessage(raw)

        // Timeout ESCALADO con la longitud: 6s de base + 1s por cada 300
        // chars extra (tope 18s). El fijo de 6s CANCELABA el pulido de
        // dictados largos (caso real: 127s de audio → CancellationError →
        // texto crudo sin limpiar tras pagar 6s de espera).
        let timeout = min(18.0, 6.0 + Double(max(0, raw.count - 600)) / 300.0)
        let task = Task {
            try await session.respond(to: prompt, options: options).content
        }
        do {
            let result = try await withTimeout(seconds: timeout) { try await task.value }
            // NEGATIVA del modelo (caso real: «Lo siento, pero no puedo
            // cumplir con esa solicitud») — trató el dictado como una orden.
            // Reintento con instrucción mínima, que no da pie a "conversar".
            if Self.looksLikeRefusal(result) {
                Log.info("[Formatter] el modelo se negó — reintento con instrucción mínima…")
                if let retried = await minimalRetry(prompt: prompt, options: options, timeout: timeout),
                   !Self.looksLikeRefusal(retried) {
                    return retried
                }
                return nil   // texto crudo antes que una negativa pegada
            }
            return result
        } catch {
            // MATAR AL ZOMBIE: sin esto, la generación seguía corriendo de
            // fondo tras el timeout, ocupando el Neural Engine y encolando
            // los dictados SIGUIENTES (lentitudes en cascada).
            task.cancel()
            Log.error("[Formatter] Apple FM error: \(error)")

            // El censor de Apple dispara FALSOS POSITIVOS con español
            // inofensivo (caso real: «…garantizar una mayor tasa de éxito» →
            // guardrailViolation). Reintento con instrucción MÍNIMA (menos
            // superficie que evaluar) suele pasar; si no, texto crudo.
            if String(describing: error).lowercased().contains("guardrail") {
                Log.info("[Formatter] reintento anti-censor con instrucción mínima…")
                if let out = await minimalRetry(prompt: prompt, options: options, timeout: timeout) {
                    return out
                }
            }
            return nil
        }
    }

    /// ¿La salida es una negativa/conversación en vez de la corrección?
    static func looksLikeRefusal(_ s: String) -> Bool {
        let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return l.hasPrefix("lo siento") || l.hasPrefix("i'm sorry")
            || l.hasPrefix("i am sorry") || l.hasPrefix("perdona, ")
            || l.contains("no puedo cumplir") || l.contains("no puedo ayudar")
            || l.contains("cannot comply") || l.contains("can't comply")
            || l.contains("can't help with") || l.contains("cannot assist")
    }

    /// Reintento tras un RECHAZO de validación: misma instrucción mínima que
    /// guardrail/negativa (el síntoma es el mismo: el modelo se desvió).
    private func minimalRetryForValidation(raw: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let cap = max(120, Int(Double(raw.count) / 3.0 * 1.5))
        let options = GenerationOptions(temperature: 0.0, maximumResponseTokens: cap)
        let timeout = min(18.0, 6.0 + Double(max(0, raw.count - 600)) / 300.0)
        return await minimalRetry(prompt: FormatterPrompt.userMessage(raw),
                                  options: options, timeout: timeout)
    }

    /// Pasada de emergencia con instrucción MÍNIMA: menos superficie para el
    /// censor y sin pie a que el modelo "converse". Usada tras guardrail o
    /// negativa.
    private func minimalRetry(prompt: String, options: GenerationOptions,
                              timeout: TimeInterval) async -> String? {
        let minimal = LanguageModelSession(instructions: """
        Corrige ortografía, puntuación y mayúsculas del texto entre \
        \(FormatterPrompt.transcriptOpen) y \(FormatterPrompt.transcriptClose). \
        No cambies, añadas ni quites palabras. Devuelve solo el texto corregido.
        """)
        let retryTask = Task {
            try await minimal.respond(to: prompt, options: options).content
        }
        do {
            let out = try await withTimeout(seconds: timeout) { try await retryTask.value }
            // Sanear AQUÍ (cubre los tres llamadores): sin esto, un reintento
            // con fences/«<dictado>» o una negativa acababa pegado literal.
            let clean = Self.stripWrapping(out.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !clean.isEmpty, !Self.looksLikeRefusal(clean) else {
                Log.info("[Formatter] reintento mínimo devolvió vacío/negativa → descartado")
                return nil
            }
            Log.info("[Formatter] reintento mínimo OK")
            return clean
        } catch {
            retryTask.cancel()
            Log.error("[Formatter] reintento mínimo también falló: \(error)")
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
