import Foundation
import GRDB

/// Un dictado guardado: siempre el crudo Y el pulido (para "Deshacer arreglo IA").
struct Transcript: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transcript"

    var id: Int64?
    var createdAt: Date
    var rawText: String
    var formattedText: String
    var durationSecs: Double
    var targetApp: String?
    var wordCount: Int
    var engine: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Persistencia SQLite (GRDB) en ~/Library/Application Support/ZuzurroFlow/.
/// GRDB DatabaseQueue es thread-safe; las operaciones son de milisegundos.
final class HistoryStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZuzurroFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("zuzurro.sqlite")

        dbQueue = try DatabaseQueue(path: dbURL.path)
        try migrate()
        importLegacyHistoryIfNeeded()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "transcript") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("rawText", .text).notNull()
                t.column("formattedText", .text).notNull()
                t.column("durationSecs", .double).notNull()
                t.column("targetApp", .text)
                t.column("wordCount", .integer).notNull()
                t.column("engine", .text).notNull()
            }
        }
        migrator.registerMigration("v2-dictionary") { db in
            try db.create(table: "dictword") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("word", .text).notNull().unique()
                t.column("replacement", .text)      // "mal oído" → word (opcional)
                t.column("starred", .boolean).notNull().defaults(to: false)
                t.column("autoLearned", .boolean).notNull().defaults(to: false)
                t.column("usageCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v3-snippets") { db in
            try db.create(table: "snippet") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trigger", .text).notNull().unique()   // frase dictada
                t.column("expansion", .text).notNull()          // texto que inserta
                t.column("createdAt", .datetime).notNull()
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Operaciones

    @discardableResult
    func save(raw: String, formatted: String, duration: Double,
              targetApp: String?, engine: String) -> Transcript? {
        var record = Transcript(
            id: nil,
            createdAt: Date(),
            rawText: raw,
            formattedText: formatted,
            durationSecs: duration,
            targetApp: targetApp,
            wordCount: formatted.split(whereSeparator: \.isWhitespace).count,
            engine: engine
        )
        do {
            try dbQueue.write { db in
                try record.insert(db)
            }
            return record
        } catch {
            Log.error("[History] Error guardando: \(error)")
            return nil
        }
    }

    /// usageCount +1 para las palabras del diccionario que dispararon en el
    /// último dictado (era un contador muerto: se creaba a 0 y nada lo subía,
    /// dejando la ordenación "más usadas primero" como estadística falsa).
    func incrementDictUsage(words: [String]) {
        guard !words.isEmpty else { return }
        try? dbQueue.write { db in
            for w in words {
                try db.execute(
                    sql: "UPDATE dictword SET usageCount = usageCount + 1 WHERE word = ?",
                    arguments: [w])
            }
        }
    }

    func latest(_ limit: Int = 5) -> [Transcript] {
        (try? dbQueue.read { db in
            try Transcript
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Copia de seguridad (export/import fusionando)

    func allTranscripts() -> [Transcript] {
        (try? dbQueue.read { db in
            try Transcript.order(Column("createdAt").asc).fetchAll(db)
        }) ?? []
    }

    /// Inserta un transcript importado; salta duplicados (misma fecha+crudo).
    @discardableResult
    func importTranscript(_ t: Transcript) -> Bool {
        (try? dbQueue.write { db -> Bool in
            let dup = try Transcript
                .filter(Column("createdAt") == t.createdAt && Column("rawText") == t.rawText)
                .fetchCount(db)
            guard dup == 0 else { return false }
            var rec = t
            rec.id = nil
            try rec.insert(db)
            return true
        }) ?? false
    }

    /// Inserta una palabra importada conservando estrella/uso; salta duplicadas.
    @discardableResult
    func importDictWord(_ w: DictWord) -> Bool {
        (try? dbQueue.write { db -> Bool in
            let dup = try DictWord.filter(Column("word") == w.word).fetchCount(db)
            guard dup == 0 else { return false }
            var rec = w
            rec.id = nil
            try rec.insert(db)
            return true
        }) ?? false
    }

    /// Inserta un snippet importado; salta gatillos ya existentes.
    @discardableResult
    func importSnippet(_ s: Snippet) -> Bool {
        (try? dbQueue.write { db -> Bool in
            let dup = try Snippet.filter(Column("trigger") == s.trigger).fetchCount(db)
            guard dup == 0 else { return false }
            var rec = s
            rec.id = nil
            try rec.insert(db)
            return true
        }) ?? false
    }

    func search(_ query: String, limit: Int = 100) -> [Transcript] {
        (try? dbQueue.read { db in
            try Transcript
                .filter(Column("formattedText").like("%\(query)%") ||
                        Column("rawText").like("%\(query)%"))
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func all(limit: Int = 500) -> [Transcript] {
        (try? dbQueue.read { db in
            try Transcript.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }) ?? []
    }

    func delete(id: Int64) {
        _ = try? dbQueue.write { db in
            try Transcript.deleteOne(db, key: id)
        }
    }

    // Estadísticas para el dashboard (Fase 9)
    struct Stats {
        var totalTranscripts: Int
        var totalWords: Int
        var totalSeconds: Double
        var streakDays: Int

        var averageWPM: Int {
            guard totalSeconds > 10 else { return 0 }
            return Int(Double(totalWords) / (totalSeconds / 60.0))
        }
    }

    func stats() -> Stats {
        (try? dbQueue.read { db in
            let count = try Transcript.fetchCount(db)
            let words = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(wordCount),0) FROM transcript") ?? 0
            let secs = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(durationSecs),0) FROM transcript") ?? 0
            // Racha: días consecutivos (hasta hoy o ayer) con ≥1 dictado.
            let days = try String.fetchAll(db, sql:
                "SELECT DISTINCT date(createdAt) FROM transcript ORDER BY 1 DESC LIMIT 366")
            let streak = Self.computeStreak(days: days)
            return Stats(totalTranscripts: count, totalWords: words, totalSeconds: secs, streakDays: streak)
        }) ?? Stats(totalTranscripts: 0, totalWords: 0, totalSeconds: 0, streakDays: 0)
    }

    private static func computeStreak(days: [String]) -> Int {
        guard !days.isEmpty else { return 0 }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let cal = Calendar.current

        var expected = cal.startOfDay(for: Date())
        var streak = 0
        for dayString in days {
            guard let day = fmt.date(from: dayString) else { break }
            let d = cal.startOfDay(for: day)
            if d == expected {
                streak += 1
                expected = cal.date(byAdding: .day, value: -1, to: expected)!
            } else if streak == 0, d == cal.date(byAdding: .day, value: -1, to: expected)! {
                // La racha puede empezar ayer (hoy aún sin dictar).
                streak += 1
                expected = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date()))!
            } else {
                break
            }
        }
        return streak
    }

    // MARK: - Diccionario personal (Fase 9 UI; el motor llega en Fase 10)

    struct DictWord: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "dictword"
        var id: Int64?
        var word: String
        var replacement: String?
        var starred: Bool
        var autoLearned: Bool
        var usageCount: Int
        var createdAt: Date

        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    }

    func dictionaryWords() -> [DictWord] {
        (try? dbQueue.read { db in
            try DictWord
                .order(Column("starred").desc, Column("usageCount").desc, Column("word"))
                .fetchAll(db)
        }) ?? []
    }

    /// Devuelve el id insertado, o nil si es duplicado/inválido.
    @discardableResult
    func addDictWord(_ word: String, replacement: String? = nil, autoLearned: Bool = false) -> Int64? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return nil }
        var rec = DictWord(id: nil, word: trimmed,
                           replacement: replacement?.trimmingCharacters(in: .whitespacesAndNewlines),
                           starred: false, autoLearned: autoLearned, usageCount: 0, createdAt: Date())
        do {
            try dbQueue.write { db in try rec.insert(db) }
            return rec.id
        } catch {
            return nil // duplicado u otro fallo
        }
    }

    func deleteDictWord(id: Int64) {
        _ = try? dbQueue.write { db in try DictWord.deleteOne(db, key: id) }
    }

    func toggleStar(id: Int64) {
        _ = try? dbQueue.write { db in
            try db.execute(sql: "UPDATE dictword SET starred = NOT starred WHERE id = ?", arguments: [id])
        }
    }

    /// Palabras por día (para el heatmap de racha). ["yyyy-MM-dd": palabras]
    func wordsPerDay(days: Int = 56) -> [String: Int] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT date(createdAt) AS d, SUM(wordCount) AS w
                FROM transcript
                WHERE createdAt >= datetime('now', ?)
                GROUP BY d
                """, arguments: ["-\(days) days"])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["d"] as String, $0["w"] as Int) })
        }) ?? [:]
    }

    /// Top apps destino por palabras dictadas.
    func wordsByApp(limit: Int = 5) -> [(app: String, words: Int)] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(targetApp, 'desconocida') AS a, SUM(wordCount) AS w
                FROM transcript GROUP BY a ORDER BY w DESC LIMIT ?
                """, arguments: [limit])
            return rows.map { ($0["a"] as String, $0["w"] as Int) }
        }) ?? []
    }

    // MARK: - Snippets (frase-gatillo dictada → texto fijo)

    struct Snippet: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "snippet"
        var id: Int64?
        var trigger: String
        var expansion: String
        var createdAt: Date
        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    }

    func snippets() -> [Snippet] {
        (try? dbQueue.read { db in
            try Snippet.order(Column("trigger")).fetchAll(db)
        }) ?? []
    }

    @discardableResult
    func addSnippet(trigger: String, expansion: String) -> Int64? {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 60, !e.isEmpty, e.count <= 4000 else { return nil }
        var rec = Snippet(id: nil, trigger: t, expansion: e, createdAt: Date())
        do {
            try dbQueue.write { db in try rec.insert(db) }
            return rec.id
        } catch { return nil }
    }

    func deleteSnippet(id: Int64) {
        _ = try? dbQueue.write { db in try Snippet.deleteOne(db, key: id) }
    }

    /// Fija/actualiza el "se oye como" de una palabra existente.
    func setReplacement(word: String, replacement: String?) {
        _ = try? dbQueue.write { db in
            try db.execute(sql: "UPDATE dictword SET replacement = ? WHERE word = ?",
                           arguments: [replacement, word])
        }
    }

    // MARK: - Migración del MVP Python (~/.zuzurroflow/history.json)

    private func importLegacyHistoryIfNeeded() {
        let flag = "legacyHistoryImported"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zuzurroflow/history.json")
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !items.isEmpty else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoSimple = ISO8601DateFormatter()

        var imported = 0
        try? dbQueue.write { db in
            for item in items {
                guard let text = item["text"] as? String, !text.isEmpty else { continue }
                let ts = item["timestamp"] as? String ?? ""
                let date = iso.date(from: ts) ?? isoSimple.date(from: ts) ?? Date.distantPast
                var rec = Transcript(
                    id: nil,
                    createdAt: date,
                    rawText: text,
                    formattedText: text,
                    durationSecs: item["duration"] as? Double ?? 0,
                    targetApp: nil,
                    wordCount: text.split(whereSeparator: \.isWhitespace).count,
                    engine: (item["model_used"] as? String).map { "legacy-\($0)" } ?? "legacy"
                )
                try rec.insert(db)
                imported += 1
            }
        }
        Log.info("[History] Importados \(imported) dictados del MVP Python")
    }
}
