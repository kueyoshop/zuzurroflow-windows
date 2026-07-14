import AVFoundation

/// Graba del micrófono y entrega Float32 mono a 16 kHz (formato que esperan
/// Parakeet/Whisper). Acumula las muestras en memoria y reporta el nivel RMS
/// en tiempo real para el waveform del pill.
///
/// CAPTURA DOBLE (2026-07-10, caso AirPods): un mic Bluetooth entrega
/// buffers EN SILENCIO ~2.2s tras arrancar (activación HFP, medido) y
/// comprime la voz; pero el usuario a veces dicta LEJOS del Mac y ahí los
/// AirPods son el único mic que le oye. Solución sin elegir nada: cuando la
/// entrada default es Bluetooth se graba con LOS DOS (AirPods siguiendo al
/// default + mic integrado fijado) y al parar gana el stream que mejor oyó
/// la voz (SNR). En el escritorio gana el integrado (instantáneo, sin
/// compresión); caminando por el salón ganan los AirPods. Si los AirPods
/// arrancaron en silencio y aun así ganan, la cabeza perdida se rellena con
/// el integrado.
///
/// Además: motor caliente una ventana tras cada dictado (ráfagas = arranque
/// a coste cero, el enlace BT no renegocia) y arranque asíncrono (nunca
/// bloquea el hilo principal).
final class AudioRecorder: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000
    /// Ventana de motor caliente tras parar/cancelar.
    static let warmWindowSeconds: Double = 25

    enum RecorderError: Error {
        case formatUnavailable
        case micPermissionDenied
    }

    private enum Stream { case primary, secondary }

    /// Motor primario: sigue la selección de Ajustes (default/builtin/UID).
    private let engine = AVAudioEngine()
    /// Motor secundario (solo captura doble): mic integrado fijado.
    private var secondary: AVAudioEngine?

    private let lock = NSLock()
    private var samplesPrimary: [Float] = []
    private var samplesSecondary: [Float] = []
    /// ¿Captura doble activa en esta sesión de motor?
    private var dualActive = false
    /// ¿Acumulando muestras? (la grabación "lógica")
    private(set) var isRecording = false
    /// ¿Motor(es) arrancado(s) con tap instalado? (puede estarlo sin grabar)
    private var engineLive = false
    /// Invalida arranques asíncronos en vuelo cuando el usuario ya paró.
    private var generation = 0
    private var startedAt = Date()
    private var firstBufferLogged: Set<String> = []
    private var firstAudioLogged: Set<String> = []
    private var lastLevelPrimary: Float = 0
    private var lastLevelSecondary: Float = 0
    private var configObserver: NSObjectProtocol?
    private var secondaryObserver: NSObjectProtocol?
    /// Ventana de supresión de ecos: nuestra propia reconfiguración
    /// re-dispara AVAudioEngineConfigurationChange — los avisos que lleguen
    /// dentro de esta ventana se ignoran (un flag booleano era guarda muerta:
    /// todo corre serializado en audioQueue y nunca se observaba en true).
    private var suppressChangesUntil = Date.distantPast
    private var warmTeardownItem: DispatchWorkItem?
    /// Cola serie para TODAS las operaciones de los motores.
    private let audioQueue = DispatchQueue(label: "com.zuzurro.flow.audio", qos: .userInitiated)

    /// Nivel 0–1 para la UI (máximo de los dos streams en captura doble).
    /// Se invoca en la cola de audio — despachar a main es del receptor.
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
        samplesPrimary.removeAll(keepingCapacity: true)
        samplesSecondary.removeAll(keepingCapacity: true)
        isRecording = true
        firstBufferLogged.removeAll()
        firstAudioLogged.removeAll()
        lastLevelPrimary = 0
        lastLevelSecondary = 0
        startedAt = Date()
        generation += 1
        let gen = generation
        let live = engineLive
        warmTeardownItem?.cancel()
        warmTeardownItem = nil
        lock.unlock()

        if live {
            Log.info("[Audio] Grabando (motor caliente — arranque instantáneo)")
            // En dual el primario BT se soltó al parar (para no degradar la
            // música de los AirPods): relanzarlo en paralelo. El integrado
            // ya está capturando desde el primer instante.
            audioQueue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let dual = self.dualActive
                let wanted = self.generation == gen && self.isRecording
                self.lock.unlock()
                guard dual, wanted, !self.engine.isRunning else { return }
                do {
                    try self.configurePrimary()
                    self.lock.lock()
                    self.suppressChangesUntil = Date().addingTimeInterval(0.5)
                    self.lock.unlock()
                } catch {
                    Log.error("[Audio] el primario BT no volvió en el rearranque caliente: \(error) — sigo con el integrado")
                }
            }
            return
        }

        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let wanted = self.generation == gen
            self.lock.unlock()
            guard wanted else { return }
            do {
                try self.configureAndStartEngines()
                self.installConfigObserversIfNeeded()
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
                // Solo tocar el estado si ESTA generación sigue vigente: un
                // fallo tardío del arranque N no puede matar el dictado N+2
                // que ya está en curso (carrera real de la revisión).
                self.lock.lock()
                let stale = self.generation != gen
                if !stale { self.isRecording = false }
                self.lock.unlock()
                guard !stale else { return }
                self.onStartFailed?(error)
            }
        }
    }

    /// Configura y arranca el/los motores según Ajustes. SIEMPRE en audioQueue.
    private func configureAndStartEngines() throws {
        // ¿Toca captura DOBLE? Solo en modo auto con la entrada default en
        // Bluetooth y mic integrado disponible (y el ajuste activado).
        let selection = SettingsStore.shared.micSelection
        var wantDual = false
        if selection == "auto", SettingsStore.shared.preferBuiltInMic,
           let def = AudioDevices.defaultInputDeviceID(),
           AudioDevices.isBluetooth(def),
           AudioDevices.builtInInputDeviceID() != nil {
            wantDual = true
        }

        // El INTEGRADO arranca PRIMERO (captura audio real en ~0.2s; medido:
        // yendo segundo tardaba 0.9s). El primario BT puede tomarse su tiempo.
        // dualActive se publica EN CUANTO el secundario está arriba: un
        // stop() durante el arranque del primario (~1s con BT) debe poder
        // elegir ya el stream del integrado (carrera real de la revisión).
        var secondaryUp = false
        if wantDual {
            do {
                try startSecondaryPinnedToBuiltIn()
                secondaryUp = true
                lock.lock()
                dualActive = true
                lock.unlock()
                Log.info("[Audio] captura DOBLE: AirPods (default) + mic integrado — al parar gana el que mejor te oiga")
            } catch {
                Log.error("[Audio] no pude arrancar el mic integrado en paralelo: \(error) — sigo solo con el default")
            }
        }
        if !secondaryUp {
            lock.lock()
            dualActive = false
            lock.unlock()
        }

        do {
            try configurePrimary()
        } catch {
            guard secondaryUp else { throw error }
            // El default (BT) falló pero el integrado ya captura: la
            // grabación NO se pierde — seguimos solo con el integrado.
            Log.error("[Audio] el mic default falló (\(error)) — sigo solo con el integrado")
        }
    }

    /// Motor primario: sigue la selección de Ajustes (en "auto" no se fija
    /// nada: sigue al default del sistema, AirPods incluidos).
    /// `pinBuiltInOverride`: en la reconfiguración a mitad de dictado, si el
    /// default acaba de saltar a BT (se puso los AirPods), seguir con el
    /// integrado en vez de cortar la captura buena.
    private func configurePrimary(pinBuiltInOverride: Bool = false) throws {
        let input = engine.inputNode
        // NOTA: setVoiceProcessingEnabled(true) SILENCIABA la captura en el
        // equipo del usuario (2026-07-06) — revertido.
        if pinBuiltInOverride, let builtIn = AudioDevices.builtInInputDeviceID(),
           let au = input.audioUnit {
            var dev = builtIn
            _ = AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        } else {
            applyMicSelection(on: input)
        }
        try installTap(on: input, of: engine, stream: .primary,
                       label: "primario")
        engine.prepare()
        try engine.start()
        let hz = Int(input.inputFormat(forBus: 0).sampleRate)
        Log.info("[Audio] Grabando (\(hz) Hz → 16 kHz mono)")
    }

    private func startSecondaryPinnedToBuiltIn() throws {
        let eng = secondary ?? AVAudioEngine()
        secondary = eng
        let input = eng.inputNode
        guard let builtIn = AudioDevices.builtInInputDeviceID(),
              let au = input.audioUnit else {
            throw RecorderError.formatUnavailable
        }
        var dev = builtIn
        let status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &dev, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw RecorderError.formatUnavailable }
        try installTap(on: input, of: eng, stream: .secondary,
                       label: "integrado")
        eng.prepare()
        try eng.start()
    }

    /// Construye converter+tap para el formato actual de la entrada. El
    /// converter vive capturado en el closure del tap (uno por stream).
    private func installTap(on input: AVAudioInputNode, of engine: AVAudioEngine,
                            stream: Stream, label: String) throws {
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
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.formatUnavailable
        }

        input.removeTap(onBus: 0)   // idempotente: por si reconfiguramos
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter,
                          targetFormat: targetFormat, stream: stream, label: label)
        }
    }

    /// Fija el micrófono según Ajustes: "builtin", "auto" (default del
    /// sistema, sin fijar) o un UID concreto.
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

    private func installConfigObserversIfNeeded() {
        if configObserver == nil {
            // Vigilar cambios de ruta/formato (ponerse/quitarse AirPods…)
            // para reconfigurar el tap SIN perder lo ya grabado ni cortar.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.audioQueue.async { self.handleConfigurationChange(of: .primary) }
            }
        }
        if secondaryObserver == nil, let secondary {
            secondaryObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: secondary, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.audioQueue.async { self.handleConfigurationChange(of: .secondary) }
            }
        }
    }

    /// El audio cambió de ruta/formato. Grabando: reconstruye el tap del
    /// stream afectado SIN vaciar lo capturado. En reposo (motor caliente):
    /// libera todo y el próximo arranque configura fresco.
    private func handleConfigurationChange(of stream: Stream) {
        lock.lock()
        let recording = isRecording
        let suppressed = Date() < suppressChangesUntil
        lock.unlock()
        guard !suppressed else {
            Log.info("[Audio] aviso de configuración ignorado (eco de nuestra propia reconfiguración)")
            return
        }

        defer {
            lock.lock()
            suppressChangesUntil = Date().addingTimeInterval(0.5)
            lock.unlock()
        }

        guard recording else {
            fullTeardown(reason: "cambio de dispositivo en reposo")
            return
        }

        let t0 = Date()
        lock.lock()
        let keptP = samplesPrimary.count
        let keptS = samplesSecondary.count
        lock.unlock()
        Log.info("[Audio] Cambio de dispositivo a mitad de dictado (stream \(stream == .primary ? "primario" : "integrado")) — reconfigurando (\(keptP) muestras primario + \(keptS) integrado conservadas)")

        switch stream {
        case .primary:
            engine.stop()
            // Si estamos en escritorio con captura simple y el default acaba
            // de saltar a Bluetooth (se puso los AirPods a mitad), NO seguir
            // al default: fijar el integrado y no cortar la captura buena.
            var pinBuiltIn = false
            lock.lock()
            let dualNow = dualActive
            lock.unlock()
            if !dualNow, SettingsStore.shared.micSelection == "auto",
               SettingsStore.shared.preferBuiltInMic,
               let def = AudioDevices.defaultInputDeviceID(),
               AudioDevices.isBluetooth(def),
               AudioDevices.builtInInputDeviceID() != nil {
                pinBuiltIn = true
                Log.info("[Audio] el default saltó a Bluetooth a mitad de dictado — sigo capturando con el integrado")
            }
            var attempts = 0
            var lastError: Error?
            while attempts < 3 {
                do {
                    try configurePrimary(pinBuiltInOverride: pinBuiltIn)   // NO toca las muestras
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
            // Si el default dejó de ser Bluetooth (se quitó los AirPods), el
            // secundario sobra: primario e integrado serían el mismo mic.
            lock.lock()
            let dual = dualActive
            lock.unlock()
            if dual {
                let stillBT = AudioDevices.defaultInputDeviceID().map(AudioDevices.isBluetooth) ?? false
                if !stillBT {
                    stopSecondary(reason: "el default ya no es Bluetooth")
                }
            }
        case .secondary:
            // El integrado casi nunca cambia; si pasa, reintentar una vez.
            secondary?.stop()
            do {
                try startSecondaryPinnedToBuiltIn()
            } catch {
                Log.error("[Audio] el mic integrado no volvió tras el cambio: \(error) — sigo solo con el primario")
                stopSecondary(reason: "no volvió tras el cambio")
            }
        }

        // Si el usuario paró mientras reconfigurábamos, dejarlo caliente.
        lock.lock()
        let stillRecording = isRecording
        lock.unlock()
        if !stillRecording { scheduleWarmTeardown() }
    }

    private func stopSecondary(reason: String) {
        if let secondaryObserver {
            NotificationCenter.default.removeObserver(secondaryObserver)
            self.secondaryObserver = nil
        }
        secondary?.inputNode.removeTap(onBus: 0)
        secondary?.stop()
        secondary = nil
        lock.lock()
        // RESCATE DE CABEZA antes de tirar el stream: si el primario (BT)
        // arrancó en silencio digital, lo que el integrado captó en ese
        // tramo es la única copia de las primeras palabras — trasplantarlo.
        if isRecording, !samplesSecondary.isEmpty {
            var lead = 0
            while lead < samplesPrimary.count, abs(samplesPrimary[lead]) < 1e-5 { lead += 1 }
            if Double(lead) / Self.targetSampleRate >= 0.5 {
                let headCount = min(lead, samplesSecondary.count)
                samplesPrimary.replaceSubrange(
                    0..<min(lead, samplesPrimary.count),
                    with: samplesSecondary.prefix(headCount))
                Log.info(String(format: "[Audio] cabeza de %.1fs trasplantada del integrado antes de soltar la captura doble", Double(headCount) / Self.targetSampleRate))
            }
        }
        samplesSecondary.removeAll(keepingCapacity: false)
        dualActive = false
        lock.unlock()
        Log.info("[Audio] captura doble desactivada (\(reason))")
    }

    /// Para la grabación y devuelve las muestras del MEJOR stream. El motor
    /// queda CALIENTE (warmWindowSeconds) para el siguiente dictado.
    func stop() -> [Float] {
        lock.lock()
        guard isRecording else { lock.unlock(); return [] }
        isRecording = false
        generation += 1
        let p = samplesPrimary
        let s = samplesSecondary
        let dual = dualActive
        samplesPrimary.removeAll(keepingCapacity: false)
        samplesSecondary.removeAll(keepingCapacity: false)
        onLevel?(0)   // dentro del lock: ningún nivel en vuelo lo pisa
        lock.unlock()
        releasePrimaryIfDual(dual)
        scheduleWarmTeardown()

        let captured = Self.chooseFinalSamples(primary: p, secondary: s, dual: dual)
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
        let dual = dualActive
        samplesPrimary.removeAll(keepingCapacity: false)
        samplesSecondary.removeAll(keepingCapacity: false)
        onLevel?(0)
        lock.unlock()
        releasePrimaryIfDual(dual)
        scheduleWarmTeardown()
        Log.info("[Audio] Cancelado, audio descartado")
    }

    /// En captura doble, soltar el primario (BT) NADA MÁS parar: mantenerlo
    /// caliente retenía el enlace HFP 25s y degradaba la música de los
    /// AirPods a calidad de llamada tras cada dictado (revisión). El
    /// integrado queda caliente (arranque instantáneo garantizado); si el
    /// siguiente dictado llega en ventana, el primario se relanza en
    /// paralelo y su silencio de activación lo cubre el relleno de cabeza.
    private func releasePrimaryIfDual(_ dual: Bool) {
        guard dual else { return }
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let recording = self.isRecording
            self.lock.unlock()
            guard !recording else { return }   // ya hay dictado nuevo: no tocar
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.lock.lock()
            self.suppressChangesUntil = Date().addingTimeInterval(0.5)
            self.lock.unlock()
            Log.info("[Audio] primario BT liberado (los AirPods vuelven a alta calidad); integrado sigue caliente")
        }
    }

    /// Libera los motores YA (cambio de ajustes de mic, salida de la app…):
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

    /// Audio acumulado hasta ahora sin parar (para el rescate de
    /// cancelaciones largas) — también elige el mejor stream.
    func samplesSoFar() -> [Float] {
        lock.lock()
        let p = samplesPrimary
        let s = samplesSecondary
        let dual = dualActive
        lock.unlock()
        return Self.chooseFinalSamples(primary: p, secondary: s, dual: dual)
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

    /// Apaga los motores de verdad y suelta el micrófono (indicador naranja
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
        if let secondaryObserver {
            NotificationCenter.default.removeObserver(secondaryObserver)
            self.secondaryObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        secondary?.inputNode.removeTap(onBus: 0)
        secondary?.stop()
        secondary = nil
        lock.lock()
        dualActive = false
        lock.unlock()
        Log.info("[Audio] Micrófono liberado (\(reason))")
    }

    // MARK: - Elección del mejor stream (captura doble)

    /// Métricas de un stream: nivel de voz (p90 de RMS por tramas de 30 ms),
    /// suelo de ruido (p10) y silencio inicial (activación Bluetooth).
    static func streamStats(_ samples: [Float]) -> (voiceDB: Double, snrDB: Double, leadingSilenceSecs: Double) {
        let frame = Int(targetSampleRate * 0.03)
        guard samples.count >= frame * 4 else { return (-100, 0, 0) }

        var lead = 0
        while lead < samples.count, abs(samples[lead]) < 1e-5 { lead += 1 }
        let leadingSecs = Double(lead) / targetSampleRate

        // Las stats se calculan SIN el silencio digital (cabeza de activación
        // BT y huecos): esos ceros hundían el suelo p10 a -160 dB e inflaban
        // el "SNR" de los AirPods hasta ganar en el escritorio (revisión).
        var rmsDB: [Double] = []
        var i = lead
        while i + frame <= samples.count {
            var acc: Float = 0
            for j in i..<(i + frame) { acc += samples[j] * samples[j] }
            let rms = Double((acc / Float(frame)).squareRoot())
            let db = 20 * log10(max(rms, 1e-8))
            if db > -120 { rmsDB.append(db) }
            i += frame
        }
        guard rmsDB.count >= 4 else { return (-100, 0, leadingSecs) }
        rmsDB.sort()
        let voice = rmsDB[min(rmsDB.count - 1, Int(Double(rmsDB.count) * 0.9))]
        let floor = rmsDB[max(0, Int(Double(rmsDB.count) * 0.1))]
        return (voice, voice - floor, leadingSecs)
    }

    /// En captura doble decide qué stream pasa al ASR:
    /// - INTEGRADO por defecto (sin compresión HFP, sin silencio de arranque;
    ///   el usuario reporta que "funciona mucho mejor").
    /// - AIRPODS solo si el integrado apenas oyó la voz (SNR bajo) y los
    ///   AirPods sí (el usuario caminando lejos del Mac). En ese caso, si a
    ///   los AirPods les faltó la cabeza (silencio de activación BT), se
    ///   rellena con lo que el integrado captó en ese tramo.
    static func chooseFinalSamples(primary: [Float], secondary: [Float], dual: Bool) -> [Float] {
        // Cinturón anti-carrera: si el integrado capturó audio real, se
        // considera aunque el flag dual llegara tarde.
        let minUseful = Int(targetSampleRate * 0.4)
        guard dual || secondary.count >= minUseful else { return primary }
        guard secondary.count >= minUseful else { return primary }
        guard primary.count >= minUseful else {
            Log.info("[Audio] dual: el default (AirPods) no entregó audio — uso el integrado")
            return secondary
        }

        let a = streamStats(primary)     // AirPods / default BT
        let b = streamStats(secondary)   // integrado
        // ¿El integrado captó MAL la voz y los AirPods MUCHO mejor? Entonces
        // el usuario está lejos del Mac (o el mic integrado no le llega) y
        // hay que usar los AirPods pese a la compresión HFP. El umbral viejo
        // (SNR integrado < 8) era demasiado estricto: caso real id=745, voz
        // integrado -36 dBFS / SNR 8.6 vs AirPods -15.9 dBFS / SNR 24.3 — se
        // quedó en el integrado (débil) y Parakeet alucinó. Ahora se mira si
        // el integrado es DÉBIL en términos absolutos (voz floja O SNR bajo)
        // y los AirPods son claramente mejores. Los AirPods, a 2 cm de la
        // boca, casi siempre tienen SNR alto, así que la clave es la calidad
        // ABSOLUTA del integrado, no solo la diferencia.
        // Validado con TODO el histórico dual del usuario (2026-07-14): su
        // mic integrado le capta la voz SIEMPRE floja (-33 a -41 dBFS) y los
        // AirPods siempre fuerte (~-15 dBFS). Con este umbral, con AirPods
        // puestos gana el que de verdad le oye (AirPods) salvo que estos no
        // entreguen audio útil; un futuro caso de hablar pegado al MacBook
        // (voz > -32, SNR ≥ 9) sí se queda en el integrado.
        let integratedWeak = b.voiceDB < -32.0 || b.snrDB < 9.0
        let airpodsClearlyBetter = a.snrDB - b.snrDB > 5.0
            || a.voiceDB - b.voiceDB > 10.0
        let farFromMac = integratedWeak && airpodsClearlyBetter

        if !farFromMac {
            Log.info(String(format: "[Audio] dual: integrado SNR %.1f dB (voz %.1f dBFS) / AirPods SNR %.1f dB (voz %.1f dBFS) → INTEGRADO", b.snrDB, b.voiceDB, a.snrDB, a.voiceDB))
            return secondary
        }

        Log.info(String(format: "[Audio] dual: integrado SNR %.1f dB (voz %.1f dBFS) / AirPods SNR %.1f dB (voz %.1f dBFS) → AIRPODS (el integrado te captó flojo)", b.snrDB, b.voiceDB, a.snrDB, a.voiceDB))
        // Cabeza perdida por la activación BT: rellenar con el integrado.
        // Ambos streams terminan en el mismo instante (stop() los copia bajo
        // el mismo lock), así que la diferencia de longitudes ≈ desfase de
        // arranque entre motores (el integrado arranca antes) — la cabeza
        // debe cubrir lead+desfase para no dejar un hueco de habla en la
        // costura (revisión: se perdían 1-2 palabras).
        if a.leadingSilenceSecs >= 0.5 {
            let leadSamples = Int(a.leadingSilenceSecs * targetSampleRate)
            let offset = max(0, secondary.count - primary.count)
            let headCount = min(leadSamples + offset, secondary.count)
            let head = Array(secondary.prefix(headCount))
            let tail = Array(primary.dropFirst(min(leadSamples, primary.count)))
            Log.info(String(format: "[Audio] dual: cabeza de %.1fs rellenada con el integrado (los AirPods arrancaron en silencio)", Double(headCount) / targetSampleRate))
            return head + tail
        }
        return primary
    }

    // MARK: - Procesado por buffer

    private func process(buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                         targetFormat: AVAudioFormat, stream: Stream, label: String) {
        lock.lock()
        let recording = isRecording
        lock.unlock()
        // Motor caliente sin grabar: descartar (ni memoria ni UI).
        guard recording else { return }

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

        // RMS → dB → curva del MVP: -60..-30 dB mapeado a 0..1, boost ^0.4
        // para que hasta un susurro mueva las barras.
        var acc: Float = 0
        for s in chunk { acc += s * s }
        let rms = (acc / Float(max(chunk.count, 1))).squareRoot()

        lock.lock()
        // Re-verificar bajo el lock: un stop() entre el guard de arriba y
        // aquí dejaría un append huérfano y un nivel residual tras el 0
        // final (revisión) — descartar el chunk en vuelo.
        guard isRecording else { lock.unlock(); return }
        switch stream {
        case .primary: samplesPrimary.append(contentsOf: chunk)
        case .secondary: samplesSecondary.append(contentsOf: chunk)
        }
        // Instrumentación del arranque real: los micros Bluetooth entregan
        // SILENCIO ~2s tras arrancar (activación HFP) — esto lo hace visible.
        let logBuffer = !firstBufferLogged.contains(label)
        if logBuffer { firstBufferLogged.insert(label) }
        let logAudio = !firstAudioLogged.contains(label) && rms > 0.0005
        if logAudio { firstAudioLogged.insert(label) }
        let t0 = startedAt
        // Nivel para la UI: máximo de los streams activos.
        let db = 20 * log10(max(rms, 1e-7))
        var normalized = max(0, min(1, (db + 60) / 30))
        normalized = pow(normalized, 0.4)
        switch stream {
        case .primary: lastLevelPrimary = normalized
        case .secondary: lastLevelSecondary = normalized
        }
        let level = max(lastLevelPrimary, lastLevelSecondary)
        // onLevel DENTRO de la sección crítica: orden total de emisión entre
        // los dos taps y frente al 0 final de stop() (el receptor solo
        // despacha a main — no re-entra al recorder).
        onLevel?(level)
        lock.unlock()

        if logBuffer {
            Log.info(String(format: "[Audio] primer buffer (%@) tras %.2fs", label, Date().timeIntervalSince(t0)))
        }
        if logAudio {
            Log.info(String(format: "[Audio] primer audio real (%@) tras %.2fs", label, Date().timeIntervalSince(t0)))
        }
    }
}
