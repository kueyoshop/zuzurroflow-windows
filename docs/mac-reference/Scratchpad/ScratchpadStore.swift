import Foundation

/// Persistencia del Scratchpad: un archivo de texto en la carpeta de datos.
/// Local y privado, como todo lo demás (nada de nube — a diferencia de Wispr).
final class ScratchpadStore: @unchecked Sendable {
    static let shared = ScratchpadStore()
    private let url: URL
    private let lock = NSLock()

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZuzurroFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("scratchpad.txt")
    }

    func load() -> String {
        lock.lock(); defer { lock.unlock() }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func save(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Añade texto al final (para "enviar al Scratchpad" desde la tarjeta).
    func append(_ text: String) {
        let current = load()
        let joined = current.isEmpty ? text : current + "\n\n" + text
        save(joined)
    }
}
