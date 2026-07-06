import Foundation

/// Command Mode: aplicar una ORDEN dictada sobre el texto SELECCIONADO
/// ("tradúcelo al inglés", "resúmelo", "hazlo más formal"…).
/// Motor: Claude (claude-haiku-4-5) vía kie.ai — aquí la espera de unos
/// segundos se justifica: es edición bajo demanda, no el hot path.
actor CommandEngine {

    enum CommandError: Error, LocalizedError {
        case noApiKey
        case httpError(Int)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .noApiKey: "Falta la clave de kie.ai en Ajustes"
            case .httpError(let c): "Error del servicio (\(c))"
            case .emptyResult: "El modelo no devolvió resultado"
            }
        }
    }

    private static let systemPrompt = """
    Eres el modo comando de un sistema de dictado. Recibes un TEXTO \
    seleccionado por el usuario y una ORDEN dictada por voz. Aplica la orden \
    al texto y devuelve ÚNICAMENTE el texto resultante — sin explicaciones, \
    sin comillas envolventes, sin markdown fences, sin comentarios.

    Ejemplos de órdenes: "tradúcelo al inglés", "resúmelo en dos frases", \
    "hazlo más formal", "corrige la ortografía", "conviértelo en lista", \
    "expande esta idea". Si la orden pide generar contenido nuevo a partir \
    del texto, genera exactamente eso. Conserva el idioma que la orden \
    implique (si pide traducir, traduce; si no, mantén el idioma original).
    """

    func apply(order: String, to selection: String) async throws -> String {
        guard let apiKey = SettingsStore.shared.kieApiKey else {
            throw CommandError.noApiKey
        }

        var request = URLRequest(url: URL(string: "https://api.kie.ai/claude/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let user = """
        ORDEN: \(order)

        TEXTO:
        \(selection)
        """
        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": max(1000, selection.count / 2),
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CommandError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw CommandError.emptyResult
        }
        var text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Por si envolvió en fences pese al prompt.
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```[a-z]*\n?", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw CommandError.emptyResult }
        return text
    }
}
