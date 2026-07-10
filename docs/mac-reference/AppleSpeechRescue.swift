import Foundation
import Speech
import AVFoundation

/// Rescate de segmentos alucinados: re-transcribe un trozo de audio FORZANDO
/// un idioma de verdad a nivel acústico. Parakeet no puede forzar es/en — su
/// parámetro `language` solo filtra por alfabeto (latino/cirílico) — así que
/// cuando alucina inglés sobre audio español, este es el único modo de
/// recuperar las palabras REALES.
///
/// Motor principal: SpeechTranscriber/SpeechAnalyzer (macOS 26) — el modelo
/// NUEVO de Apple, diseñado para audio largo y micro lejano. Validado con
/// sonda: español perfecto con puntuación, 54s de audio en 1.3s, y NO
/// requiere permiso de Reconocimiento de voz (audio de la app, no del mic).
/// Fallback: SFSpeechRecognizer legacy (ese sí requiere permiso).
/// Degrada a nil si nada funciona: el llamador conserva Parakeet.
enum AppleSpeechRescue {

    /// Re-transcribe forzando idioma. Prueba el motor moderno primero.
    static func transcribe(samples: [Float],
                           sampleRate: Double,
                           localeID: String,
                           timeout: TimeInterval = 8) async -> String? {
        if #available(macOS 26.0, *) {
            if let modern = await ModernSpeechRescue.shared.transcribe(
                samples: samples, sampleRate: sampleRate,
                localeID: localeID, timeout: timeout) {
                return modern
            }
        }
        return await legacyTranscribe(samples: samples, sampleRate: sampleRate,
                                      localeID: localeID, timeout: timeout)
    }

    /// Pre-instala los assets del modelo nuevo (llamar al arranque, en
    /// background) para no pagar la descarga en el primer rescate.
    static func prewarmAssets(localeID: String) async {
        if #available(macOS 26.0, *) {
            await ModernSpeechRescue.shared.prewarm(localeID: localeID)
        }
    }

    /// Garantiza (una vez) el permiso de Reconocimiento de voz (solo lo
    /// necesita el fallback legacy).
    static func ensureAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }

    /// ¿Hay motor on-device para este idioma? (sin pedir permiso todavía)
    static func isAvailable(localeID: String) -> Bool {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else { return false }
        return rec.isAvailable && rec.supportsOnDeviceRecognition
    }

    /// Fallback legacy (SFSpeechRecognizer). Requiere permiso de voz.
    static func legacyTranscribe(samples: [Float],
                                 sampleRate: Double,
                                 localeID: String,
                                 timeout: TimeInterval = 8) async -> String? {
        guard !samples.isEmpty else { return nil }
        guard await ensureAuthorized() else {
            Log.info("[SpeechRescue] legacy sin permiso de Reconocimiento de voz")
            return nil
        }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              rec.isAvailable, rec.supportsOnDeviceRecognition else {
            Log.info("[SpeechRescue] legacy \(localeID) no disponible on-device")
            return nil
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let box = ResumeOnce(cont)
            rec.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    box.resume(result.bestTranscription.formattedString)
                } else if error != nil {
                    box.resume(nil)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.resume(nil)
            }
        }
    }
}

