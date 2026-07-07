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

        let mode = SettingsStore.shared.asrLanguageMode

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
                    if !t.isEmpty {
                        let gap = prevEnd.map { max(0, vs.startTime - $0) } ?? 0
                        segs.append((t, r.confidence, chunk, gap))
                    }
                    prevEnd = vs.endTime
                }
                guard !segs.isEmpty else {
                    // Ningún segmento útil → dejar caer al camino de un disparo.
                    var ds = TdtDecoderState.make()
                    let r = try await manager.transcribe(samples, decoderState: &ds, language: nil)
                    return Self.cleaned(r.text)
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
                                Log.info("[ASR] segmento \(i + 1): rescate no disponible/corto (¿falta permiso de Reconocimiento de voz?) — se conserva Parakeet")
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
                let joined = FormatterPrompt.joinSegmentsWithPauses(
                    segs.map { (text: $0.text, gapBefore: $0.gapBefore) })
                let paras = joined.components(separatedBy: "\n\n").count
                Log.info("[ASR] Auto multiidioma: \(vadSegments.count) segmentos, \(paras) párrafo(s) por pausas")
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
        return Self.cleaned(result.text)
    }

    /// Limpieza mínima determinística (el pulido de verdad es la Fase 7).
    static func cleaned(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("  ") {
            t = t.replacingOccurrences(of: "  ", with: " ")
        }
        return t
    }
}
