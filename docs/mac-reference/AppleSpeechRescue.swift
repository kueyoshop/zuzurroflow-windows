import Foundation
import Speech
import AVFoundation

/// Rescate de segmentos alucinados: re-transcribe un trozo de audio FORZANDO
/// un idioma de verdad a nivel acústico (SFSpeechRecognizer, el dictado del
/// sistema). Parakeet no puede forzar es/en — su parámetro `language` solo
/// filtra por alfabeto (latino/cirílico), inútil para dos idiomas latinos —
/// así que cuando alucina inglés sobre audio español, este es el único modo
/// de recuperar las palabras REALES. Degrada a nil si falta permiso/modelo:
/// el llamador conserva entonces la salida de Parakeet (nunca empeora).
enum AppleSpeechRescue {

    /// Garantiza (una vez) el permiso de Reconocimiento de voz.
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

    /// Re-transcribe `samples` (mono, `sampleRate` Hz) forzando `localeID`
    /// 100% on-device. nil si no autorizado, sin modelo, error o timeout.
    static func transcribe(samples: [Float],
                           sampleRate: Double,
                           localeID: String,
                           timeout: TimeInterval = 8) async -> String? {
        guard !samples.isEmpty, await ensureAuthorized() else { return nil }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              rec.isAvailable, rec.supportsOnDeviceRecognition else { return nil }
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

/// Garantiza que una CheckedContinuation se reanuda UNA sola vez (carrera
/// entre el handler de reconocimiento y el timeout). @unchecked Sendable: el
/// único estado va protegido por el lock y no se retiene a través de awaits.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
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
