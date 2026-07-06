import AppKit

/// Captura teclado global con CGEventTap y alimenta el HotKeyProcessor.
/// Maneja el gesto de la tecla de dictado (Shift derecha o Fn según perfil).
///
/// Permiso necesario: Accesibilidad (el tap de sesión lo exige). Incluye
/// watchdog: si el sistema desactiva el tap por timeout, lo reactiva.
@MainActor
final class EventTapMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var processor = HotKeyProcessor()
    private var ptt: KeyCombo
    private var handsFree: KeyCombo?
    private var pasteLastKeyCode: CGKeyCode
    private var pasteLastFlags: CGEventFlags
    private var triggerHeld = false
    private var lastLocked = false
    private var tapExpiryWork: DispatchWorkItem?

    /// Acciones de alto nivel hacia el coordinador.
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onLockChanged: ((Bool) -> Void)?
    /// Acorde de manos libres pulsado (toggle empezar/terminar).
    var onHandsFreeToggle: (() -> Void)?

    init(profile: HotkeyProfile) {
        ptt = SettingsStore.shared.pushToTalkCombo
        handsFree = SettingsStore.shared.handsFreeCombo
        pasteLastKeyCode = profile.pasteLastKeyCode
        pasteLastFlags = profile.pasteLastFlags
        processor.isModifierOnly = ptt.modifierOnly
    }

    /// Recarga atajos desde Ajustes (perfil o combos personalizados).
    func reloadShortcuts() {
        let profile = SettingsStore.shared.hotkeyProfile
        ptt = SettingsStore.shared.pushToTalkCombo
        handsFree = SettingsStore.shared.handsFreeCombo
        pasteLastKeyCode = profile.pasteLastKeyCode
        pasteLastFlags = profile.pasteLastFlags
        processor = HotKeyProcessor()
        processor.isModifierOnly = ptt.modifierOnly
        triggerHeld = false
        Log.info("[Hotkey] Atajos: hablar=\(ptt.displayName)\(handsFree.map { " · manos libres=\($0.displayName)" } ?? "")")
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Pide permiso de Accesibilidad (abre el diálogo del sistema si falta).
    func promptAccessibilityIfNeeded() {
        // La constante del SDK es una global mutable (no Sendable en Swift 6);
        // su valor real es "AXTrustedCheckOptionPrompt".
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else {
            Log.error("[Hotkey] Falta permiso de Accesibilidad — actívalo en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad")
            return false
        }

        let mask = (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue)

        // `refcon` lleva un puntero a self para el callback C.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,        // no suprimimos: solo escuchamos
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleFromTap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            Log.error("[Hotkey] No se pudo crear el event tap")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.info("[Hotkey] Activo — hablar=\(ptt.displayName)\(handsFree.map { " · manos libres=\($0.displayName)" } ?? "")")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    // Llamado desde el callback C (hilo del run loop, que es main).
    nonisolated private func handleFromTap(type: CGEventType, event: CGEvent) {
        // El callback C es nonisolated; volvemos a main para tocar estado.
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        MainActor.assumeIsolated {
            self.route(type: type, keyCode: keyCode, flags: flags)
        }
    }

    private func route(type: CGEventType, keyCode: CGKeyCode, flags: CGEventFlags) {
        let now = ProcessInfo.processInfo.systemUptime

        // Re-habilitar si el sistema desactivó el tap (watchdog).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        switch type {
        // PTT solo-modificador (Fn, Shift derecha…): presión/suelta por flags.
        case .flagsChanged where ptt.modifierOnly && keyCode == ptt.keyCode:
            guard let flag = ptt.modifierFlag else { return }
            let isDown = flags.contains(flag)
            if isDown, !triggerHeld {
                triggerHeld = true
                dispatch(processor.handle(.hotkeyDown(at: now)))
            } else if !isDown, triggerHeld {
                triggerHeld = false
                dispatch(processor.handle(.hotkeyUp(at: now)))
                processor.clearDirtyIfReleased()
            }

        case .keyDown:
            if keyCode == 53 { // Esc
                if processor.state != .idle {
                    Log.info("[Hotkey] Esc → cancelar dictado")
                }
                dispatch(processor.handle(.escape))
            } else if let hf = handsFree, keyCode == hf.keyCode, flagsMatch(flags, hf.flags) {
                // Acorde de manos libres: toggle empezar/terminar.
                onHandsFreeToggle?()
            } else if !ptt.modifierOnly, keyCode == ptt.keyCode, flagsMatch(flags, ptt.flags) {
                // PTT acorde (tecla+modificadores): keyDown = presión.
                if !triggerHeld {
                    triggerHeld = true
                    dispatch(processor.handle(.hotkeyDown(at: now)))
                }
            } else if keyCode == pasteLastKeyCode && flagsMatch(flags, pasteLastFlags) {
                onPasteLast?()
            } else {
                dispatch(processor.handle(.otherKeyDown(at: now)))
            }

        case .keyUp:
            if !ptt.modifierOnly, keyCode == ptt.keyCode, triggerHeld {
                triggerHeld = false
                dispatch(processor.handle(.hotkeyUp(at: now)))
                processor.clearDirtyIfReleased()
            }

        default:
            break
        }
    }

    /// Compara solo los modificadores relevantes (⌃⌥⇧⌘ + Fn), ignorando
    /// bits de estado como caps lock o teclado numérico.
    private func flagsMatch(_ actual: CGEventFlags, _ expected: CGEventFlags) -> Bool {
        let mask: CGEventFlags = [.maskControl, .maskShift, .maskCommand, .maskAlternate, .maskSecondaryFn]
        return actual.intersection(mask) == expected.intersection(mask)
    }

    private func dispatch(_ action: HotKeyProcessor.Action) {
        switch action {
        case .start: onStart?()
        case .stop: onStop?()
        case .cancel: onCancel?()
        case .none: break
        }
        // Propagar cambios de modo manos-libres (para el pill).
        let locked = processor.isLocked
        if locked != lastLocked {
            lastLocked = locked
            onLockChanged?(locked)
        }
        // Si quedó un toque pendiente de segundo toque, programar la expiración.
        tapExpiryWork?.cancel()
        tapExpiryWork = nil
        if let deadline = processor.pendingDeadline {
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.dispatch(self.processor.handle(.tapWindowExpired(at: now)))
                }
            }
            tapExpiryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.01, execute: work)
        }
    }
}
