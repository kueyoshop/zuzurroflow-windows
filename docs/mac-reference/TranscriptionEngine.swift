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

                // ARBITRAJE ANTI-ALUCINACIÓN. El LID de Parakeet derrapa de
                // dos formas: segmento entero al idioma equivocado y deriva
                // a mitad de segmento. El ancla ya NO es la "mayoría" del
                // dictado (caso real: la alucinación fue tan larga que GANÓ
                // la votación y protegimos al invasor) sino el IDIOMA
                // PRINCIPAL del usuario. Además, medido en su log: forzar
                // español sobre audio genuinamente inglés sigue produciendo
                // el inglés correcto (Parakeet v3 no obedece a ciegas), así
                // que re-transcribir forzado es casi inofensivo para el
                // idioma invitado y CURA la alucinación.
                var apparent: [NLLanguage?] = []
                for s in segs {
                    apparent.append(LanguageHygiene.apparent(of: s.text))
                }
                let primaryIsSpanish = SettingsStore.shared.asrAutoPrimary != "en"
                let majority: Language = primaryIsSpanish ? .spanish : .english
                let majorityNL: NLLanguage = primaryIsSpanish ? .spanish : .english
                let guestNL: NLLanguage = primaryIsSpanish ? .english : .spanish
                // Dictado ENTERO en el idioma invitado (cambio intencional
                // de idioma, "let's talk in English"): no tocar nada.
                let meaningful = segs.indices.filter {
                    segs[$0].text.split(separator: " ").count >= 3
                }
                let unanimousGuest = !meaningful.isEmpty && meaningful.allSatisfy {
                    apparent[$0] == guestNL
                        && !LanguageHygiene.hasForeignContamination(segs[$0].text, majority: guestNL)
                }
                if unanimousGuest {
                    Log.info("[ASR] dictado íntegro en idioma invitado — se respeta sin arbitraje")
                } else {
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
                        // CARGA DE LA PRUEBA INVERTIDA (caso real 17:46: la
                        // alucinación inglesa fluida puntuó 0.68 vs 0.61 del
                        // español correcto — el invento va "muy seguro").
                        // El idioma minoritario solo se conserva si le gana
                        // al forzado por MUCHO: audio genuinamente inglés
                        // forzado a español da confianza muy baja (hueco
                        // grande); audio español alucinado a inglés da hueco
                        // pequeño. Umbral: +0.15.
                        let keepMargin: Float = 0.15
                        if !ft.isEmpty, segs[i].confidence <= forced.confidence + keepMargin {
                            Log.info(String(
                                format: "[ASR] segmento %d (%@) → idioma mayoritario (orig %.2f ≤ %.2f+%.2f): «%@»",
                                i + 1, isMinority ? "minoritario" : "contaminado",
                                segs[i].confidence, forced.confidence, keepMargin, ft))
                            segs[i].text = ft
                        } else {
                            Log.info(String(
                                format: "[ASR] segmento %d conserva su idioma (orig %.2f vs forzado %.2f — hueco grande, idioma genuino)",
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
