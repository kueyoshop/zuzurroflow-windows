import SwiftUI

extension Notification.Name {
    /// Publicada cuando cambian ajustes que requieren re-aplicar (perfil hotkey).
    static let zzfSettingsChanged = Notification.Name("zzf.settingsChanged")
}

/// Ajustes: atajos personalizables, motor de pulido, nivel de limpieza, Kie.
struct SettingsView: View {
    var history: HistoryStore?
    @State private var backupResult: String?
    @State private var profile = SettingsStore.shared.hotkeyProfile
    @State private var engine = SettingsStore.shared.formatterEngine
    @State private var level = SettingsStore.shared.cleanupLevel
    @State private var kieKey = SettingsStore.shared.kieApiKey ?? ""
    @State private var anthropicKey = SettingsStore.shared.anthropicApiKey ?? ""
    @State private var asrLanguage = SettingsStore.shared.asrLanguageMode
    @State private var autoPrimary = SettingsStore.shared.asrAutoPrimary
    @State private var appleRescue = SettingsStore.shared.appleRescueEnabled
    @State private var preferBuiltInMic = SettingsStore.shared.preferBuiltInMic
    @State private var soundsOn = SettingsStore.shared.soundsEnabled
    @State private var micSelection = SettingsStore.shared.micSelection
    @State private var micDevices: [(name: String, uid: String)] = []
    @State private var pttDisplay = SettingsStore.shared.pushToTalkCombo.displayName
    @State private var hfDisplay = SettingsStore.shared.handsFreeCombo?.displayName
    @State private var cmdDisplay = SettingsStore.shared.commandCombo.displayName
    @State private var recording: RecordingTarget?