/// Motor moderno: SpeechTranscriber/SpeechAnalyzer (macOS 26). Actor: cachea
/// qué locales tienen los assets instalados (la instalación es una vez).
@available(macOS 26.0, *)
actor ModernSpeechRescue {
    static let shared = ModernSpeechRescue()
    private var ready = Set<String>()
    private var failed = Set<String>()

    /// Instala (una vez) los assets del modelo para un locale.
    func prewarm(localeID: String) async {
        guard !ready.contains(localeID), !failed.contains(localeID) else { return }
        let transcriber = SpeechTranscriber(locale: Locale(identifier: localeID),
                                            preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.info("[SpeechRescue] instalando modelo \(localeID)…")
                try await request.downloadAndInstall()
            }
            var status = await AssetInventory.status(forModules: [transcriber])
            var tries = 0
            while status != .installed, tries < 30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                status = await AssetInventory.status(forModules: [transcriber])
                tries += 1
            }
            if status == .installed {
                ready.insert(localeID)
                Log.info("[SpeechRescue] modelo \(localeID) listo (SpeechTranscriber)")
            } else {
                failed.insert(localeID)
                Log.error("[SpeechRescue] assets \(localeID) no instalados (estado \(status)) — se usará el fallback legacy")
            }
        } catch {
            failed.insert(localeID)
            Log.error("[SpeechRescue] prewarm \(localeID) falló: \(error)")
        }
    }

    /// Transcribe forzando idioma con el modelo nuevo. nil → probar legacy.
    func transcribe(samples: [Float], sampleRate: Double,
                    localeID: String, timeout: TimeInterval) async -> String? {
        guard !samples.isEmpty else { return nil }
        await prewarm(localeID: localeID)
        guard ready.contains(localeID) else {
            Log.info("[SpeechRescue] ST \(localeID) sin assets listos → legacy")
            return nil
        }
        let audioSecs = Double(samples.count) / sampleRate

        let work = Task { () -> String? in
            let transcriber = SpeechTranscriber(locale: Locale(identifier: localeID),
                                                preset: .transcription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let wanted = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                  let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate, channels: 1,
                                               interleaved: false),
                  let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat,
                                               frameCapacity: AVAudioFrameCount(samples.count))
            else { return nil }
            inBuf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }

            // Convertir al formato que pide el modelo (Int16 16k mono).
            let feedBuf: AVAudioPCMBuffer
            if wanted.isEqual(inFormat) {
                feedBuf = inBuf
            } else {
                guard let converter = AVAudioConverter(from: inFormat, to: wanted) else { return nil }
                let capacity = AVAudioFrameCount(Double(inBuf.frameLength)
                    * wanted.sampleRate / inFormat.sampleRate) + 1024
                guard let out = AVAudioPCMBuffer(pcmFormat: wanted, frameCapacity: capacity) else { return nil }
                var fed = false
                var convError: NSError?
                converter.convert(to: out, error: &convError) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return inBuf
                }
                guard convError == nil, out.frameLength > 0 else { return nil }
                feedBuf = out
            }

            let collector = Task {
                var text = ""
                do {
                    for try await result in transcriber.results {
                        text += String(result.text.characters)
                    }
                } catch {
                    Log.error("[SpeechRescue] results: \(error)")
                }
                return text
            }
            let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
            builder.yield(AnalyzerInput(buffer: feedBuf))
            builder.finish()
            do {
                _ = try await analyzer.analyzeSequence(sequence)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Log.error("[SpeechRescue] análisis falló: \(error)")
                collector.cancel()
                return nil
            }
            let text = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                Log.info(String(format: "[SpeechRescue] ST devolvió VACÍO para %.1fs de audio (%@)",
                                audioSecs, localeID))
            }
            return text.isEmpty ? nil : text
        }

        // Timeout: cancelar el trabajo si se pasa (sin zombies).
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            work.cancel()
        }
        let result = await work.value
        if result == nil, work.isCancelled {
            Log.info(String(format: "[SpeechRescue] ST timeout %.0fs con %.1fs de audio (%@)",
                            timeout, audioSecs, localeID))
        }
        watchdog.cancel()
        return result
    }
}

/// Garantiza que una CheckedContinuation se reanuda UNA sola vez (carrera
/// entre el handler de reconocimiento y el timeout). @unchecked Sendable: el
/// único estado va protegido por el lock y no se retiene a través de awaits.
/// Internal: también lo usa la espera acotada de la sombra (TranscriptionEngine).
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<T, Never>

    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }

    func resume(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        cont.resume(returning: value)
    }
}
