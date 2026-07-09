import Accelerate
import Foundation

/// Normalización de ganancia por dictado (AGC estático): sube la voz BAJA al
/// nivel que el ASR espera — el usuario tenía que GRITAR para que Parakeet no
/// alucinara. Medida sobre el percentil 90 del RMS por frames de 30 ms (el
/// RMS global se diluye con los silencios), con gate anti-ruido (amplificar
/// ruido puro provoca texto fantasma) y soft-limiter para no clipear.
/// Se aplica UNA vez al inicio de TranscriptionEngine.transcribe — beneficia
/// al VAD, a Parakeet y a los rescates. NO se aplica en AudioRecorder: el
/// medidor del pill debe mostrar el nivel real del micrófono.
enum AGC {
    static let targetRMS: Float = 0.1        // -20 dBFS
    static let maxGain: Float = 15.85        // +24 dB
    static let frameLength = 480             // 30 ms @ 16 kHz
    static let minSpeechRMSdB: Float = -55
    static let minSNRdB: Float = 6
    static let limiterKnee: Float = 0.85
    static let limiterCeiling: Float = 0.999

    static func normalize(_ samples: [Float]) -> [Float] {
        guard samples.count >= frameLength else { return samples }

        // 1. RMS por frame de 30 ms (vDSP)
        var frameRMS: [Float] = []
        frameRMS.reserveCapacity(samples.count / frameLength)
        samples.withUnsafeBufferPointer { buf in
            var i = 0
            while i + frameLength <= buf.count {
                var rms: Float = 0
                vDSP_rmsqv(buf.baseAddress! + i, 1, &rms, vDSP_Length(frameLength))
                frameRMS.append(rms)
                i += frameLength
            }
        }
        guard !frameRMS.isEmpty else { return samples }

        // 2. Voz = percentil 90; suelo de ruido = percentil 20
        let sorted = frameRMS.sorted()
        let speech = max(sorted[min(sorted.count - 1, (sorted.count * 9) / 10)], 1e-7)
        let noise = max(sorted[(sorted.count * 2) / 10], 1e-7)
        let speechDB = 20 * log10(speech)
        let snrDB = 20 * log10(speech / noise)

        // 3. Gate: sin voz real, no amplificar ruido (alucinaciones)
        guard speechDB > minSpeechRMSdB, snrDB > minSNRdB else { return samples }

        // 4. Ganancia: solo subir, techo +24 dB
        var gain = min(max(targetRMS / speech, 1), maxGain)
        if gain <= 1.001 { return samples }
        Log.info(String(format: "[AGC] voz %.1f dBFS, SNR %.1f dB → ganancia %.1fx", speechDB, snrDB, gain))

        // 5. Aplicar (vDSP)
        var out = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &gain, &out, 1, vDSP_Length(samples.count))

        // 6. Soft-limiter tanh solo si hace falta
        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(out.count))
        if peak > limiterKnee {
            let range = limiterCeiling - limiterKnee
            for i in 0..<out.count {
                let a = abs(out[i])
                if a > limiterKnee {
                    let y = limiterKnee + range * tanh((a - limiterKnee) / range)
                    out[i] = out[i] < 0 ? -y : y
                }
            }
        }
        return out
    }
}
