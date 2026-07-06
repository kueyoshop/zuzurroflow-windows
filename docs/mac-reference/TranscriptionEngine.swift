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
            if let chunks = try? await vad.segmentSpeechAudio(samples, config: segConfig),
               chunks.count > 1 {
                var segs: [(text: String, confidence: Float, chunk: [Float])] = []
                for chunk in chunks where chunk.count >= 6_400 {   // ≥0.4s
                    var ds = TdtDecoderState.make()
                    let r = try await manager.transcribe(chunk, decoderState: &ds, language: nil)
                    let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { segs.append((t, r.confidence, chunk)) }
                }

                // ARBITRAJE ANTI-ALUCINACIÓN: el LID de Parakeet derrapa de
                // dos formas: (1) segmento entero al idioma equivocado
                // ("more fashionable for me…") y (2) deriva A MITAD de
                // segmento ("…la editora también isa for me, como siempre we
                // have…" — caso real). Regla: el idioma MAYORITARIO del
                // dictado manda; los segmentos minoritarios O contaminados
                // se re-transcriben forzando la mayoría y GANA la confianza
                // más alta — el inglés dicho de verdad sobrevive, el falso no.
                var apparent: [NLLanguage?] = []
                var esWords = 0, enWords = 0
                for s in segs {
                    let lang = LanguageHygiene.apparent(of: s.text)
                    apparent.append(lang)
                    let w = s.text.split(separator: " ").count
                    if lang == .spanish { esWords += w }
                    if lang == .english { enWords += w }
                }
                if esWords > 0 || enWords > 0 {
                    let majority: Language = esWords >= enWords ? .spanish : .english
                    let majorityNL: NLLanguage = esWords >= enWords ? .spanish : .english
                    for i in segs.indices {
                        guard segs[i].text.split(separator: " ").count >= 3 else { continue }
                        let isMinority = apparent[i] != nil && apparent[i] != majorityNL
                        let contaminated = LanguageHygiene.hasForeignContamination(
                            segs[i].text, majority: majorityNL)
                        guard isMinority || contaminated else { continue }

                        var ds = TdtDecoderState.make()
                        guard let forced = try? await manager.transcribe(
                            segs[i].chunk, decoderState: &ds, language: majority) else { continue }
                        let ft = forced.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Con contaminación detectada, pequeño sesgo a favor
                        // de la mayoría (la deriva infla su propia confianza).
                        let threshold = contaminated && !isMinority
                            ? segs[i].confidence - 0.03
                            : segs[i].confidence
                        if !ft.isEmpty, forced.confidence > threshold {
                            Log.info(String(
                                format: "[ASR] segmento %d (%@) re-transcrito al idioma mayoritario (%.2f vs %.2f): «%@»",
                                i + 1, isMinority ? "minoritario" : "contaminado",
                                forced.confidence, segs[i].confidence, ft))
                            segs[i].text = ft
                        } else {
                            Log.info(String(
                                format: "[ASR] segmento %d mantiene su idioma (confianza %.2f vs %.2f)",
                                i + 1, segs[i].confidence, forced.confidence))
                        }
                    }
                }

                Log.info("[ASR] Auto multiidioma: \(chunks.count) segmentos por pausas")
                return Self.cleaned(segs.map(\.text).joined(separator: " "))
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
