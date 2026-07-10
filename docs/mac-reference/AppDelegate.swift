import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let audioRecorder = AudioRecorder()
    let transcriptionEngine = TranscriptionEngine()
    let formatter = Formatter()
    let paster = Paster()
    let targetTracker = TargetAppTracker()
    let learner = CorrectionLearner()
    let commandEngine = CommandEngine()
    let toast = ToastController()
    /// Command Mode en curso: selección capturada al pulsar la tecla de orden.
    private var commandSelection: String?
    let sounds = SoundPlayer()
    /// Audio de una grabación cancelada, retenido para "Deshacer".
    private var cancelledSamples: [Float]?
    /// Id en historial del transcript auto-guardado de la última cancelación
    /// larga (para no duplicar si el usuario pulsa Deshacer).
    private var cancelledHistoryId: Int64?
    private(set) var history: HistoryStore?
    private var statusItem: StatusItemController?
    private var hotkeyMonitor: EventTapMonitor?
    private var flowBar: FlowBarController?
    private var cancellables = Set<AnyCancellable>()
    /// Último texto dictado, para el atajo "pegar último" (portapapeles propio).
    private(set) var lastTranscript: String?
    /// Token anti-App-Nap: sin él, macOS "duerme" la app tras un rato de
    /// inactividad y el primer gesto de hotkey llegaba tarde o se perdía
    /// (caso real: el doble toque de Fn fallaba tras un rato sin dictar).
    private var napActivity: NSObjectProtocol?
    /// Avisos de polaridad del árbitro PK↔ST, pendientes de mostrar DESPUÉS
    /// del pegado (mostrados al nacer, los toasts del pipeline los pisaban).
    private var pendingPolarityWarnings: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Dictator (antes ZuzurroFlow) iniciando…")

        // Sin App Nap: la app debe reaccionar al atajo AL INSTANTE aunque
        // lleve horas quieta (no impide que el sistema duerma).
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Dictado global: respuesta inmediata al atajo")

        // Menú Edición (Cmd+A/C/V/X/Z) para los campos de texto del Scratchpad
        // y el Dashboard — sin esto, una app LSUIElement no los enruta.
        EditMenu.install()

        // Historial persistente (SQLite). Si falla, la app sigue sin historial.
        do {
            let store = try HistoryStore()
            history = store
            lastTranscript = store.latest(1).first?.formattedText
            seedDictionaryIfNeeded(store)
            recoverPendingDictationIfAny()
        } catch {
            Log.error("[History] No se pudo abrir la base de datos: \(error)")
        }

        // Re-aplicar el perfil de atajos cuando cambie en Ajustes.
        NotificationCenter.default.addObserver(
            forName: .zzfSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotkeyMonitor?.reloadShortcuts()
                self?.neutralizeFnSystemActionIfNeeded()
                // El motor caliente puede tener fijado un mic viejo: liberar
                // para que el próximo dictado re-lea la selección.
                self?.audioRecorder.endWarm()
            }
        }

        let controller = StatusItemController(appState: appState)
        controller.recentProvider = { [weak self] in
            self?.history?.latest(5).map { $0.formattedText } ?? []
        }
        controller.onPasteRecent = { [weak self] text in
            self?.paste(text: text)
        }
        controller.onToggleRecording = { [weak self] in self?.toggleRecording() }
        controller.onOpenDashboard = { [weak self] in
            DashboardWindowController.shared.show(history: self?.history)
        }
        controller.onOpenScratchpad = { [weak self] in
            guard let self else { return }
            ScratchpadWindowController.shared.show(appState: self.appState)
        }
        toast.onSendToScratchpad = { [weak self] in
            guard let self else { return }
            ScratchpadWindowController.shared.show(appState: self.appState)
        }
        controller.onQuit = { NSApplication.shared.terminate(nil) }
        statusItem = controller

        // Flow Bar que respira: mini-pastilla SIEMPRE visible que se expande
        // al dictar (morph estilo Wispr). Click en la mini = manos libres.
        let bar = FlowBarController(appState: appState)
        bar.onCancel = { [weak self] in self?.cancelFromHotkey() }
        bar.onStop = { [weak self] in self?.endRecordingFromHotkey() }
        bar.onIdleTap = { [weak self] in
            guard let self, appState.recordingState == .idle else { return }
            appState.handsFreeLocked = true
            sounds.play(.lock)
            beginRecordingFromHotkey()
        }
        bar.onOpenScratchpad = { [weak self] in
            guard let self else { return }
            ScratchpadWindowController.shared.show(appState: self.appState)
        }
        bar.onOpenSettings = { [weak self] in
            DashboardWindowController.shared.show(history: self?.history, section: .settings)
        }
        flowBar = bar
        bar.presentAlways()

        appState.$recordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recState in
                self?.flowBar?.updateForState(recState)
            }
            .store(in: &cancellables)

        let state = appState
        audioRecorder.onStartFailed = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.appState.recordingState = .idle
                self.toast.show("No se pudo iniciar el micrófono", duration: 3)
                Log.error("[Audio] arranque fallido reportado a la UI: \(error)")
            }
        }
        audioRecorder.onLevel = { [weak bar] level in
            Task { @MainActor in
                state.audioLevel = level
                bar?.setAudioLevel(level)
            }
        }

        // Cargar el modelo ASR en segundo plano (descarga la primera vez).
        let engine = transcriptionEngine
        Task {
            // Aviso de polaridad (los dos motores oyeron sentidos opuestos):
            // toast informativo — la corrección es del usuario, no nuestra.
            await engine.setWarningHandler { [weak self] msg in
                Task { @MainActor in
                    self?.pendingPolarityWarnings.append(msg)
                }
            }
            await engine.loadModel()
            let ready = await engine.isReady
            await MainActor.run {
                state.modelReady = ready
            }
        }

        // Diccionario personal → pipeline de pulido.
        let fmt = formatter
        if let store = history {
            Task {
                await fmt.setDictionaryProvider {
                    store.dictionaryWords().map { ($0.word, $0.replacement) }
                }
                await fmt.setSnippetsProvider {
                    store.snippets().map { ($0.trigger, $0.expansion) }
                }
            }
        }

        // Precalentar el modelo de pulido de Apple.
        Task.detached(priority: .utility) {
            await fmt.prewarm()
        }

        setupHotkey()
        neutralizeFnSystemActionIfNeeded()
        targetTracker.startTracking()

        // Asistente de permisos si falta alguno (reinstalación / Mac nuevo).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            OnboardingWindowController.shared.showIfNeeded()
        }

        // Rescate anti-alucinación: pre-instalar los assets del modelo nuevo
        // (SpeechTranscriber, sin permiso) y, como fallback, pedir el permiso
        // del motor legacy. Sin bloquear; si algo falta, la app sigue igual.
        if SettingsStore.shared.appleRescueEnabled {
            let primary = SettingsStore.shared.asrAutoPrimary == "en" ? "en-US" : "es-ES"
            Task.detached(priority: .utility) {
                await AppleSpeechRescue.prewarmAssets(localeID: primary)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Task { _ = await AppleSpeechRescue.ensureAuthorized() }
            }
        }

        // Como Wispr: si el USUARIO abrió la app (doble clic en Aplicaciones),
        // mostrar el Dashboard. En el arranque automático al encender el Mac,
        // quedarse silenciosa en la barra de menú.
        if !launchedAsLoginItem, !OnboardingWindowController.needsOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                DashboardWindowController.shared.show(history: self?.history)
            }
        }

        Log.info("Listo. Icono en la barra de menú activo.")
    }

    private var accessibilityPollTimer: Timer?

    /// Mantiene la acción de sistema de la tecla fn/🌐 sincronizada con los
    /// atajos: si algún atajo usa fn → neutralizarla (el visor de emojis
    /// interfiere con el dictado), GUARDANDO el valor original; si ya ningún
    /// atajo usa fn → restaurar el valor original. Igual que exige Wispr,
    /// pero automático y reversible.
    private func neutralizeFnSystemActionIfNeeded() {
        let combos = [SettingsStore.shared.pushToTalkCombo,
                      SettingsStore.shared.handsFreeCombo,
                      SettingsStore.shared.commandCombo].compactMap { $0 }
        let usesFn = combos.contains(where: { $0.usesFnKey })
        let domain = "com.apple.HIToolbox" as CFString
        let key = "AppleFnUsageType" as CFString
        let backupKey = "fnUsageTypeBackup"
        let current = (CFPreferencesCopyAppValue(key, domain) as? Int) ?? 2

        if usesFn {
            guard current != 0 else { return }
            // Recordar el valor original para restaurarlo si deja de usar fn.
            if UserDefaults.standard.object(forKey: backupKey) == nil {
                UserDefaults.standard.set(current, forKey: backupKey)
            }
            CFPreferencesSetAppValue(key, 0 as CFNumber, domain)
            CFPreferencesAppSynchronize(domain)
            Log.info("[Hotkey] Tecla fn/🌐 del sistema neutralizada (\(current) → 0): ya no abre el visor de emojis")
            toast.show("Ajusté la tecla 🌐 del sistema a «No hacer nada» para que no abra emojis al dictar", duration: 5)
        } else if let backup = UserDefaults.standard.object(forKey: backupKey) as? Int {
            // Ya no dicta con fn: devolverle a la tecla su función original.
            if current == 0, backup != 0 {
                CFPreferencesSetAppValue(key, backup as CFNumber, domain)
                CFPreferencesAppSynchronize(domain)
                Log.info("[Hotkey] Tecla fn/🌐 restaurada a su función original (\(backup))")
                toast.show("Tecla 🌐 restaurada a su función original — ya no la usas para dictar", duration: 5)
            }
            UserDefaults.standard.removeObject(forKey: backupKey)
        }
    }

    private func setupHotkey() {
        let monitor = EventTapMonitor(profile: SettingsStore.shared.hotkeyProfile)
        monitor.onStart = { [weak self] in self?.beginRecordingFromHotkey() }
        monitor.onStop = { [weak self] in self?.endRecordingFromHotkey() }
        monitor.onCancel = { [weak self] in self?.cancelFromHotkey() }
        monitor.onPasteLast = { [weak self] in self?.pasteLast() }
        monitor.onLockChanged = { [weak self] locked in
            self?.appState.handsFreeLocked = locked
            if locked { self?.sounds.play(.lock) }
        }
        // Command Mode: mantener (con texto seleccionado) → dictar la orden
        // → soltar → Claude la aplica y reemplaza la selección.
        monitor.onCommandStart = { [weak self] in self?.commandStart() }
        monitor.onCommandStop = { [weak self] in self?.commandStop() }

        // Acorde de manos libres (ej. fn+Espacio): toggle empezar/terminar.
        monitor.onHandsFreeToggle = { [weak self] in
            guard let self else { return }
            switch appState.recordingState {
            case .idle:
                appState.handsFreeLocked = true
                sounds.play(.lock)
                beginRecordingFromHotkey()
            case .recording:
                endRecordingFromHotkey()
            default:
                break
            }
        }
        hotkeyMonitor = monitor

        if monitor.hasAccessibilityPermission {
            _ = monitor.start()
        } else {
            // Abre el diálogo del sistema y espera a que se conceda para arrancar
            // el tap sin necesidad de reiniciar la app.
            Log.info("[Hotkey] Falta permiso de Accesibilidad. Abriendo diálogo del sistema…")
            monitor.promptAccessibilityIfNeeded()
            accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let m = self.hotkeyMonitor else { return }
                    if m.hasAccessibilityPermission {
                        self.accessibilityPollTimer?.invalidate()
                        self.accessibilityPollTimer = nil
                        _ = m.start()
                        Log.info("[Hotkey] Permiso concedido — atajos activos")
                    }
                }
            }
        }
    }

    private func beginRecordingFromHotkey() {
        guard appState.recordingState == .idle else { return }
        startRecording()
    }

    private func endRecordingFromHotkey() {
        guard appState.recordingState == .recording else { return }
        stopAndProcess()
    }

    // MARK: - Command Mode

    private func commandStart() {
        guard appState.recordingState == .idle else { return }
        guard SettingsStore.shared.kieApiKey != nil else {
            toast.show("Command Mode necesita la clave de kie.ai (Ajustes)", duration: 3.5)
            return
        }
        // Capturar la selección ANTES de grabar (el foco sigue intacto).
        guard let selection = SelectionReader.readSelectedText() else {
            toast.show("Selecciona texto primero y mantén la tecla de orden", duration: 3)
            return
        }
        commandSelection = selection
        Log.info("[Command] Selección capturada (\(selection.count) chars) — dicta la orden")
        startRecording()
    }

    private func commandStop() {
        guard let selection = commandSelection, appState.recordingState == .recording else {
            commandSelection = nil
            return
        }
        commandSelection = nil
        let samples = audioRecorder.stop()
        appState.handsFreeLocked = false
        sounds.play(.stop)

        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        guard seconds >= 0.4 else {
            appState.recordingState = .idle
            toast.show("No oí la orden — mantén la tecla mientras la dictas", duration: 3)
            return
        }

        appState.recordingState = .formatting
        let engine = transcriptionEngine
        let cmd = commandEngine

        Task { @MainActor in
            defer { if appState.recordingState != .pasting { appState.recordingState = .idle } }
            do {
                guard await engine.isReady else { return }
                let order = try await engine.transcribe(samples)
                guard !order.isEmpty else {
                    toast.show("No entendí la orden", duration: 2.5)
                    return
                }
                Log.info("[Command] Orden: «\(order)»")
                toast.show("Aplicando: \(order.prefix(40))…", duration: 20)

                let result = try await cmd.apply(order: order, to: selection)
                toast.dismiss(immediately: true)

                history?.save(raw: selection, formatted: result, duration: seconds,
                              targetApp: targetTracker.targetBundleID, engine: "command")
                // La selección sigue activa en la app → pegar la reemplaza.
                deliver(result)
                Log.info("[Command] Aplicado (\(result.count) chars)")
            } catch {
                toast.dismiss(immediately: true)
                toast.show("Command Mode: \(error.localizedDescription)", duration: 4)
                Log.error("[Command] \(error)")
            }
        }
    }

    private func cancelFromHotkey() {
        commandSelection = nil   // cancelar también aborta una orden en curso
        guard appState.recordingState == .recording else { return }
        // Conservar el audio: el toast permite deshacer la cancelación.
        let samples = audioRecorder.stop()
        appState.recordingState = .idle
        appState.handsFreeLocked = false
        sounds.play(.cancel)
        Log.info("Dictado cancelado")

        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        // Solo ofrecer deshacer si había algo con sustancia (evita el toast
        // en descartes por toque suelto o pulsación accidental).
        guard seconds >= 0.8 else { return }

        cancelledSamples = samples
        cancelledHistoryId = nil
        // Toast más largo cuanto más audio había en juego.
        let toastDuration = min(8.0, max(3.5, seconds / 6.0))
        toast.show("Grabación cancelada", actionTitle: "Deshacer", duration: toastDuration) { [weak self] in
            self?.undoCancel()
        }

        // RED DE SEGURIDAD para cancelaciones largas (p. ej. un Esc accidental
        // tras un minuto hablando): transcribir en segundo plano y guardarlo
        // en el historial — aunque el toast expire, nada se pierde.
        if seconds >= 5.0 {
            let engine = transcriptionEngine
            Task { @MainActor in
                guard await engine.isReady else { return }
                guard let text = try? await engine.transcribe(samples), !text.isEmpty else { return }
                let saved = history?.save(
                    raw: text, formatted: text, duration: seconds,
                    targetApp: targetTracker.targetBundleID, engine: "cancelado"
                )
                cancelledHistoryId = saved?.id
                Log.info("[Cancel] Audio largo cancelado transcrito y guardado en Recientes (\(Int(seconds))s)")
            }
        }
    }

    /// ¿La lanzó el sistema al iniciar sesión (login item)?
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication,
              let prop = event.paramDescriptor(forKeyword: keyAEPropData)
        else { return false }
        return prop.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Click en la app (Finder/Dock/Spotlight) estando ya abierta → Dashboard.
    // MARK: - Abrir la app ya corriendo (Aplicaciones/Spotlight) → Dashboard
    // Tres vías porque en apps .accessory el camino estándar es poco fiable:
    // 1) delegate estándar, 2) Apple Event «rapp» directo, 3) activación sin
    // ventanas visibles.

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
    }

    @objc private func handleReopenEvent(_ event: NSAppleEventDescriptor?,
                                         withReply reply: NSAppleEventDescriptor?) {
        Log.info("[App] Evento reabrir (doble clic con la app corriendo) → Dashboard")
        DashboardWindowController.shared.show(history: history)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        Log.info("[App] applicationShouldHandleReopen (ventanas: \(flag)) → Dashboard")
        DashboardWindowController.shared.show(history: history)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Doble clic en Aplicaciones con la app corriendo la ACTIVA aunque el
        // evento de reapertura se pierda: si no hay ventana visible (los
        // paneles del overlay/toasts no cuentan), el usuario espera el Dashboard.
        guard appState.recordingState == .idle else { return }
        // Pero si estamos abriendo el Scratchpad, es ESO lo que quiere ver, no
        // el Dashboard.
        if ScratchpadWindowController.shared.isVisible { return }
        let anyVisible = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) }
        if !anyVisible {
            Log.info("[App] Activada sin ventanas visibles → Dashboard")
            DashboardWindowController.shared.show(history: history)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // cancel() ya es idempotente bajo su lock — leer isRecording desde
        // aquí sin lock era una carrera de datos técnica.
        audioRecorder.cancel()
        Log.info("Cerrando Dictator.")
    }

    // Toggle desde el menú; en Fase 3 lo disparará también el hotkey global.
    private func toggleRecording() {
        switch appState.recordingState {
        case .idle:
            startRecording()
        case .recording:
            stopAndProcess()
        default:
            break
        }
    }

    private func startRecording() {
        targetTracker.captureNow()   // recordar dónde pegar antes de nada
        // ¿Corrigió a mano el dictado anterior? → aprender para el diccionario
        // (comprobación final; las periódicas corren tras cada pegado).
        if let store = history {
            showLearnedToast(learner.harvestCorrections(into: store), store: store)
        }
        Task { @MainActor in
            guard await AudioRecorder.requestMicPermission() else {
                Log.error("Permiso de micrófono denegado — actívalo en Ajustes del Sistema → Privacidad → Micrófono")
                return
            }
            // Arranque NO bloqueante: el pill y el sonido responden al
            // instante; el motor arranca en su propia cola (con AirPods la
            // activación del enlace tardaba segundos y congelaba esto).
            // Un fallo real llega por onStartFailed y resetea el estado.
            audioRecorder.start()
            appState.recordingState = .recording
            sounds.play(.start)
            // Contexto del campo (estilo Wispr): leer AHORA lo que ya hay
            // escrito donde se va a pegar — sus nombres/siglas se
            // respetarán aunque no estén en el diccionario.
            var contextText = ""
            if let element = FocusedFieldInspector.focusedElement(),
               let value = FocusedFieldInspector.value(of: element), !value.isEmpty {
                contextText = String(value.suffix(FieldContext.maxContextChars))
            }
            let terms = FieldContext.extractTerms(from: contextText)
            lastContextTerms = terms
            if !terms.isEmpty {
                let sample = terms.suffix(8).joined(separator: ", ")
                Log.info("[Contexto] \(terms.count) términos del campo: \(sample)\(terms.count > 8 ? "…" : "")")
            }
            // Precalentar la sesión del pulido EN PARALELO con el habla:
            // al soltar, el modelo solo genera (gran recorte de latencia).
            let fmt = formatter
            let ctx = contextText
            let tone = AppToneCategory.categorize(bundleID: targetTracker.targetBundleID)
            if tone != .neutral {
                Log.info("[Tono] app destino \(targetTracker.targetBundleID ?? "?") → \(tone.rawValue)")
            }
            Task.detached(priority: .userInitiated) {
                await fmt.setToneCategory(tone)
                await fmt.setFieldContext(terms: terms, text: ctx)
                await fmt.prepareForDictation()
            }
        }
    }

    /// Cronómetro parar→pegar (para vigilar la latencia total).
    private var stopInstant: Date?

    private func stopAndProcess() {
        let samples = audioRecorder.stop()
        appState.handsFreeLocked = false
        sounds.play(.stop)
        stopInstant = Date()
        process(samples: samples)
    }

    /// Deshacer una cancelación: procesar el audio retenido como si se
    /// hubiera parado normal (transcribe → pule → pega donde esté el cursor).
    private func undoCancel() {
        // Un solo pipeline a la vez: si hay otro dictado transcribiendo o
        // formateando, dos process() entrelazados cruzan formatter/paster.
        // Re-ofrecer el Deshacer para cuando termine (no perder el audio).
        guard appState.recordingState == .idle else {
            toast.show("Ocupado con otro dictado…", actionTitle: "Deshacer",
                       duration: 4) { [weak self] in self?.undoCancel() }
            return
        }
        guard let samples = cancelledSamples else { return }
        cancelledSamples = nil
        // Evitar duplicado: el proceso normal lo volverá a guardar.
        if let id = cancelledHistoryId {
            history?.delete(id: id)
            cancelledHistoryId = nil
        }
        targetTracker.captureNow()
        Log.info("Cancelación deshecha — procesando el audio retenido")
        process(samples: samples)
    }

    private func process(samples: [Float]) {
        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        guard seconds >= 0.1 else {
            Log.info("Audio demasiado corto, descartado")
            appState.recordingState = .idle
            return
        }

        appState.recordingState = .transcribing
        let engine = transcriptionEngine

        Task { @MainActor in
            defer { appState.recordingState = .idle }
            do {
                guard await engine.isReady else {
                    Log.info("El modelo aún no está listo (descargando/cargando) — audio descartado")
                    return
                }
                let t0 = Date()
                let rawText = try await engine.transcribe(samples)
                let elapsed = Date().timeIntervalSince(t0)
                Log.info("[ASR] \(String(format: "%.1f", seconds))s → \(String(format: "%.2f", elapsed))s: «\(rawText)»")

                guard !rawText.isEmpty else {
                    toast.show("No se oyó nada", duration: 2)
                    return
                }

                // Red anti-pérdida: apuntar el crudo a disco ANTES del
                // formateo. Si la app muere/se reinstala a mitad (caso real:
                // un dictado de 100s desapareció sin fila en la DB), el
                // siguiente arranque lo rescata al historial.
                let pendingURL = writePendingDictation(rawText, duration: seconds)

                // Pulido IA (Apple on-device / Claude kie según Ajustes).
                appState.recordingState = .formatting
                let text = await formatter.format(rawText)
                if text != rawText {
                    Log.info("[Formatter] «\(text)»")
                }

                // Guardar en el historial (crudo + pulido).
                history?.save(
                    raw: rawText,
                    formatted: text,
                    duration: seconds,
                    targetApp: targetTracker.targetBundleID,
                    engine: SettingsStore.shared.formatterEngine.rawValue
                )
                clearPendingDictation(pendingURL)

                // Contador real de uso del diccionario (antes siempre 0).
                let usedWords = await formatter.consumeMatchedDictWords()
                if !usedWords.isEmpty {
                    history?.incrementDictUsage(words: usedWords)
                }

                deliver(text)

                // Aviso de polaridad DESPUÉS del pegado: el texto ya está en
                // pantalla y ningún toast del pipeline lo pisa. Cita el
                // dictado CRUDO (el pulido puede haber cambiado esas palabras).
                if !pendingPolarityWarnings.isEmpty {
                    let msg = pendingPolarityWarnings.joined(separator: "  ·  ")
                    pendingPolarityWarnings.removeAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        self?.toast.show("⚠️ Los motores oyeron distinto (revisa el texto): \(msg)", duration: 8)
                    }
                }
            } catch {
                Log.error("[ASR] Error transcribiendo: \(error)")
            }
        }
    }

    // MARK: - Red anti-pérdida del dictado en curso

    /// El crudo se apunta aquí antes del formateo y se borra al guardarse en
    /// el historial. Un cierre a mitad (crash, reinstalación) ya no pierde
    /// lo dictado: el siguiente arranque lo rescata. Un ARCHIVO POR DICTADO
    /// (UUID): con dictados solapados (Deshacer), el clear de uno no puede
    /// borrar la red del otro.
    private static let pendingDictationDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".zuzurroflow/pending", isDirectory: true)

    private func writePendingDictation(_ text: String, duration: Double) -> URL {
        try? FileManager.default.createDirectory(
            at: Self.pendingDictationDir, withIntermediateDirectories: true)
        let url = Self.pendingDictationDir
            .appendingPathComponent(UUID().uuidString + ".txt")
        let payload = "\(duration)\n" + text
        try? payload.data(using: .utf8)?.write(to: url)
        return url
    }

    private func clearPendingDictation(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func recoverPendingDictationIfAny() {
        let fm = FileManager.default
        var urls = ((try? fm.contentsOfDirectory(
            at: Self.pendingDictationDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }
        // Compat con la primera versión (archivo único).
        let legacy = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".zuzurroflow/pending-dictation.txt")
        if fm.fileExists(atPath: legacy.path) { urls.append(legacy) }

        var recovered = 0
        for url in urls {
            let payload = (try? Data(contentsOf: url))
                .flatMap { String(data: $0, encoding: .utf8) }
            try? fm.removeItem(at: url)
            guard let payload else { continue }
            let lines = payload.split(separator: "\n", maxSplits: 1,
                                      omittingEmptySubsequences: false)
            let duration = lines.first.flatMap { Double($0) } ?? 0
            let text = lines.count > 1
                ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard !text.isEmpty else { continue }
            Log.info("[History] dictado RECUPERADO de un cierre a mitad del formateo (\(text.count) chars)")
            history?.save(raw: text, formatted: text, duration: duration,
                          targetApp: nil, engine: "recuperado")
            lastTranscript = text
            recovered += 1
        }
        if recovered > 0 {
            toast.show(recovered == 1
                ? "Dictado recuperado — está en el historial (y en pegar-último)"
                : "\(recovered) dictados recuperados — en el historial", duration: 5)
        }
    }

    /// Entrega el texto final: lo guarda como "último" y lo pega en la app destino.
    /// Memoria del dictado anterior para el espaciado inteligente en campos
    /// que no exponen su contenido por Accesibilidad (Electron…).
    private var lastDeliveryEndedSentence = false
    private var lastDeliveryBundle: String?

    private func deliver(_ rawText: String) {
        // Espaciado inteligente (estilo Wispr): los campos de chat suelen
        // recortar espacios FINALES pegados, así que el espacio va DELANTE
        // del nuevo dictado cuando hace falta.
        var text = rawText
        if let window = FocusedFieldInspector.textBeforeCaret() {
            // Ventana de caracteres antes del cursor → decisión pura
            // (espacio por el último char; mayúscula por el último char
            // SIGNIFICATIVO, saltando espacios fantasma de campos web).
            let d = JoinDecision.decide(before: window)
            if d.space { text = " " + text }
            if d.lowercase {
                text = Self.lowercasedStart(text, keepingDictionaryWords: casingKeepWords())
            }
            let shown = window
                .replacingOccurrences(of: "\n", with: "⏎")
                .replacingOccurrences(of: "\t", with: "⇥")
                .replacingOccurrences(of: "\u{00A0}", with: "⍽")
            Log.info("[AX] antes-del-cursor=\"\(shown)\" → espacio=\(d.space ? "sí" : "no"), minúscula=\(d.lowercase ? "sí" : "no")")
        } else if targetTracker.targetBundleID == lastDeliveryBundle, lastTranscript != nil {
            // Campo opaco (sin AX): encadenando en la misma app.
            text = " " + text
            if !lastDeliveryEndedSentence {
                // El dictado anterior quedó a MEDIAS → continuar en minúscula.
                text = Self.lowercasedStart(text, keepingDictionaryWords: casingKeepWords())
            }
            Log.info("[AX] campo opaco → espacio=sí, minúscula=\(lastDeliveryEndedSentence ? "no" : "sí") (anterior \(lastDeliveryEndedSentence ? "cerró" : "no cerró") frase)")
        }
        lastDeliveryEndedSentence = Self.endsSentence(rawText)
        lastDeliveryBundle = targetTracker.targetBundleID
        lastTranscript = text
        appState.recordingState = .pasting
        // ¿Dictando DENTRO del Scratchpad? (su ventana tiene el foco) → pegar
        // ahí, sin reactivar la app externa que el tracker recuerda (esa era
        // la causa de que el texto se fuera a la app anterior).
        let intoScratchpad = ScratchpadWindowController.shared.isKeyWindow
        if intoScratchpad {
            ScratchpadWindowController.shared.focus()
        }
        // Si la app destino YA está delante (el caso normal: dictas donde
        // escribes), no hay que reactivar nada ni esperar el cambio de foco.
        let alreadyFront = intoScratchpad
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == targetTracker.targetBundleID
        if !alreadyFront {
            targetTracker.activateTarget()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (alreadyFront ? 0.02 : 0.12)) { [weak self] in
            guard let self else { return }
            // Sin campo de texto activo: no lanzar un ⌘V fantasma (en el
            // Finder pegaría archivos…). El texto ya vive en el portapapeles
            // propio (Recientes + ⌃⇧⌘V), listo para cuando haga falta.
            guard FocusedFieldInspector.focusedTextElement() != nil else {
                Log.info("Sin campo de TEXTO activo — mostrando tarjeta de transcripción")
                self.toast.showTranscriptCard(text)
                self.appState.recordingState = .idle
                return
            }
            let ok = self.paster.paste(text)
            if let t0 = self.stopInstant {
                Log.info(String(format: "[Perf] parar→pegar: %.2fs", Date().timeIntervalSince(t0)))
                self.stopInstant = nil
            }
            // (El sonido de paste está desactivado a petición del usuario —
            // el asset sigue en el bundle por si algún día lo quiere.)
            if !ok {
                Log.info("Texto no pegado (sin permiso). Disponible con el atajo de pegar-último.")
                self.toast.show("No pude pegar — falta permiso de Accesibilidad", duration: 3.5)
            }
            self.appState.recordingState = .idle
            // Retener el campo para aprender de tus correcciones manuales
            // (esperar a que el ⌘V aterrice antes de capturarlo).
            if ok, let store = self.history {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.learner.recordPaste(text, store: store) { [weak self] added in
                        self?.showLearnedToast(added, store: store)
                    }
                }
            }
        }
    }

    /// ¿El texto termina cerrando la frase? Ignora comillas/cierres y
    /// espacios finales ("…dijo.»" también cuenta como frase cerrada).
    static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "»", "”", "’", ")", "]", "}", " ", "\n", "\t"]
        var t = Substring(text)
        while let last = t.last, closers.contains(last) { t = t.dropLast() }
        return t.last.map { ".!?…".contains($0) } ?? false
    }

    /// Términos leídos del campo destino en el último dictado (contexto vivo).
    private var lastContextTerms: [String] = []

    /// Palabras cuya grafía se respeta al decidir minúscula inicial:
    /// diccionario personal + términos vistos en el campo actual (los
    /// compuestos "Wispr Flow" también cuentan por su primera palabra).
    private func casingKeepWords() -> [String] {
        (history?.dictionaryWords().map(\.word) ?? [])
            + lastContextTerms.flatMap { $0.split(separator: " ").map(String.init) }
    }

    /// Minúscula inicial para continuar una frase abierta — respetando
    /// nombres propios del diccionario personal.
    static func lowercasedStart(_ text: String, keepingDictionaryWords dict: [String]) -> String {
        let trimmedPrefix = text.prefix(while: { $0 == " " })
        let body = text.dropFirst(trimmedPrefix.count)
        guard let first = body.first, first.isUppercase else { return text }
        // Primera palabra del texto:
        let firstWord = body.prefix(while: { $0.isLetter || $0.isNumber })
        // Si es una palabra del diccionario (nombre propio), conservar su forma.
        if dict.contains(where: { $0.caseInsensitiveCompare(String(firstWord)) == .orderedSame }) {
            return text
        }
        // Si la palabra va TODA en mayúsculas (sigla: VPS, VSL), conservar.
        if firstWord.count > 1, firstWord.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            return text
        }
        return trimmedPrefix + first.lowercased() + body.dropFirst()
    }

    /// Toast de palabras aprendidas con Deshacer.
    private func showLearnedToast(_ added: [(correct: String, heard: String, id: Int64)],
                                  store: HistoryStore) {
        if added.count == 1 {
            let entry = added[0]
            toast.show("«\(entry.correct)» añadida al diccionario ✨",
                       actionTitle: "Deshacer") { store.deleteDictWord(id: entry.id) }
        } else if added.count > 1 {
            let ids = added.map(\.id)
            toast.show("\(added.count) palabras añadidas al diccionario ✨",
                       actionTitle: "Deshacer") { ids.forEach { store.deleteDictWord(id: $0) } }
        }
    }

    /// Palabras iniciales confirmadas por el usuario (una sola vez por versión).
    private func seedDictionaryIfNeeded(_ store: HistoryStore) {
        if !UserDefaults.standard.bool(forKey: "dictionarySeeded.v1") {
            UserDefaults.standard.set(true, forKey: "dictionarySeeded.v1")
            store.addDictWord("ZuzurroFlow", replacement: "Susurro Flow")
            store.addDictWord("VSL")
            store.addDictWord("VPS")
            store.addDictWord("Kie")
            Log.info("[Dictionary] Sembradas 4 palabras iniciales")
        }
        if !UserDefaults.standard.bool(forKey: "dictionarySeeded.v2") {
            UserDefaults.standard.set(true, forKey: "dictionarySeeded.v2")
            store.addDictWord("portapapeles", replacement: "puerta papeles")
        }
        if !UserDefaults.standard.bool(forKey: "dictionarySeeded.v3") {
            UserDefaults.standard.set(true, forKey: "dictionarySeeded.v3")
            store.addDictWord("pantalla", replacement: "pan día, pan dia, Pan Día")
        }
        if !UserDefaults.standard.bool(forKey: "dictionarySeeded.v4") {
            UserDefaults.standard.set(true, forKey: "dictionarySeeded.v4")
            // CADA MARCA SE RESPETA: sonidos "zuzurro/susurro" → ZuzurroFlow;
            // sonidos "whisper/wisper" → Wispr Flow. Nunca cruzar marcas.
            store.setReplacement(
                word: "ZuzurroFlow",
                replacement: "Susurro Flow, Zuzurro Flow, Susurroflow, Zuzurroflo, Zuzuro Flow, Susurro flou"
            )
            store.addDictWord(
                "Wispr Flow",
                replacement: "Whisper Flow, WhisperFlow, Wisper Flow, Wisperflow, Whisperflou, Guisper Flow"
            )
        }
        if !UserDefaults.standard.bool(forKey: "dictionarySeeded.v5") {
            UserDefaults.standard.set(true, forKey: "dictionarySeeded.v5")
            // Rebranding: la app ahora se llama Dictator. Variantes claras del
            // ASR — OJO: "dictador" a secas NO se mapea (palabra real en
            // español); si el usuario nunca la usa, puede añadirla él.
            store.addDictWord("Dictator", replacement: "Dictater, Dicteitor, Dictéitor, Dik Tator, Dictaitor")
        }
    }

    /// Pega el último transcript sin volver a dictar (portapapeles propio).
    func pasteLast() {
        let text = history?.latest(1).first?.formattedText ?? lastTranscript
        guard let text else { return }
        paste(text: text)
    }

    /// Pega un texto arbitrario (usado por Recientes y pegar-último).
    func paste(text: String) {
        targetTracker.captureNow()
        targetTracker.activateTarget()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.paster.paste(text)
        }
    }
}