    enum RecordingTarget: String, Identifiable {
        case ptt, handsFree, command
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("Atajos de teclado") {
                LabeledContent {
                    HStack(spacing: 8) {
                        ComboBadge(text: pttDisplay)
                        Button("Cambiar") { recording = .ptt }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mantener para hablar")
                        Text("Doble toque = manos libres").font(.caption).foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        ComboBadge(text: hfDisplay ?? "—")
                        Button("Cambiar") { recording = .handsFree }
                        if hfDisplay != nil {
                            Button("Quitar") {
                                SettingsStore.shared.handsFreeCombo = nil
                                hfDisplay = nil
                                NotificationCenter.default.post(name: .zzfSettingsChanged, object: nil)
                            }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manos libres (acorde)")
                        Text("Un toque empieza, otro termina").font(.caption).foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        ComboBadge(text: cmdDisplay)
                        Button("Cambiar") { recording = .command }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Command Mode")
                        Text("Selecciona texto, mantén y dicta la orden").font(.caption).foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Pegar último dictado") {
                    Text(profile == .transicion ? "⌃⇧⌘V" : "⌃⌘V (como Wispr)")
                }
                LabeledContent("Cancelar") { Text("Esc") }

                HStack {
                    Text("Presets").foregroundStyle(.secondary)
                    Spacer()
                    Button("Transición (⇧ dcha)") { applyPreset(.transicion) }
                    Button("Wispr (fn)") { applyPreset(.wispr) }
                }
            }

            Section("Transcripción") {
                Picker("Idioma", selection: $asrLanguage) {
                    Text("Auto — cambia entre español e inglés sobre la marcha").tag(ASRLanguageMode.auto)
                    Text("Español fijo (si Auto te mete trozos en inglés)").tag(ASRLanguageMode.es)
                    Text("English fijo").tag(ASRLanguageMode.en)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: asrLanguage) { SettingsStore.shared.asrLanguageMode = asrLanguage }

                if asrLanguage == .auto {
                    Picker("Idioma principal (Auto)", selection: $autoPrimary) {
                        Text("Español — el inglés debe demostrarse").tag("es")
                        Text("English — Spanish must prove itself").tag("en")
                    }
                    .onChange(of: autoPrimary) { SettingsStore.shared.asrAutoPrimary = autoPrimary }
                    Text("El ancla del modo Auto: tu idioma principal nunca se convierte al otro; los trozos en el otro idioma se verifican para filtrar alucinaciones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Rescatar alucinaciones con el motor de Apple", isOn: $appleRescue)
                        .onChange(of: appleRescue) {
                            SettingsStore.shared.appleRescueEnabled = appleRescue
                            if appleRescue { Task { _ = await AppleSpeechRescue.ensureAuthorized() } }
                        }
                    Text("Cuando un trozo sale en el idioma equivocado, lo re-escucha con el dictado de Apple forzando tu idioma principal (100% local). Necesita el permiso de Reconocimiento de voz. Solo actúa sobre el trozo alucinado, no ralentiza el dictado normal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Micrófono", selection: $micSelection) {
                    Text("Automático — sigue al sistema (AirPods, cable…)").tag("auto")
                    Text("Micrófono del MacBook (máxima precisión en escritorio)").tag("builtin")
                    ForEach(micDevices, id: \.uid) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                .onChange(of: micSelection) {
                    SettingsStore.shared.micSelection = micSelection
                    // Libera el motor caliente: sin esto, el mic viejo
                    // seguía capturando hasta 25s tras cambiar la selección.
                    NotificationCenter.default.post(name: .zzfSettingsChanged, object: nil)
                }
                Text("Automático funciona en cualquier parte (con AirPods te sigue aunque te alejes). Si notas menos precisión con AirPods, cambia aquí al mic del MacBook cuando estés en el escritorio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if micSelection == "auto" {
                    Toggle("Con AirPods: captura doble (AirPods + mic del MacBook)", isOn: $preferBuiltInMic)
                        .onChange(of: preferBuiltInMic) {
                            SettingsStore.shared.preferBuiltInMic = preferBuiltInMic
                            NotificationCenter.default.post(name: .zzfSettingsChanged, object: nil)
                        }
                    Text("Los AirPods tardan ~2 s en activar su micrófono al empezar a grabar (se comían las primeras palabras). Con esto activado se graba con LOS DOS micrófonos a la vez y gana el que mejor te oiga: en el escritorio, el del MacBook (instantáneo y más preciso); caminando lejos del Mac, los AirPods. No tienes que elegir nada.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Ondas de voz") {
                WaveformColorSettings()
            }

            Section("Pulido con IA") {
                Picker("Motor", selection: $engine) {
                    Text("Claude (Anthropic directo) — máxima calidad, ~1-2s — recomendado").tag(FormatterEngine.anthropic)
                    Text("Apple (local, ~1s, gratis) — más flojo, a veces reescribe").tag(FormatterEngine.apple)
                    Text("Claude vía Kie (calidad alta pero 7-8s, lento)").tag(FormatterEngine.kie)
                    Text("Desactivado (texto crudo al instante)").tag(FormatterEngine.off)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: engine) { SettingsStore.shared.formatterEngine = engine }

                Picker("Nivel de limpieza", selection: $level) {
                    Text("Ligero — solo puntuación y muletillas").tag(CleanupLevel.light)
                    Text("Medio — + auto-correcciones, listas y párrafos").tag(CleanupLevel.medium)
                    Text("Alto — + mejora de claridad").tag(CleanupLevel.high)
                }
                .onChange(of: level) { SettingsStore.shared.cleanupLevel = level }

                if engine == .anthropic {
                    SecureField("Clave API de Anthropic (empieza por sk-ant-…)", text: $anthropicKey)
                        .onChange(of: anthropicKey) {
                            SettingsStore.shared.anthropicApiKey = anthropicKey.isEmpty ? nil : anthropicKey
                        }
                    Text(anthropicKey.isEmpty
                         ? "Pega tu clave de console.anthropic.com. Mientras no haya clave (o sin internet), el pulido usa Apple como respaldo. Coste ~1-2 $/mes; el reconocimiento de voz sigue 100% local."
                         : "Clave configurada ✓. El texto a pulir viaja a Anthropic; el reconocimiento de voz sigue 100% local.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if engine == .kie {
                    SecureField("Clave API de kie.ai", text: $kieKey)
                        .onChange(of: kieKey) {
                            SettingsStore.shared.kieApiKey = kieKey.isEmpty ? nil : kieKey
                        }
                }
            }

            Section("Copia de seguridad") {
                HStack(spacing: 10) {
                    Button("Exportar todo…") { exportBackup() }
                    Button("Importar…") { importBackup() }
                    if let backupResult {
                        Text(backupResult).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Un solo archivo con historial, diccionario, snippets y ajustes. Local — también sirve para llevar tus datos a otro equipo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sistema") {
                Toggle("Sonidos de dictado (empezar, parar, manos libres, cancelar)",
                       isOn: $soundsOn)
                    .onChange(of: soundsOn) { SettingsStore.shared.soundsEnabled = soundsOn }
                LabeledContent("Arranque") { Text("Se abre automáticamente al iniciar sesión") }
                LabeledContent("Transcripción") { Text("Parakeet v3 · 100% local (Neural Engine)") }
                LabeledContent("Privacidad") { Text("Tu voz nunca sale de este Mac") }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(12)
        .onAppear {
            micDevices = AudioDevices.allInputDevices().map { ($0.name, $0.uid) }
        }
        .sheet(item: $recording) { target in
            ShortcutRecorderSheet(
                title: {
                    switch target {
                    case .ptt: "Tecla para mantener y hablar"
                    case .handsFree: "Acorde de manos libres"
                    case .command: "Tecla de Command Mode"
                    }
                }(),
                allowModifierOnly: target != .handsFree
            ) { combo in
                switch target {
                case .ptt:
                    SettingsStore.shared.pushToTalkCombo = combo
                    pttDisplay = combo.displayName
                case .handsFree:
                    SettingsStore.shared.handsFreeCombo = combo
                    hfDisplay = combo.displayName
                case .command:
                    SettingsStore.shared.commandCombo = combo
                    cmdDisplay = combo.displayName
                }
                NotificationCenter.default.post(name: .zzfSettingsChanged, object: nil)
            }
        }
    }

    private func exportBackup() {
        guard let history else { backupResult = "Sin base de datos"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "dictator-backup-\(df.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try BackupManager.export(history: history)
            try data.write(to: url)
            let mb = Double(data.count) / 1_048_576
            backupResult = String(format: "Exportado (%.1f MB) ✓", mb)
            Log.info("[Backup] exportado a \(url.lastPathComponent) (\(data.count) bytes)")
        } catch {
            backupResult = "Error al exportar"
            Log.error("[Backup] export: \(error)")
        }
    }

    private func importBackup() {
        guard let history else { backupResult = "Sin base de datos"; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let r = try BackupManager.restore(data: data, into: history)
            backupResult = "+\(r.transcripts) dictados, +\(r.dictWords) palabras, +\(r.snippets) snippets ✓"
            Log.info("[Backup] importado: \(r.transcripts) transcripts, \(r.dictWords) palabras, \(r.snippets) snippets, \(r.settings) ajustes")
            NotificationCenter.default.post(name: .zzfSettingsChanged, object: nil)
        } catch {
            backupResult = "Error al importar (¿archivo válido?)"
            Log.error("[Backup] import: \(error)")
        }
    }

    private func applyPreset(_ p: HotkeyProfile) {
        SettingsStore.shared.applyProfilePreset(p)
        profile = p
        pttDisplay = SettingsStore.shared.pushToTalkCombo.displayName
        hfDisplay = SettingsStore.shared.handsFreeCombo?.displayName
        NotificationCenter.default.post(name: .zzfSettingsChanged, object: nil)
    }
}

/// Ajuste del color de las ondas del pill: paleta + color libre + vista
/// previa EN VIVO (una pastilla simulada dictando). Detalle que Wispr no tiene.
struct WaveformColorSettings: View {
    @State private var hex = SettingsStore.shared.waveformColorHex
    @State private var customColor = Color(hex: SettingsStore.shared.waveformColorHex) ?? WaveformView.defaultColor

    private static let options: [(name: String, hex: String)] = [
        ("Rojo de siempre", "#FF4539"),
        ("Amarillo Dictator", "#FCBE05"),
        ("Blanco (Wispr)", "#FFFFFF"),
        ("Azul", "#4DA6FF"),
        ("Verde", "#30D158"),
        ("Rosa", "#FF6FA5"),
        ("Naranja", "#FF9F0A"),
        ("Morado", "#BF5AF2"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Self.options, id: \.hex) { option in
                    let selected = option.hex.compare(hex, options: .caseInsensitive) == .orderedSame
                    Circle()
                        .fill(Color(hex: option.hex) ?? .white)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 22, height: 22)
                        .padding(3)
                        .overlay(
                            Circle().strokeBorder(
                                selected ? Color.primary.opacity(0.8) : .clear,
                                lineWidth: 2
                            )
                        )
                        .contentShape(Circle())
                        .onTapGesture { select(option.hex) }
                        .help(option.name)
                }
                Spacer()
                ColorPicker("Otro", selection: $customColor, supportsOpacity: false)
                    .onChange(of: customColor) {
                        if let h = customColor.hexString { select(h) }
                    }
            }

            // Vista previa en vivo: la pastilla "dictando" con el color elegido.
            WaveformPillPreview(color: Color(hex: hex) ?? WaveformView.defaultColor)

            Text("Así se verán las ondas mientras dictas. El cambio se guarda al instante.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func select(_ newHex: String) {
        hex = newHex
        SettingsStore.shared.waveformColorHex = newHex
    }
}

/// Réplica del pill expandido con ondas animadas por una "voz" sintética.
struct WaveformPillPreview: View {
    let color: Color
    @StateObject private var model = WaveformModel()
    @State private var timer: Timer?
    @State private var t: Double = 0

    var body: some View {
        ZStack {
            // Fondo tipo escritorio para juzgar el contraste real del pill.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(.white.opacity(0.16))
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 18, height: 18)

                WaveformView(model: model, color: color)
                    .frame(width: 56, height: 16)

                ZStack {
                    Circle().fill(.white)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                }
                .frame(width: 18, height: 18)
            }
            .frame(width: 118, height: 26)
            .background(
                Capsule()
                    .fill(Color.black)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            )
        }
        .frame(height: 72)
        .onAppear {
            model.setActive(true)
            t = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                MainActor.assumeIsolated {
                    t += 0.12
                    // Voz sintética: sube y baja con pausas naturales.
                    let voice = 0.45 + 0.35 * sin(t * 1.9) * sin(t * 0.63)
                    model.setLevel(Float(max(0.16, voice)))
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
            model.setActive(false)
        }
    }
}

/// Cápsula visual del atajo (estética Wispr).
struct ComboBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.cardFill))
    }
}
