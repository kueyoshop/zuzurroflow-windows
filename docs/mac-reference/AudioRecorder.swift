import AVFoundation

/// Graba del micrófono y entrega Float32 mono a 16 kHz (formato que esperan
/// Parakeet/Whisper). Acumula las muestras en memoria y reporta el nivel RMS
/// en tiempo real para el waveform del pill.
///
/// Diseño post-auditoría 2026-07-10 (caso AirPods, medido en el equipo real):
/// - Un micrófono Bluetooth entrega buffers EN SILENCIO ~2.2s tras arrancar
///   (activación del enlace HFP) — las primeras palabras se perdían. Con el
///   mic integrado el audio real llega en ~0.2s. De ahí `preferBuiltInMic`.
/// - El motor queda CALIENTE una ventana tras cada dictado (ráfagas =
///   arranque instantáneo, y el enlace BT no renegocia entre dictados).
/// - El arranque es asíncrono: nunca bloquea el hilo principal (el pill y el
///   sonido de inicio responden al instante).
final class AudioRecorder: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000
    /// Ventana de motor caliente tras parar/cancelar: los dictados en ráfaga
    /// (patrón real del usuario) arrancan a coste cero. Después se libera el
    /// micrófono (y su indicador naranja).
    static let warmWindowSeconds: Double = 25

    enum RecorderError: Error {
        case formatUnavailable
        case micPermissionDenied
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    /// ¿Acumulando muestras? (la grabación "lógica")
    private(set) var isRecording = false
    /// ¿Motor arrancado con tap instalado? (puede estarlo sin grabar: caliente)
    private var engineLive = false
    /// Invalida arranques asíncronos en vuelo cuando el usuario ya paró.
    private var generation = 0
    private var startedAt = Date()
    private var firstBufferLogged = true
    private var firstAudioLogged = true
    /// Observador del cambio de ruta/formato de audio (AirPods, cable…).
    private var configObserver: NSObjectProtocol?
    /// Evita re-entrar en la reconfiguración (nuestra propia re-fijación de
    /// dispositivo vuelve a disparar la notificación).
    private var isReconfiguring = false
    private var warmTeardownItem: DispatchWorkItem?
    /// Cola serie para TODAS las operaciones del motor (arranque, teardown,
    /// reconfiguración): nada de esto toca el hilo principal.
    private let audioQueue = DispatchQueue(label: "com.zuzurro.flow.audio", qos: .userInitiated)

    /// Nivel 0–1 para la UI. Se invoca en la cola de audio — despachar a main
    /// es responsabilidad del receptor.
    var onLevel: (@Sendable (Float) -> Void)?
    /// El arranque asíncrono falló (sin mic/permiso) — para resetear la UI.
    var onStartFailed: (@Sendable (Error) -> Void)?

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

    /// Empieza a grabar. NO bloquea: si el motor está caliente es inmediato;
    /// si no, arranca en la cola de audio (el pill/sonido responden ya).
    /// Un fallo real llega por `onStartFailed`.
    func start() {
        lock.lock()
        if isRecording { lock.unlock(); return }
        samples.removeAll(keepingCapacity: true)
        isRecording = true
        firstBufferLogged = false
        firstAudioLogged = false
        startedAt = Date()
        generation += 1
        let gen = generation
        let live = engineLive
        warmTeardownItem?.cancel()
        warmTeardownItem = nil
        lock.unlock()

        if live {
            Log.info("[Audio] Grabando (motor caliente — arranque instantáneo)")
            return
        }

        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let wanted = self.generation == gen
            self.lock.unlock()
            guard wanted else { return }
            do {
                try self.configureAndStartEngine()
                self.installConfigObserverIfNeeded()
                self.lock.lock()
                self.engineLive = true
                let aborted = !(self.generation == gen && self.isRecording)
                self.lock.unlock()
                // Soltó la tecla antes de que el mic estuviera listo: el
                // motor queda CALIENTE — el reintento típico que sigue
                // (caso real: tres pulsaciones en 2s) sale instantáneo.
                if aborted { self.scheduleWarmTeardown() }
            } catch {
                Log.error("[Audio] No se pudo iniciar la grabación: \(error)")
                self.lock.lock()
                self.isRecording = false
                self.lock.unlock()
                self.onStartFailed?(error)
            }
        }
    }

    /// Fija el micrófono elegido, construye converter+tap para el formato de
    /// entrada actual y arranca el motor. Reutilizado por start() y por la
    /// reconfiguración en caliente. SIEMPRE en audioQueue.
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

    /// Fija el micrófono según Ajustes: "builtin", "auto" o un UID concreto.
    /// En "auto" con `preferBuiltInMic` (default ON): si la entrada default
    /// del sistema es Bluetooth (AirPods) y existe mic integrado, se captura
    /// con el integrado — medido en este equipo: audio real a los 0.2s frente
    /// a ~2.2s de silencio del enlace BT, y sin compresión HFP. El audio de
    /// SALIDA (música/llamadas) no se toca.
    private func applyMicSelection(on input: AVAudioInputNode) {
        let selection = SettingsStore.shared.micSelection
        var chosen: AudioDeviceID?
        switch selection {
        case "auto":
            chosen = nil
            if SettingsStore.shared.preferBuiltInMic,
               let def = AudioDevices.defaultInputDeviceID(),
               AudioDevices.isBluetooth(def),
               let builtIn = AudioDevices.builtInInputDeviceID() {
                chosen = builtIn
                Log.info("[Audio] Entrada default es Bluetooth (\(AudioDevices.name(of: def))) → capturo con el integrado (arranque instantáneo; desactivable en Ajustes)")
            }
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

    private func installConfigObserverIfNeeded() {
        guard configObserver == nil else { return }
        // Vigilar cambios de ruta/formato (ponerse AirPods, enchufar cable…)
        // para reconfigurar el tap SIN perder lo ya grabado ni cortar.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.audioQueue.async { self.handleConfigurationChange() }
        }
    }

    /// El audio cambió de ruta/formato (AirPods, cable…). Grabando:
    /// reconstruye el tap con el nuevo formato SIN vaciar las muestras ya
    /// capturadas — la grabación continúa. En reposo (motor caliente):
    /// libera el motor y el próximo arranque configura fresco.
    private func handleConfigurationChange() {
        lock.lock()
        let recording = isRecording
        let busy = isReconfiguring
        if !busy { isReconfiguring = true }
        lock.unlock()
        guard !busy else { return }

        defer {
            lock.lock()
            isReconfiguring = false
            lock.unlock()
        }

        guard recording else {
            fullTeardown(reason: "cambio de dispositivo en reposo")
            return
        }

        let t0 = Date()
        let alreadyCaptured = samplesSoFar().count
        Log.info("[Audio] Cambio de dispositivo a mitad de dictado — reconfigurando (\(alreadyCaptured) muestras conservadas)")

        engine.stop()
        var attempts = 0
        var lastError: Error?
        while attempts < 3 {
            do {
                try configureAndStartEngine()   // NO toca `samples`
                lastError = nil
                break
            } catch {
                lastError = error
                attempts += 1
                Log.error("[Audio] Reconfiguración fallida (intento \(attempts)): \(error)")
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
        if let lastError {
            Log.error("[Audio] Reconfiguración agotada tras el cambio de mic: \(lastError)")
        } else {
            Log.info(String(format: "[Audio] Reconfigurado en %.2fs", Date().timeIntervalSince(t0)))
        }

        // Si el usuario paró mientras reconfigurábamos, dejarlo caliente.
        lock.lock()
        let stillRecording = isRecording
        lock.unlock()
        if !stillRecording { scheduleWarmTeardown() }
    }

    /// Para la grabación y devuelve todas las muestras capturadas.
    /// El motor queda CALIENTE (ventana warmWindowSeconds) para que el
    /// siguiente dictado arranque a coste cero.
    func stop() -> [Float] {
        lock.lock()
        guard isRecording else { lock.unlock(); return [] }
        isRecording = false
        generation += 1
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        onLevel?(0)
        scheduleWarmTeardown()

        let seconds = Double(captured.count) / Self.targetSampleRate
        Log.info("[Audio] Parado: \(captured.count) muestras (\(String(format: "%.1f", seconds))s)")
        return captured
    }

    /// Cancela y descarta el audio. El motor queda caliente igualmente.
    func cancel() {
        lock.lock()
        guard isRecording else { lock.unlock(); return }
        isRecording = false
        generation += 1
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        onLevel?(0)
        scheduleWarmTeardown()
        Log.info("[Audio] Cancelado, audio descartado")
    }

    /// Libera el motor YA (cambio de ajustes de mic, salida de la app…):
    /// el próximo arranque re-lee la selección de micrófono.
    func endWarm() {
        lock.lock()
        let recording = isRecording
        warmTeardownItem?.cancel()
        warmTeardownItem = nil
        lock.unlock()
        guard !recording else { return }
        audioQueue.async { [weak self] in
            self?.fullTeardown(reason: "ajustes de micrófono cambiados")
        }
    }

    /// Audio acumulado hasta ahora sin parar (para transcripción de sesiones largas).
    func samplesSoFar() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func scheduleWarmTeardown() {
        let item = DispatchWorkItem { [weak self] in
            self?.fullTeardown(reason: "ventana caliente agotada")
        }
        lock.lock()
        warmTeardownItem?.cancel()
        warmTeardownItem = item
        lock.unlock()
        audioQueue.asyncAfter(deadline: .now() + Self.warmWindowSeconds, execute: item)
    }

    /// Apaga el motor de verdad y suelta el micrófono (indicador naranja
    /// fuera). SIEMPRE en audioQueue. No toca una grabación activa.
    private func fullTeardown(reason: String) {
        lock.lock()
        let recording = isRecording
        if !recording { engineLive = false }
        lock.unlock()
        guard !recording else { return }

        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        Log.info("[Audio] Micrófono liberado (\(reason))")
    }

    // MARK: - Procesado por buffer

    private func process(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        lock.lock()
        let recording = isRecording
        lock.unlock()
        // Motor caliente sin grabar: descartar (ni memoria ni UI).
        guard recording, let converter else { return }

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

        // Instrumentación del arranque real: los micros Bluetooth entregan
        // SILENCIO ~2s tras arrancar (activación HFP) — esto lo hace visible
        // en el log ([Audio] primer buffer / primer audio real).
        lock.lock()
        let logBuffer = !firstBufferLogged
        if logBuffer { firstBufferLogged = true }
        let logAudio = !firstAudioLogged && rms > 0.0005
        if logAudio { firstAudioLogged = true }
        let t0 = startedAt
        lock.unlock()
        if logBuffer {
            Log.info(String(format: "[Audio] primer buffer tras %.2fs", Date().timeIntervalSince(t0)))
        }
        if logAudio {
            Log.info(String(format: "[Audio] primer audio real tras %.2fs", Date().timeIntervalSince(t0)))
        }

        let db = 20 * log10(max(rms, 1e-7))
        var normalized = max(0, min(1, (db + 60) / 30))
        normalized = pow(normalized, 0.4)

        onLevel?(normalized)
    }
}
