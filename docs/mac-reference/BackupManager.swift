import Foundation

/// Copia de seguridad COMPLETA en un solo archivo JSON: historial +
/// diccionario + snippets + ajustes. Local (sin nube), legible, y sirve
/// para migrar a otro equipo (incluido el PC con la app hermana de Windows).
struct DictatorBackup: Codable {
    var version: Int
    var exportedAt: Date
    var app: String
    var transcripts: [Transcript]
    var dictWords: [HistoryStore.DictWord]
    var snippets: [HistoryStore.Snippet]
    /// Ajustes simples serializados como texto; los atajos van en base64.
    var settings: [String: String]
}

enum BackupManager {

    /// Claves de UserDefaults que viajan en la copia (texto plano).
    private static let settingKeys = [
        "cleanupLevel", "asrLanguageMode", "asrAutoPrimary", "formatterEngine",
        "hotkeyProfile", "soundsEnabled", "micSelection", "waveformColorHex",
        "appleRescueEnabled", "preferBuiltInMic", "kieApiKey",
    ]
    /// Atajos personalizados (Data JSON en defaults → base64).
    private static let comboKeys = ["pttCombo", "hfCombo", "cmdCombo"]

    static func export(history: HistoryStore) throws -> Data {
        let defaults = UserDefaults.standard
        var settings: [String: String] = [:]
        for key in settingKeys {
            if let value = defaults.object(forKey: key) {
                settings[key] = String(describing: value)
            }
        }
        for key in comboKeys {
            if let data = defaults.data(forKey: key) {
                settings["combo." + key] = data.base64EncodedString()
            }
        }

        let backup = DictatorBackup(
            version: 1,
            exportedAt: Date(),
            app: "Dictator",
            transcripts: history.allTranscripts(),
            dictWords: history.dictionaryWords(),
            snippets: history.snippets(),
            settings: settings
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    struct RestoreResult {
        var transcripts = 0
        var dictWords = 0
        var snippets = 0
        var settings = 0
    }

    /// Importa FUSIONANDO: lo existente no se toca; duplicados se saltan.
    static func restore(data: Data, into history: HistoryStore) throws -> RestoreResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(DictatorBackup.self, from: data)

        var result = RestoreResult()
        for t in backup.transcripts where history.importTranscript(t) {
            result.transcripts += 1
        }
        for w in backup.dictWords where history.importDictWord(w) {
            result.dictWords += 1
        }
        for s in backup.snippets where history.importSnippet(s) {
            result.snippets += 1
        }

        let defaults = UserDefaults.standard
        for (key, value) in backup.settings {
            if key.hasPrefix("combo.") {
                let realKey = String(key.dropFirst("combo.".count))
                if let data = Data(base64Encoded: value) {
                    defaults.set(data, forKey: realKey)
                    result.settings += 1
                }
            } else if settingKeys.contains(key) {
                // Restaurar con el tipo correcto (bools llegan como "0"/"1").
                if value == "0" || value == "1" {
                    defaults.set(value == "1", forKey: key)
                } else {
                    defaults.set(value, forKey: key)
                }
                result.settings += 1
            }
        }
        return result
    }
}
