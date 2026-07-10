import Foundation

/// Tono según la app destino (los "Flow Styles" de Wispr): el mismo dictado
/// se puntúa distinto en un chat que en un correo. Categoría por bundle ID;
/// lo desconocido queda neutro (comportamiento actual).
enum AppToneCategory: String {
    case messaging   // chats: casual, sin punto final en mensajes cortos
    case email       // correo: formal, puntuación completa
    case neutral     // resto: sin sesgo

    static func categorize(bundleID: String?) -> AppToneCategory {
        guard let id = bundleID?.lowercased() else { return .neutral }
        if messagingBundles.contains(where: { id.contains($0) }) { return .messaging }
        if emailBundles.contains(where: { id.contains($0) }) { return .email }
        return .neutral
    }

    private static let messagingBundles: [String] = [
        "net.whatsapp", "whatsapp",            // WhatsApp
        "com.apple.mobilesms", "messages",     // Mensajes
        "telegram",                            // Telegram (org./ru.keepcoder)
        "com.tinyspeck.slackmacgap", "slack",  // Slack
        "com.hnc.discord", "discord",          // Discord
        "com.facebook.archon", "messenger",    // Messenger
        "com.skype", "teams",                  // Skype/Teams
    ]

    private static let emailBundles: [String] = [
        "com.apple.mail",                      // Mail
        "com.microsoft.outlook",               // Outlook
        "com.readdle.smartemail",              // Spark
        "com.airmailapp", "airmail",           // Airmail
        "it.bloop.airmail",
        "com.superhuman",                      // Superhuman
    ]

    /// Sección de tono para las instrucciones del pulido. Vacía en neutro.
    var promptSection: String {
        switch self {
        case .messaging:
            return """


            TONO (app de MENSAJERÍA): es un chat — natural y directo. Si el \
            dictado completo tiene 1 o 2 frases, NO pongas punto final a la \
            última (estilo chat); en dictados más largos, puntúa normal. No \
            uses lenguaje más formal del que el hablante usó.
            """
        case .email:
            return """


            TONO (CORREO): redacción de email profesional — puntuación \
            completa, mayúsculas correctas, punto final siempre. No cambies \
            las palabras del hablante, solo cuida la forma.
            """
        case .neutral:
            return ""
        }
    }
}
