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
                if unanimousGuest {
                    Log.info("[ASR] dictado íntegro en idioma invitado — se respeta sin rescate")
                } else if rescueOn {
                    // Índices sospechosos (idioma equivocado sobre el ancla).
                    let toRescue: [Int] = segs.indices.filter { i in
                        guard segs[i].text.split(separator: " ").count >= 3 else { return false }
                        let isMinority = apparent[i] != nil && apparent[i] != majorityNL
                        let contaminated = LanguageHygiene.hasForeignContamination(
                            segs[i].text, majority: majorityNL)
                        return isMinority || contaminated
                    }
                    if !toRescue.isEmpty {
                        // Rescatar EN PARALELO (antes secuencial → sumaba
                        // segundos en dictados largos multilingües).
                        let jobs = toRescue.map { (index: $0, chunk: segs[$0].chunk) }
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

                // COLA PERDIDA: si la sombra ST (que oyó el audio COMPLETO)
                // termina con ≥5 palabras que Parakeet no tiene, anexarlas.
                if let shadowTask {
                    if let st = await Self.awaitWithDeadline(shadowTask, seconds: 2.5),
                       let completed = Self.appendLostTail(parakeet: joined, st: st) {
                        Log.info("[ASR] cola perdida recuperada por ST: «…\(String(completed.suffix(90)))»")
                        joined = completed
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
