import Foundation

enum CleanupLevel: String, CaseIterable {
    case none, light, medium, high
}

enum ASRLanguageMode: String, CaseIterable {
    case auto   // auto-LID por utterance (recomendado para es/en mezclado)
    case es
    case en
}

enum FormatterEngine: String, CaseIterable {
    case apple      // Apple Foundation Models 3B: ~1s, gratis, offline; pero
                    // reescribe/inventa (el 3B es demasiado flojo).
    case anthropic  // Claude Haiku vía API oficial: máxima calidad, ~1-2s,
                    // barato (~1-2 $/mes). Sin red → fallback a Apple.
    case kie        // Claude Haiku vía kie.ai (intermediario): buena calidad
                    // pero 7-8s medidos — demasiado lento, en desuso.
    case off        // sin pulido IA: pegar transcripción cruda
}

/// Preferencias persistentes (UserDefaults). Crece por fases.
/// @unchecked Sendable: el único estado es UserDefaults, que es thread-safe.
final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let cleanupLevel = "cleanupLevel"
        static let asrLanguageMode = "asrLanguageMode"
        static let hotkeyProfile = "hotkeyProfile"
        static let formatterEngine = "formatterEngine"
        static let kieApiKey = "kieApiKey"
        static let anthropicApiKey = "anthropicApiKey"
        static let soundsEnabled = "soundsEnabled"
    }

    var soundsEnabled: Bool {
        get { defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.soundsEnabled) }
    }

    /// Color de las ondas de voz del pill, en hex sRGB "#RRGGBB".
    /// Default: el rojo de siempre de la casa.
    var waveformColorHex: String {
        get { defaults.string(forKey: "waveformColorHex") ?? "#FF4539" }
        set { defaults.set(newValue, forKey: "waveformColorHex") }
    }

    /// Usar siempre el micrófono integrado del MacBook aunque haya
    /// AirPods/auriculares conectados (su mic degrada mucho el dictado).
    var preferBuiltInMic: Bool {
        get { defaults.object(forKey: "preferBuiltInMic") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "preferBuiltInMic") }
    }

    /// Micrófono elegido: "auto" = seguir al sistema (AirPods puestos → su
    /// mic; cable → ese; nada → MacBook), como hace macOS. "builtin" fuerza
    /// el del MacBook (máxima precisión en escritorio). O un UID concreto.
    var micSelection: String {
        get { defaults.string(forKey: "micSelection") ?? "auto" }
        set { defaults.set(newValue, forKey: "micSelection") }
    }

    var formatterEngine: FormatterEngine {
        get { FormatterEngine(rawValue: defaults.string(forKey: Keys.formatterEngine) ?? "") ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: Keys.formatterEngine) }
    }

    var kieApiKey: String? {
        get {
            let v = defaults.string(forKey: Keys.kieApiKey)
            return (v?.isEmpty == false) ? v : nil
        }
        set { defaults.set(newValue ?? "", forKey: Keys.kieApiKey) }
    }

    /// Modelo de Claude para el pulido directo. Default: Haiku (rápido,
    /// barato). Se puede cambiar a "claude-sonnet-4-6" (más listo, ~2x más
    /// lento) o "claude-haiku-4-5" sin recompilar — solo cambia este ajuste.
    var anthropicModel: String {
        get { defaults.string(forKey: "anthropicModel") ?? "claude-haiku-4-5" }
        set { defaults.set(newValue, forKey: "anthropicModel") }
    }

    /// Clave de la API oficial de Anthropic (console.anthropic.com) para el
    /// motor de pulido Claude Haiku directo. Se guarda tal cual la pega el
    /// usuario, con los espacios recortados.
    var anthropicApiKey: String? {
        get {
            let v = defaults.string(forKey: Keys.anthropicApiKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty == false) ? v : nil
        }
        set {
            defaults.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                         forKey: Keys.anthropicApiKey)
        }
    }

    /// Perfil de atajos. Default = Transición (no pisa a Wispr Flow).
    var hotkeyProfile: HotkeyProfile {
        get { HotkeyProfile(rawValue: defaults.string(forKey: Keys.hotkeyProfile) ?? "") ?? .transicion }
        set { defaults.set(newValue.rawValue, forKey: Keys.hotkeyProfile) }
    }

    // MARK: - Atajos personalizados (estilo Wispr)

    private func combo(forKey key: String) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private func setCombo(_ combo: KeyCombo?, forKey key: String) {
        if let combo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Mantener-para-hablar. Default: según perfil.
    var pushToTalkCombo: KeyCombo {
        get { combo(forKey: "pttCombo") ?? (hotkeyProfile == .wispr ? .fnHold : .rightShiftHold) }
        set { setCombo(newValue, forKey: "pttCombo") }
    }

    /// Acorde de manos libres (además del doble-toque del PTT). Opcional.
    var handsFreeCombo: KeyCombo? {
        get { combo(forKey: "hfCombo") ?? (hotkeyProfile == .wispr ? .fnSpace : nil) }
        set { setCombo(newValue, forKey: "hfCombo") }
    }

    /// Command Mode: mantener y dictar una orden sobre el texto seleccionado.
    var commandCombo: KeyCombo {
        get { combo(forKey: "cmdCombo") ?? .rightOptionHold }
        set { setCombo(newValue, forKey: "cmdCombo") }
    }

    /// Aplica un preset completo (borra los custom → vuelven los defaults del perfil).
    func applyProfilePreset(_ profile: HotkeyProfile) {
        hotkeyProfile = profile
        setCombo(nil, forKey: "pttCombo")
        setCombo(nil, forKey: "hfCombo")
    }

    var cleanupLevel: CleanupLevel {
        get { CleanupLevel(rawValue: defaults.string(forKey: Keys.cleanupLevel) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Keys.cleanupLevel) }
    }

    /// Idioma PRINCIPAL del modo Auto ("es"/"en"): el ancla del rescate
    /// anti-alucinación. Los segmentos en el otro idioma deben demostrar
    /// que son genuinos; el principal nunca se fuerza al invitado.
    var asrAutoPrimary: String {
        get { defaults.string(forKey: "asrAutoPrimary") ?? "es" }
        set { defaults.set(newValue, forKey: "asrAutoPrimary") }
    }

    /// Rescatar segmentos alucinados con el motor de voz de Apple (fuerza el
    /// idioma principal a nivel acústico). Requiere permiso de Reconocimiento
    /// de voz. On por defecto; degrada solo si falta el permiso.
    var appleRescueEnabled: Bool {
        get { defaults.object(forKey: "appleRescueEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "appleRescueEnabled") }
    }

    var asrLanguageMode: ASRLanguageMode {
        // AUTO: el usuario cambia de idioma a mitad de dictado y quiere ambos
        // perfectos. (Los flips raros a inglés venían del mic de los AirPods —
        // ver preferBuiltInMic. Si reaparecen: fijar Español en Ajustes.)
        get { ASRLanguageMode(rawValue: defaults.string(forKey: Keys.asrLanguageMode) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Keys.asrLanguageMode) }
    }
}
