import Foundation

/// Máquina de estados pura para el gesto de dictado (sin dependencias del OS,
/// testeable). Traduce eventos crudos de teclado en acciones de alto nivel.
///
/// Semántica (como Wispr Flow):
///   - MANTENER la tecla (≥ tapMaxDuration) → grabar; soltar → parar y pegar.
///   - TOQUE-TOQUE rápido → manos libres: sigue grabando sin sujetar nada;
///     un toque más → parar y pegar. La grabación del primer toque NUNCA se
///     corta mientras se espera el segundo toque.
///   - Toque suelto único (sin segundo toque) → descartar (audio inútil).
///   - Otra tecla durante un hold cortísimo de modificador → uso normal del
///     modificador (ej. Shift para mayúscula) → descartar (flag dirty).
///   - Esc cancela siempre.
struct HotKeyProcessor {

    enum State: Equatable {
        case idle
        case pressAndHold(since: TimeInterval)
        /// Primer toque soltado; la grabación SIGUE mientras esperamos un
        /// posible segundo toque (ventana de doubleTapWindow).
        case tapPending(deadline: TimeInterval)
        case handsFreeLocked
    }

    enum Action: Equatable {
        case start          // empezar a grabar
        case stop           // parar y transcribir
        case cancel         // descartar grabación
        case none
    }

    enum Event: Equatable {
        case hotkeyDown(at: TimeInterval)
        case hotkeyUp(at: TimeInterval)
        case otherKeyDown(at: TimeInterval)
        case tapWindowExpired(at: TimeInterval)  // programado por el monitor
        case escape
    }

    /// 0.45s: con 0.35 los segundos toques "tranquilos" (tras un rato sin
    /// dictar) llegaban justo fuera y el gesto fallaba en silencio.
    var doubleTapWindow: TimeInterval = 0.45
    /// Un hold más corto que esto es un "toque" (candidato a doble-toque).
    var tapMaxDuration: TimeInterval = 0.30
    var isModifierOnly: Bool = true

    private(set) var state: State = .idle
    /// "dirty": ignorar todo hasta que se suelte la hotkey por completo.
    private var dirty = false

    /// El monitor debe programar un `.tapWindowExpired` a este instante
    /// cuando quede no-nil tras manejar un evento.
    var pendingDeadline: TimeInterval? {
        if case let .tapPending(deadline) = state { return deadline }
        return nil
    }

    var isLocked: Bool { state == .handsFreeLocked }

    mutating func handle(_ event: Event) -> Action {
        switch event {
        case .escape:
            if state != .idle {
                state = .idle
                dirty = false
                return .cancel
            }
            return .none

        case let .hotkeyDown(at):
            if dirty { return .none }
            switch state {
            case .idle:
                state = .pressAndHold(since: at)
                return .start
            case .pressAndHold:
                return .none
            case .tapPending:
                // Segundo toque dentro de la ventana → manos libres.
                // La grabación ya está corriendo: no hay acción, solo lock.
                state = .handsFreeLocked
                return .none
            case .handsFreeLocked:
                // Toque en modo bloqueado → terminar y transcribir.
                state = .idle
                return .stop
            }

        case let .hotkeyUp(at):
            switch state {
            case let .pressAndHold(since):
                if at - since < tapMaxDuration {
                    // Toque corto: NO parar aún; esperar posible segundo toque.
                    state = .tapPending(deadline: at + doubleTapWindow)
                    return .none
                }
                // Hold normal (push-to-talk): soltar = transcribir.
                state = .idle
                return .stop
            case .handsFreeLocked:
                // Soltar el segundo toque del lock: ignorar.
                return .none
            default:
                return .none
            }

        case let .tapWindowExpired(at):
            if case let .tapPending(deadline) = state, at >= deadline {
                // Nadie dio el segundo toque: el audio del toque era inútil.
                state = .idle
                return .cancel
            }
            return .none

        case let .otherKeyDown(at):
            // Otra tecla durante un hold cortísimo de modificador-solo:
            // el usuario está usando Shift normal (mayúscula) → descartar.
            if case let .pressAndHold(since) = state, isModifierOnly {
                if at - since < tapMaxDuration {
                    dirty = true
                    state = .idle
                    return .cancel
                }
            }
            return .none
        }
    }

    /// Llamar cuando la hotkey se soltó del todo (limpia dirty).
    mutating func clearDirtyIfReleased() {
        dirty = false
    }
}
