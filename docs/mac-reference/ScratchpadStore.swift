import AppKit
import Foundation

/// Una nota del Scratchpad. El texto va en RTF para conservar el formato
/// (negrita, listas…) que aplica la barra de Formatting; `plain` se guarda
/// aparte para buscar y previsualizar sin desempaquetar el RTF.
struct ScratchNote: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String = "Untitled"
    var rtf: Data?
    var plain: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Título mostrado: el puesto por el usuario o la 1ª línea del texto.
    var displayTitle: String {
        if !title.isEmpty, title != "Untitled" { return title }
        let firstLine = plain.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = firstLine.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Untitled" : String(t.prefix(28))
    }
}

/// Persistencia multi-nota del Scratchpad: un JSON en la carpeta de datos.
/// Local y privado (nada de nube, a diferencia de Wispr). Migra sola la nota
/// única del formato viejo (scratchpad.txt) la primera vez.
final class ScratchpadStore: @unchecked Sendable {
    static let shared = ScratchpadStore()
    private let url: URL
    private let legacyURL: URL
    private let lock = NSLock()
    private var cache: [ScratchNote]?

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZuzurroFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("scratchpad-notes.json")
        legacyURL = dir.appendingPathComponent("scratchpad.txt")
    }

    // MARK: - Notas

    func loadAll() -> [ScratchNote] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        var notes: [ScratchNote] = []
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ScratchNote].self, from: data) {
            notes = decoded
        } else if let legacy = try? String(contentsOf: legacyURL, encoding: .utf8),
                  !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Migración del scratchpad de nota única.
            notes = [ScratchNote(title: "Untitled", rtf: nil, plain: legacy)]
            persist(notes)
        }
        cache = notes
        return notes
    }

    func save(_ note: ScratchNote) {
        lock.lock()
        var notes = cache ?? []
        var updated = note
        updated.updatedAt = Date()
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = updated
        } else {
            notes.append(updated)
        }
        cache = notes
        let snapshot = notes
        lock.unlock()
        persist(snapshot)
    }

    func delete(id: UUID) {
        lock.lock()
        var notes = cache ?? []
        notes.removeAll { $0.id == id }
        cache = notes
        let snapshot = notes
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ notes: [ScratchNote]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Añade texto a la nota MÁS RECIENTE (o crea una) — lo usa el botón
    /// "enviar al Scratchpad" del toast.
    func append(_ text: String) {
        let notes = loadAll()
        var target = notes.max(by: { $0.updatedAt < $1.updatedAt }) ?? ScratchNote()
        let current = target.plain
        target.plain = current.isEmpty ? text : current + "\n\n" + text
        // Al añadir por esta vía se pierde el formato previo: se re-escribe
        // el RTF desde el texto plano resultante.
        target.rtf = Self.rtf(from: AttributedString(target.plain))
        save(target)
    }

    // MARK: - RTF ↔ AttributedString

    static func rtf(from attributed: AttributedString) -> Data? {
        let ns = NSAttributedString(attributed)
        return try? ns.data(from: NSRange(location: 0, length: ns.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func attributed(from rtf: Data?, fallbackPlain: String) -> AttributedString {
        guard let rtf,
              let ns = try? NSAttributedString(
                  data: rtf,
                  options: [.documentType: NSAttributedString.DocumentType.rtf],
                  documentAttributes: nil)
        else { return AttributedString(fallbackPlain) }
        return AttributedString(ns)
    }
}
