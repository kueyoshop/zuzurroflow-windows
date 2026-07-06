import AVFoundation

/// Graba del micrófono y entrega Float32 mono a 16 kHz (formato que esperan
/// Parakeet/Whisper). Acumula las muestras en memoria y reporta el nivel RMS
/// en tiempo real para el waveform del pill.
///
/// Equivalente Swift del `audio_recorder.py` del MVP, con la misma curva de
/// normalización de nivel: clamp((dB+60)/30) ** 0.4.
final class AudioRecorder: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000

    enum RecorderError: Error {
        case formatUnavailable
        case micPermissionDenied
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var isRecording = false
    /// Observador del cambio de ruta/formato de audio (AirPods, cable…).
    private var configObserver: NSObjectProtocol?
    /// Evita re-entrar en la reconfiguración (nuestra propia re-fijación de
    /// dispositivo vuelve a disparar la notificación).
    private var isReconfiguring = false

    /// Nivel 0–1 para la UI. Se invoca en la cola de audio — despachar a main
    /// es responsabilidad del receptor.
    var onLevel: (@Sendable (Float) -> Void)?

    // MARK: - Permiso de micrófono

    static func requestMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Ciclo de grabación

    func start() throws {
        guard !isRecording else { return }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        try configureAndStartEngine()
        isRecording = true

        // Vigilar cambios de ruta/formato (ponerse AirPods, enchufar cable…)
        // para reconfigurar el tap SIN perder lo ya grabado ni cortar.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// Fija el micrófono elegido, construye converter+tap para el formato de
    /// entrada actual y arranca el motor. Reutilizado por start() y por la
    /// reconfiguración en caliente.
    private func configureAndStartEngine() throws {
        let input = engine.inputNode
        // NOTA: setVoiceProcessingEnabled(true) SILENCIABA la captura en el
        // equipo del usuario (2026-07-06) — revertido.
        applyMicSelection(on: input)

        let inputFormat = input.inputFormat(forBus: 0)
        // Sin permiso de mic (o sin dispositivo) el formato viene con 0 Hz.
        guard inputFormat.sampleRate > 0 else {
            throw RecorderError.micPermissionDenied
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnavailable
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)   // idempotente: por si reconfiguramos
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        Log.info("[Audio] Grabando (\(Int(inputFormat.sampleRate)) Hz → 16 kHz mono)")
    }

    /// Fija el micrófono según Ajustes: "builtin" (recomendado — el de AirPods
    /// degrada el dictado), "auto" (default del sistema) o un UID concreto.
    private func applyMicSelection(on input: AVAudioInputNode) {
        let selection = SettingsStore.shared.micSelection
        var chosen: AudioDeviceID?
        switch selection {
        case "auto":
            chosen = nil
        case "builtin":
            chosen = AudioDevices.builtInInputDeviceID()
        default:
            chosen = AudioDevices.allInputDevices().first { $0.uid == selection }?.id
                ?? AudioDevices.builtInInputDeviceID()   // el elegido ya no existe
        }
        if let deviceID = chosen, let au = input.audioUnit {
            var dev = deviceID
            let status = AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &dev, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                Log.info("[Audio] Micrófono: \(AudioDevices.name(of: deviceID)) (elegido; default del sistema: \(AudioDevices.defaultInputName()))")
            } else {
                Log.error("[Audio] No pude fijar el mic elegido (err \(status)) — usando: \(AudioDevices.defaultInputName())")
            }
        } else {
            Log.info("[Audio] Micrófono (default del sistema): \(AudioDevices.defaultInputName())")
        }
    }

    /// El audio cambió de ruta/formato a mitad de grabación (AirPods, cable…).
    /// Reconstruye el tap con el nuevo formato SIN vaciar las muestras ya
    /// capturadas — la grabación continúa sin cortarse.
    private func handleConfigurationChange() {
        lock.lock()
        let recording = isRecording
        let busy = isReconfiguring
        if recording && !busy { isReconfiguring = true }
        lock.unlock()
        guard recording, !busy else { return }

        let alreadyCaptured = samplesSoFar().count
        Log.info("[Audio] Cambio de dispositivo a mitad de dictado — reconfigurando (\(alreadyCaptured) muestras conservadas)")

        engine.stop()
        do {
            try configureAndStartEngine()   // NO toca `samples`
        } catch {
            Log.error("[Audio] Falló la reconfiguración tras el cambio de mic: \(error)")
        }

        lock.lock()
        isReconfiguring = false
        lock.unlock()
    }

    /// Para la grabación y devuelve todas las muestras capturadas.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        teardown()

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()

        let seconds = Double(captured.count) / Self.targetSampleRate
        Log.info("[Audio] Parado: \(captured.count) muestras (\(String(format: "%.1f", seconds))s)")
        return captured
    }

    /// Cancela y descarta el audio.
    func cancel() {
        guard isRecording else { return }
        teardown()

        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lock.unlock()

        Log.info("[Audio] Cancelado, audio descartado")
    }

    /// Audio acumulado hasta ahora sin parar (para transcripción de sesiones largas).
    func samplesSoFar() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func teardown() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        isReconfiguring = false
        converter = nil
        onLevel?(0)
    }

    // MARK: - Procesado por buffer

    private func process(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, convError == nil,
              out.frameLength > 0,
              let channel = out.floatChannelData?[0] else { return }

        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        // RMS → dB → curva del MVP: -60..-30 dB mapeado a 0..1, boost ^0.4
        // para que hasta un susurro mueva las barras.
        var acc: Float = 0
        for s in chunk { acc += s * s }
        let rms = (acc / Float(max(chunk.count, 1))).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        var normalized = max(0, min(1, (db + 60) / 30))
        normalized = pow(normalized, 0.4)

        onLevel?(normalized)
    }
}
