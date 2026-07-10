import Foundation
import FluidAudio
import NaturalLanguage

/// Transcripción 100% local con Parakeet-TDT-0.6b-v3 vía FluidAudio
/// (CoreML sobre el Neural Engine). Multilingüe con detección de idioma
/// por frase — maneja español/inglés mezclado sin configuración.
///
/// El modelo (~1.2 GB) se descarga automáticamente la primera vez.
/// Actor: el aislamiento sustituye a los locks (requisito Swift 6).
actor TranscriptionEngine {

    enum EngineState: Equatable {
        case notLoaded
        case loading
        case ready
        case failed(String)
    }

    enum EngineError: Error {
        case notReady
    }

    private(set) var state: EngineState = .notLoaded
    private var manager: AsrManager?
    /// Aviso al usuario (inversiones de polaridad entre motores). Lo fija
    /// el AppDelegate; se invoca fuera del main actor.
    private var warningHandler: (@Sendable (String) -> Void)?

    func setWarningHandler(_ handler: @escaping @Sendable (String) -> Void) {
        warningHandler = handler
    }
    /// VAD para el modo Auto multiidioma: trocear por pausas y detectar
    /// idioma POR SEGMENTO (un solo LID por dictado marea al minoritario).
    private var vad: VadManager?

    var isReady: Bool { state == .ready }

    /// Descarga (primera vez) y carga el modelo. Idempotente: si ya está
    /// cargando o listo, no hace nada; reintenta tras un fallo.
    func loadModel() async {
        switch state {
        case .loading, .ready:
            return
        case .notLoaded, .failed:
            break
        }
        state = .loading

        Log.info("[ASR] Cargando Parakeet v3 (primera vez descarga ~1.2 GB — puede tardar varios minutos)…")
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let asrManager = AsrManager(config: .default)
            try await asrManager.loadModels(models)

            manager = asrManager
            state = .ready
            Log.info("[ASR] Modelo Parakeet v3 listo (Neural Engine)")

            // VAD (pequeño, ~2MB) para segmentar en modo Auto multiidioma.
            vad = try? await VadManager()
            Log.info("[ASR] VAD \(vad == nil ? "NO disponible" : "listo") para segmentación multiidioma")
        } catch {
            state = .failed("\(error)")
            Log.error("[ASR] Fallo cargando modelo: \(error)")
        }
    }

    /// Transcribe muestras Float32 mono 16 kHz. Devuelve texto crudo limpio.
    /// Idioma según Ajustes: fijar Español evita que trozos salgan en inglés
    /// con ruido de fondo (los anglicismos sueltos se transcriben bien igual);
    /// Auto = detección por dictado (puede mezclar idiomas si hay ruido).
    func transcribe(_ samples: [Float]) async throws -> String {
        guard state == .ready, let manager else { throw EngineError.notReady }

        // Voz baja → subirla al nivel que el ASR espera (el usuario tenía que
        // gritar). Beneficia al VAD, a Parakeet y a los rescates a la vez.
        let samples = AGC.normalize(samples)

        let mode = SettingsStore.shared.asrLanguageMode

        // MODO SOMBRA (doble motor, fase de validación): en dictados largos,
        // transcribir TODO el audio en paralelo con SpeechTranscriber (el
        // modelo nuevo de Apple) y REGISTRARLO para comparar con la salida
        // real. Sonda validada: es-ES clava el español Y el inglés embebido
        // (code-switching), 40x tiempo real. Además del registro, el
        // resultado se APROVECHA como red de seguridad de COLA PERDIDA:
        // Parakeet a veces descarta las últimas palabras del audio (caso
        // real de la auditoría: tiró ~10 palabras finales y el usuario tuvo
        // que redictarlas) — si ST tiene una cola sustancial que Parakeet
        // no, se anexa. Espera acotada: ST corre en paralelo desde el
        // principio y casi siempre ya terminó cuando se le necesita.
        let duration = Double(samples.count) / 16_000
        var shadowTask: Task<String?, Never>?
        if mode == .auto, duration > 20, SettingsStore.shared.appleRescueEnabled {
            let shadowSamples = samples
            let primary = SettingsStore.shared.asrAutoPrimary == "en" ? "en-US" : "es-ES"
            shadowTask = Task(priority: .utility) {
                let t0 = Date()
                let shadow = await AppleSpeechRescue.transcribe(
                    samples: shadowSamples, sampleRate: 16_000,
                    localeID: primary, timeout: 25)
                if let shadow {
                    Log.info(String(format: "[SOMBRA-ST %.1fs→%.2fs] «%@»",
                                    duration, Date().timeIntervalSince(t0), shadow))
                }
                return shadow
            }
        }

        // MODO AUTO multiidioma: trocear por pausas (VAD) y transcribir cada
        // segmento con su propia detección de idioma → los cambios es↔en en
        // pausas naturales se respetan. (Un LID único por dictado hacía que
        // el idioma minoritario saliera "mareado".)
        if mode == .auto, let vad,
           Double(samples.count) / 16_000 > 3.0 {   // dictados cortos: directo
            // Pausas de ≥0.4s parten segmento (los cambios de idioma ocurren
            // en pausas naturales de frase); padding para no cortar bordes.
            let segConfig = VadSegmentationConfig(
                minSilenceDuration: 0.3,
                speechPadding: 0.1
            )
            // segmentSpeech (con TIEMPOS) en vez de segmentSpeechAudio: así
            // conocemos la PAUSA antes de cada segmento — señal prosódica que
            // usamos para poner frases y párrafos (como hace Wispr).
            if let vadSegments = try? await vad.segmentSpeech(samples, config: segConfig),
               vadSegments.count > 1 {
                var segs: [(text: String, confidence: Float, chunk: [Float], gapBefore: Double)] = []
                var prevEnd: Double?
                for vs in vadSegments {
                    let startS = max(0, min(vs.startSample(sampleRate: 16_000), samples.count))
                    let endS = max(startS, min(vs.endSample(sampleRate: 16_000), samples.count))
                    guard endS - startS >= 6_400 else { prevEnd = vs.endTime; continue }   // ≥0.4s
                    let chunk = Array(samples[startS..<endS])
                    var ds = TdtDecoderState.make()
                    let r = try await manager.transcribe(chunk, decoderState: &ds, language: nil)
                    let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.mostlyNonLatin(t) {
                        // Parakeet multilingüe puede emitir OTRO alfabeto en
                        // clips cortos/ruidosos (caso real: «Т. С. Мэрис.»
                        // pegado en cirílico) — nunca es lo que se dictó.
                        Log.info("[ASR] segmento en alfabeto no latino descartado: «\(t)»")
                    } else if !t.isEmpty {
                        let gap = prevEnd.map { max(0, vs.startTime - $0) } ?? 0
                        segs.append((t, r.confidence, chunk, gap))
                    }
                    prevEnd = vs.endTime
                }
                guard !segs.isEmpty else {
                    // Ningún segmento útil → dejar caer al camino de un
                    // disparo, con la MISMA guarda de alfabeto (si los
                    // segmentos eran cirílico, el disparo único también).
                    var ds = TdtDecoderState.make()
                    let r = try await manager.transcribe(samples, decoderState: &ds, language: nil)
                    let full = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.mostlyNonLatin(full) {
                        Log.info("[ASR] fallback sin segmentos: alfabeto no latino descartado: «\(full)»")
                        return ""
                    }
                    return Self.cleaned(full)
                }

                // RESCATE ANTI-ALUCINACIÓN con el motor de Apple.
                // Parakeet no puede forzar es/en (su `language` solo filtra
                // ALFABETOS: latino vs cirílico — inútil entre dos idiomas
                // latinos; verificado en el fuente de FluidAudio). Cuando
                // alucina inglés sobre audio español, el ÚNICO modo de
                // recuperar las palabras reales es re-escuchar ese trozo con
                // SFSpeechRecognizer forzando el idioma principal a nivel
                // acústico. Ancla = idioma PRINCIPAL del usuario (Ajustes),
                // no la "mayoría" del dictado (una alucinación larga podía
                // ganar la votación). Degrada a Parakeet si falta permiso.
                var apparent: [NLLanguage?] = []
                for s in segs {
                    apparent.append(LanguageHygiene.apparent(of: s.text))
                }
                let primaryIsSpanish = SettingsStore.shared.asrAutoPrimary != "en"
                let majorityNL: NLLanguage = primaryIsSpanish ? .spanish : .english
                let guestNL: NLLanguage = primaryIsSpanish ? .english : .spanish
                let rescueLocale = primaryIsSpanish ? "es-ES" : "en-US"
                // Dictado ENTERO en el idioma invitado (cambio intencional,
                // "let's talk in English"): no tocar nada.
                let meaningful = segs.indices.filter {
                    segs[$0].text.split(separator: " ").count >= 3
                }
                let unanimousGuest = !meaningful.isEmpty && meaningful.allSatisfy {
                    apparent[$0] == guestNL
                        && !LanguageHygiene.hasForeignContamination(segs[$0].text, majority: guestNL)
                }
                let rescueOn = SettingsStore.shared.appleRescueEnabled
                // Cache de la sombra: rescate y árbitro comparten UNA espera
                // acotada (2.5s) — re-esperar sumaba hasta 5s si ST iba lento.
                var stCache: String?
                var stAwaited = false
                if unanimousGuest {
                    Log.info("[ASR] dictado íntegro en idioma invitado — se respeta sin rescate")
                } else if rescueOn {
                    // Índices sospechosos (idioma equivocado sobre el ancla).
                    let toRescue: [Int] = segs.indices.filter { i in
                        guard segs[i].text.split(separator: " ").count >= 3 else { return false }
                        let isMinority = apparent[i] != nil && apparent[i] != majorityNL
                        let contaminated = LanguageHygiene.hasForeignContamination(
                            segs[i].text, majority: majorityNL)
                        // Ventana ancha (12): caza el code-switch a mitad de
                        // segmento que la de 5 dejaba pasar («test that he's
                        // done haciendo» — 7 falsos negativos en la auditoría).
                        let codeSwitch = LanguageHygiene.hasCodeSwitch(
                            segs[i].text, majority: majorityNL)
                        return isMinority || contaminated || codeSwitch
                    }
                    if !toRescue.isEmpty {
                        // PRIMERA LÍNEA: trasplantar el tramo desde la sombra
                        // ST (audio COMPLETO, contexto léxico entero). La
                        // auditoría de 33 casos demostró que el parcheo por
                        // segmentos degrada términos («Prot», «Me Libery»,
                        // «alfaajes») porque re-escucha el trozo sin contexto;
                        // el tramo equivalente de ST no tiene ese problema.
                        // Anclas: 4-gramas de los segmentos vecinos. Sin ancla
                        // fiable o tramo sucio → fallback Apple (2ª línea).
                        var pendingApple: [Int] = []
                        if let shadowTask, !stAwaited {
                            stCache = await Self.awaitWithDeadline(shadowTask, seconds: 2.5)
                            stAwaited = true
                        }
                        if let st = stCache {
                            for i in toRescue.sorted() {
                                if let span = Self.transplantSpan(
                                       segments: segs.map(\.text), index: i, st: st),
                                   Self.spanLooksClean(span, majority: majorityNL, guest: guestNL) {
                                    Log.info("[ASR] segmento \(i + 1) TRASPLANTADO de la sombra ST: «\(span)» (antes: «\(segs[i].text)»)")
                                    segs[i].text = span
                                } else {
                                    pendingApple.append(i)
                                }
                            }
                            if !pendingApple.isEmpty {
                                Log.info("[ASR] \(pendingApple.count) segmento(s) sin ancla/tramo limpio en ST → fallback Apple")
                            }
                        } else {
                            pendingApple = toRescue
                        }

                        // SEGUNDA LÍNEA: rescate Apple por segmento, EN
                        // PARALELO (antes secuencial → sumaba segundos).
                        let jobs = pendingApple.map { (index: $0, chunk: segs[$0].chunk) }
                        let locale = rescueLocale
                        let results: [(Int, String?)] = await withTaskGroup(
                            of: (Int, String?).self
                        ) { group in
                            for job in jobs {
                                group.addTask {
                                    let r = await AppleSpeechRescue.transcribe(
                                        samples: job.chunk, sampleRate: 16_000, localeID: locale)
                                    return (job.index, r)
                                }
                            }
                            var acc: [(Int, String?)] = []
                            for await res in group { acc.append(res) }
                            return acc
                        }
                        for (i, rescued) in results {
                            guard let rt = rescued?.trimmingCharacters(in: .whitespacesAndNewlines),
                                  rt.split(separator: " ").count >= 2 else {
                                // Causa separada (la auditoría no podía
                                // distinguir permiso/assets de resultado corto).
                                if let r = rescued {
                                    Log.info("[ASR] segmento \(i + 1): rescate CORTO («\(r)») — se conserva Parakeet")
                                } else {
                                    Log.info("[ASR] segmento \(i + 1): rescate devolvió nil (motor/permiso/assets) — se conserva Parakeet")
                                }
                                continue
                            }
                            Log.info("[ASR] segmento \(i + 1) RESCATADO con Apple (\(locale)): «\(rt)» (antes: «\(segs[i].text)»)")
                            segs[i].text = rt
                        }
                    }
                }

                // Unir por PAUSAS: pausa media → fin de frase; pausa larga →
                // párrafo (línea en blanco). Da puntuación básica y párrafos
                // GRATIS, on-device, sin depender del modelo (el pulido añade
                // luego las comas internas y respeta estos saltos).
                var joined = FormatterPrompt.joinSegmentsWithPauses(
                    segs.map { (text: $0.text, gapBefore: $0.gapBefore) })
                let paras = joined.components(separatedBy: "\n\n").count
                Log.info("[ASR] Auto multiidioma: \(vadSegments.count) segmentos, \(paras) párrafo(s) por pausas")

                // ÁRBITRO PK↔ST (auditoría definitiva, 41 casos): con la
                // sombra disponible, (a) OMISIONES INTERIORES — cláusulas que
                // Parakeet perdió en silencio (el fallo más caro del corpus:
                // hasta ~40% de un dictado) se trasplantan de ST, solo en
                // dictados ≥40s; (b) POLARIDAD — si los motores se
                // contradicen en una negación/prefijo des-, se AVISA al
                // usuario (jamás auto-corregir: el motor correcto varía);
                // (c) COLA PERDIDA como hasta ahora.
                if let shadowTask {
                    if !stAwaited {
                        // Espera ESCALONADA: en 20-40s la sombra es red de
                        // seguridad secundaria (cola/polaridad; la única cola
                        // perdida real del corpus fue a 69.8s) — no vale 2.5s
                        // de espera. En ≥40s sí: ahí viven las omisiones.
                        let deadline = duration >= 40 ? 2.5 : 1.2
                        stCache = await Self.awaitWithDeadline(shadowTask, seconds: deadline)
                        stAwaited = true
                    }
                    if let st = stCache {
                        let arb = Self.arbitrate(pk: joined, st: st,
                                                 allowSplices: duration >= 40,
                                                 majority: majorityNL, guest: guestNL)
                        if arb.splices > 0 {
                            Log.info("[ASR] árbitro: \(arb.splices) omisión(es) interior(es) trasplantada(s) de ST")
                            joined = arb.text
                        }
                        if !arb.warnings.isEmpty {
                            for w in arb.warnings {
                                Log.info("[ASR] ⚠️ polaridad: \(w)")
                            }
                            // UNA llamada con todo: dos toasts seguidos se
                            // pisaban y el usuario no veía el primero.
                            warningHandler?(arb.warnings.joined(separator: "  ·  "))
                        }
                        if let completed = Self.appendLostTail(parakeet: joined, st: st) {
                            Log.info("[ASR] cola perdida recuperada por ST: «…\(String(completed.suffix(90)))»")
                            joined = completed
                        }
                    }
                }
                return Self.cleaned(joined)
            }
        }

        let language: Language?
        switch mode {
        case .auto: language = nil
        case .es: language = .spanish
        case .en: language = .english
        }

        // Estado del decodificador fresco por dictado: cada utterance es
        // independiente, sin arrastrar contexto de la anterior.
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: language)
        var text = result.text
        if Self.mostlyNonLatin(text) {
            // Alucinación de alfabeto en clip corto/ruidoso («Т. С. Мэрис.»):
            // mejor "no se oyó nada" que pegar cirílico.
            Log.info("[ASR] dictado en alfabeto no latino descartado: «\(text)»")
            text = ""
        }
        if let shadowTask, !text.isEmpty {
            if let st = await Self.awaitWithDeadline(shadowTask, seconds: 2.5),
               let completed = Self.appendLostTail(parakeet: text, st: st) {
                Log.info("[ASR] cola perdida recuperada por ST: «…\(String(completed.suffix(90)))»")
                text = completed
            }
        }
        return Self.cleaned(text)
    }

    /// Limpieza mínima determinística (el pulido de verdad es la Fase 7).
    static func cleaned(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("  ") {
            t = t.replacingOccurrences(of: "  ", with: " ")
        }
        return t
    }

    /// ¿La mayoría de las letras están fuera del alfabeto latino? Parakeet
    /// multilingüe puede emitir cirílico/otros en clips cortos o con ruido.
    static func mostlyNonLatin(_ s: String) -> Bool {
        var latin = 0, other = 0
        for u in s.unicodeScalars where u.properties.isAlphabetic {
            if u.value < 0x250 { latin += 1 } else { other += 1 }
        }
        return other >= 3 && other > latin
    }

    /// Espera ACOTADA sobre la tarea sombra: si ST no ha terminado en
    /// `seconds`, seguimos sin él (la sombra sigue y registrará su log igual).
    /// OJO: nada de withTaskGroup aquí — el grupo espera implícitamente a
    /// TODOS sus hijos al salir, y `await task.value` de una Task no-throwing
    /// ignora la cancelación: el "deadline" acababa esperando a la sombra
    /// entera (verificado: 8s reales con deadline de 2.5s). Con Tasks sueltas
    /// + ResumeOnce, retorna en min(sombra, deadline) de verdad.
    private static func awaitWithDeadline(_ task: Task<String?, Never>,
                                          seconds: Double) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let box = ResumeOnce(cont)
            Task { box.resume(await task.value) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                box.resume(nil)
            }
        }
    }

    /// Tokens DÉBILES para anclar (funcionales es/en frecuentes): un ancla
    /// apoyada solo en ellos liga en casi cualquier frase española.
    static let weakAnchorTokens: Set<String> = [
        "el", "la", "los", "las", "de", "del", "que", "y", "a", "en", "un",
        "una", "es", "lo", "se", "no", "con", "por", "para", "al", "su",
        "me", "te", "mi", "tu", "o", "u", "e", "the", "of", "to", "and",
        "in", "on", "is", "it", "for",
    ]

    /// TRASPLANTE de un segmento alucinado desde el transcript ST del audio
    /// completo. Anclas: el 3-grama final del segmento anterior y el inicial
    /// del siguiente, localizados EN ORDEN dentro de ST con matching DIFUSO
    /// (≥2 de 3 tokens — la exigencia exacta de 4-gramas dejó el trasplante
    /// sin ejecutar ni una vez en producción: 3/3 intentos fallidos según la
    /// auditoría definitiva). Conservador: sin anclas o tamaño incoherente
    /// (fuera de 0.3x-3x palabras) → nil (fallback Apple).
    static func transplantSpan(segments: [String], index: Int, st: String) -> String? {
        func norm(_ w: Substring) -> String {
            w.lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
                .trimmingCharacters(in: .punctuationCharacters)
        }
        func words(_ s: String) -> [String] {
            s.split(whereSeparator: { $0.isWhitespace }).map(norm).filter { !$0.isEmpty }
        }
        // Difuso: ≥ (n-1) coincidencias y al menos un extremo exacto.
        // GUARDAS de la revisión: con 2 tokens el difuso degeneraba a UNA
        // coincidencia (ligaba en cualquier parte) → exigir exacto; y un
        // ancla de solo palabras función («de la que») liga en casi
        // cualquier frase → exigir que coincida exacto al menos un token
        // NO-funcional, o coincidencia total si el ancla es todo funcionales.
        func findFuzzySeq(_ haystack: [String], _ needle: [String], from: Int) -> Int? {
            guard needle.count >= 2, haystack.count >= needle.count else { return nil }
            let required = needle.count >= 3 ? needle.count - 1 : needle.count
            let hasStrongToken = needle.contains { !Self.weakAnchorTokens.contains($0) }
            var i = max(0, from)
            while i + needle.count <= haystack.count {
                var matches = 0
                var strongMatched = false
                for j in 0..<needle.count where haystack[i + j] == needle[j] {
                    matches += 1
                    if !Self.weakAnchorTokens.contains(needle[j]) { strongMatched = true }
                }
                let anchorOK = hasStrongToken ? strongMatched : matches == needle.count
                if matches >= required, anchorOK,
                   haystack[i] == needle[0] || haystack[i + needle.count - 1] == needle[needle.count - 1] {
                    return i
                }
                i += 1
            }
            return nil
        }

        let stTokens = st.split(whereSeparator: { $0.isWhitespace })
        let sWords = stTokens.map(norm)
        guard sWords.count >= 6, index >= 0, index < segments.count else { return nil }

        var lo = 0
        if index > 0 {
            let anchor = Array(words(segments[index - 1]).suffix(3))
            guard anchor.count >= 2,
                  let pos = findFuzzySeq(sWords, anchor, from: 0) else { return nil }
            lo = pos + anchor.count
        }
        var hi = stTokens.count
        if index + 1 < segments.count {
            let anchor = Array(words(segments[index + 1]).prefix(3))
            guard anchor.count >= 2,
                  let pos = findFuzzySeq(sWords, anchor, from: lo) else { return nil }
            hi = pos
        }
        guard hi > lo else { return nil }

        let spanCount = hi - lo
        let pkCount = segments[index].split(whereSeparator: { $0.isWhitespace }).count
        // Tamaño coherente con lo que Parakeet oyó en ese hueco.
        guard spanCount >= 1, pkCount >= 1,
              spanCount >= max(1, (pkCount * 3) / 10), spanCount <= pkCount * 3 else { return nil }

        let span = stTokens[lo..<hi].joined(separator: " ")
        // Firma de invención de ST («grabaciónbación») → donante no fiable.
        guard !LanguageHygiene.hasDuplicatedSyllableSignature(span) else { return nil }
        return span
    }

    /// ÁRBITRO PK↔ST: alinea ambos transcripts por anclas de 3-gramas
    /// idénticos (monótonas, greedy) y examina las regiones divergentes:
    /// - OMISIÓN INTERIOR (`allowSplices`): región con ≤2 tokens en PK y ≥8
    ///   en ST → Parakeet se saltó una cláusula en silencio (el fallo más
    ///   caro del corpus). Se trasplanta el tramo ST con guardas: idioma
    ///   limpio, sin firma de invención, sin polaridad sospechosa y sin
    ///   tocar los 2 últimos tokens de ST (recorta su última palabra).
    /// - POLARIDAD: regiones divergentes cortas donde los motores se
    ///   contradicen (negador, des-, pares peligrosos) → aviso, sin tocar.
    static func arbitrate(pk: String, st: String, allowSplices: Bool,
                          majority: NLLanguage, guest: NLLanguage)
        -> (text: String, splices: Int, warnings: [String]) {
        func norm(_ w: Substring) -> String {
            w.lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
                .trimmingCharacters(in: .punctuationCharacters)
        }
        // Tokens de PK CON sus separadores originales (conservar \n\n).
        var pkTokens: [String] = []
        var pkSeps: [String] = []   // pkSeps[i] = espacio DESPUÉS de pkTokens[i]
        var tok = ""
        var sep = ""
        for ch in pk {
            if ch.isWhitespace {
                if !tok.isEmpty {
                    pkTokens.append(tok)
                    tok = ""
                    sep = ""
                }
                if !pkTokens.isEmpty { sep.append(ch) }   // ignorar ws inicial
                if pkTokens.count == pkSeps.count + 1 {
                    pkSeps.append(sep)
                } else if !pkSeps.isEmpty {
                    pkSeps[pkSeps.count - 1] = sep
                }
            } else {
                tok.append(ch)
            }
        }
        if !tok.isEmpty { pkTokens.append(tok) }
        while pkSeps.count < pkTokens.count { pkSeps.append(" ") }

        let stTokens = st.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let pkNorm = pkTokens.map { norm(Substring($0)) }
        let stNorm = stTokens.map { norm(Substring($0)) }
        guard pkNorm.count >= 6, stNorm.count >= 6 else {
            return (pk, 0, [])
        }

        // Anclas monótonas de 3-gramas idénticos.
        var anchors: [(p: Int, s: Int)] = []
        var sPos = 0
        var p = 0
        while p + 3 <= pkNorm.count {
            var found = -1
            var i = sPos
            while i + 3 <= stNorm.count {
                if stNorm[i] == pkNorm[p], stNorm[i + 1] == pkNorm[p + 1],
                   stNorm[i + 2] == pkNorm[p + 2] {
                    found = i
                    break
                }
                i += 1
            }
            if found >= 0 {
                anchors.append((p, found))
                sPos = found + 3
                p += 3
            } else {
                p += 1
            }
        }
        guard anchors.count >= 2 else { return (pk, 0, []) }

        var splices: [(pkRange: Range<Int>, donor: String)] = []
        var warnings: [String] = []
        for k in 0..<(anchors.count - 1) {
            let pkLo = anchors[k].p + 3
            let pkHi = anchors[k + 1].p
            let stLo = anchors[k].s + 3
            let stHi = anchors[k + 1].s
            guard pkHi >= pkLo, stHi >= stLo else { continue }
            let pkGap = pkHi - pkLo
            let stGap = stHi - stLo

            if allowSplices, pkGap <= 2, stGap >= 8,
               stHi <= stNorm.count - 2 {   // los 2 últimos tokens de ST no son fiables
                let donor = stTokens[stLo..<stHi].joined(separator: " ")
                // ANTI-ECO (revisión, reproducido): si el ancla se ligó TARDE
                // en ST por una frase repetida, el "donante" es texto que PK
                // YA TIENE alrededor — trasplantarlo DUPLICA contenido. Una
                // omisión genuina es material que PK no oyó: cualquier
                // 3-grama compartido con el contexto delata el eco.
                let donorNorm = Array(stNorm[stLo..<stHi])
                let ctxLo = max(0, pkLo - 8)
                let ctxHi = min(pkNorm.count, pkHi + max(8, stGap + 3))
                let context = Array(pkNorm[ctxLo..<ctxHi])
                var echoes = false
                if donorNorm.count >= 3, context.count >= 3 {
                    outer: for d in 0...(donorNorm.count - 3) {
                        for c in 0...(context.count - 3)
                        where context[c] == donorNorm[d]
                            && context[c + 1] == donorNorm[d + 1]
                            && context[c + 2] == donorNorm[d + 2] {
                            echoes = true
                            break outer
                        }
                    }
                }
                // POLARIDAD del residuo (revisión): si el trasplante descarta
                // 1-2 tokens que PK sí oyó y difieren en negación del
                // donante, no coser en silencio — que caiga al AVISO.
                var flipsPolarity = false
                if pkGap >= 1 {
                    let residue = pkTokens[pkLo..<pkHi].joined(separator: " ")
                    flipsPolarity = LanguageHygiene.polarityMismatch(residue, donor) != nil
                }
                if !echoes, !flipsPolarity,
                   Self.spanLooksClean(donor, majority: majority, guest: guest),
                   !LanguageHygiene.hasDuplicatedSyllableSignature(donor) {
                    splices.append((pkLo..<pkHi, donor))
                    continue
                }
                if echoes {
                    Log.info("[ASR] árbitro: donante con eco del contexto — trasplante descartado (ancla tardía probable)")
                }
            }

            if pkGap + stGap >= 1, pkGap <= 15, stGap <= 15, warnings.count < 2 {
                let pkSpan = pkTokens[pkLo..<pkHi].joined(separator: " ")
                let stSpan = stTokens[stLo..<stHi].joined(separator: " ")
                if let signal = LanguageHygiene.polarityMismatch(pkSpan, stSpan) {
                    warnings.append("«\(String(pkSpan.prefix(60)))» ↔ «\(String(stSpan.prefix(60)))» (\(signal))")
                }
            }
        }

        guard !splices.isEmpty else { return (pk, 0, warnings) }

        // Reensamblar conservando los separadores de PK (párrafos incluidos).
        var out = ""
        var idx = 0
        var spliceIter = splices.makeIterator()
        var current = spliceIter.next()
        while idx < pkTokens.count {
            if let c = current, idx == c.pkRange.lowerBound {
                Log.info("[ASR] omisión interior trasplantada de ST: «\(String(c.donor.prefix(90)))…»")
                out += c.donor
                // Saltar los tokens PK sustituidos (0-2) y conservar el
                // separador más FUERTE de la región: un \n\n de párrafo
                // (pausa larga) puede caer tras el PRIMER token sustituido
                // y no debe perderse fundiendo los dos párrafos.
                if c.pkRange.isEmpty {
                    out += " "
                } else {
                    let seps = c.pkRange.clamped(to: pkSeps.indices).map { pkSeps[$0] }
                    out += seps.first(where: { $0.contains("\n") }) ?? seps.last ?? " "
                }
                idx = max(c.pkRange.upperBound, idx)
                current = spliceIter.next()
                continue
            }
            out += pkTokens[idx]
            if idx < pkSeps.count { out += pkSeps[idx] }
            idx += 1
        }
        return (out.trimmingCharacters(in: .whitespaces), splices.count, warnings)
    }

    /// ¿El tramo trasplantado está limpio? (en el idioma ancla, sin
    /// contaminación del invitado — ST también puede fallar).
    static func spanLooksClean(_ span: String, majority: NLLanguage, guest: NLLanguage) -> Bool {
        guard !span.isEmpty else { return false }
        if LanguageHygiene.hasForeignContamination(span, majority: majority) { return false }
        let apparent = LanguageHygiene.apparent(of: span)
        return apparent == nil || apparent == majority
    }

    /// Detector de COLA PERDIDA: Parakeet a veces descarta las últimas
    /// palabras del audio (caso real: «…imágenes de esa» cuando el hablante
    /// siguió ~10 palabras más — tuvo que redictar). Ancla: el último
    /// 4-grama de Parakeet localizado en la mitad final de ST; si tras el
    /// ancla quedan ≥5 palabras en ST, esa cola se anexa. Conservador: sin
    /// ancla exacta o con cola corta, no toca nada.
    static func appendLostTail(parakeet: String, st: String) -> String? {
        func norm(_ w: Substring) -> String {
            w.lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
                .trimmingCharacters(in: .punctuationCharacters)
        }
        let pWords = parakeet.split(whereSeparator: { $0.isWhitespace })
            .map(norm).filter { !$0.isEmpty }
        let stTokens = st.split(whereSeparator: { $0.isWhitespace })
        let sWords = stTokens.map(norm)
        guard pWords.count >= 4, sWords.count >= 9 else { return nil }

        let anchor = Array(pWords.suffix(4))
        var anchorEnd: Int?
        var i = sWords.count - 4
        while i >= 0 {
            if sWords[i] == anchor[0], sWords[i + 1] == anchor[1],
               sWords[i + 2] == anchor[2], sWords[i + 3] == anchor[3] {
                anchorEnd = i + 4
                break
            }
            i -= 1
        }
        guard let end = anchorEnd else { return nil }
        // Cola sustancial y ancla en el tramo final de ST (a mitad de texto
        // sería divergencia normal entre motores, no una cola perdida).
        guard stTokens.count - end >= 5,
              end >= Int(Double(stTokens.count) * 0.5) else { return nil }

        let tail = stTokens[end...].joined(separator: " ")
        var out = parakeet
        // Costura: si ST cerró frase justo antes de la cola, el punto de
        // Parakeet es un cierre REAL — conservarlo (o añadirlo). Si no,
        // quitar la puntuación y unir como continuación.
        let stBoundary = stTokens[end - 1].last.map { ".!?".contains($0) } ?? false
        if let l = out.last, ".,;:".contains(l) {
            if !stBoundary { out.removeLast() }
        } else if stBoundary {
            out += "."
        }
        return out + " " + tail
    }
}
