import AppKit
import SwiftUI

/// Controla el pill flotante: mostrar/ocultar con fade, posicionarlo
/// abajo-centro de la pantalla donde está el cursor, y SEGUIR al cursor
/// entre pantallas en vivo mientras está visible (mejora sobre Wispr,
/// cuyo comportamiento multi-monitor ni está documentado).
@MainActor
final class FlowBarController {
    private let panel: OverlayPanel
    private let waveform = WaveformModel()
    private var mouseMonitor: Any?
    private var currentScreen: NSScreen?

    // Panel de tamaño FIJO (transparente): el morph mini↔grande ocurre
    // dentro con SwiftUI; los clicks en zonas transparentes pasan a través.
    private static let size = NSSize(width: 150, height: 36)
    /// Con Wispr Flow corriendo, su pill vive abajo: el nuestro se aparta
    /// un poco más arriba. Si Wispr no está, ocupamos su hueco.
    private static let bottomMarginAboveWispr: CGFloat = 24
    private static let bottomMarginWisprSlot: CGFloat = 10
    private var wisprRunning = false

    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var onIdleTap: (() -> Void)?
    var onOpenScratchpad: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(appState: AppState) {
        panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.size))

        let view = FlowBarView(
            appState: appState,
            waveform: waveform,
            onCancel: { [weak self] in self?.onCancel?() },
            onStop: { [weak self] in self?.onStop?() },
            onIdleTap: { [weak self] in self?.onIdleTap?() },
            onOpenScratchpad: { [weak self] in self?.onOpenScratchpad?() },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // macOS emite geometría TRANSITORIA durante la reconfiguración
                // (resolución, monitor que entra/sale, despertar): recolocar
                // ahora Y de nuevo cuando se haya asentado, para no quedar mal.
                self?.repositionToCursorScreen(force: true)
                for delay in [0.3, 0.8, 1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        MainActor.assumeIsolated { self?.repositionToCursorScreen(force: true) }
                    }
                }
            }
        }

        // Vigilar si Wispr Flow abre/cierra para ceder o tomar su hueco.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshWisprPresence(repositionIfChanged: true)
                }
            }
        }
        refreshWisprPresence(repositionIfChanged: false)
    }

    /// ¿Está corriendo Wispr Flow? (por bundle id o nombre)
    private func refreshWisprPresence(repositionIfChanged: Bool) {
        let running = NSWorkspace.shared.runningApplications.contains { app in
            (app.bundleIdentifier?.lowercased().contains("wispr") ?? false)
                || (app.localizedName?.lowercased().contains("wispr") ?? false)
        }
        guard running != wisprRunning else { return }
        wisprRunning = running
        Log.info("[FlowBar] Wispr Flow \(running ? "activo → pill se aparta arriba" : "cerrado → pill ocupa su hueco")")
        if repositionIfChanged { repositionToCursorScreen(force: true) }
    }

    func setAudioLevel(_ level: Float) {
        waveform.setLevel(level)
    }

    /// Presencia permanente (como Wispr): la mini-pastilla vive siempre en
    /// pantalla y sigue al cursor; el morph lo maneja la vista según estado.
    func presentAlways() {
        repositionToCursorScreen(force: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        startFollowingCursor()
    }

    /// El waveform solo consume timer mientras se dicta.
    func updateForState(_ state: RecordingState) {
        waveform.setActive(state == .recording)
        // Asegurar visibilidad por si algo la tapó/ordenó fuera.
        panel.orderFrontRegardless()
    }

    // MARK: - Seguimiento del cursor entre pantallas (patrón Hex)

    private func startFollowingCursor() {
        guard mouseMonitor == nil else { return }
        // Los monitores de mouse NO requieren permiso de Accesibilidad.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionToCursorScreen(force: false)
            }
        }
    }

    private func stopFollowingCursor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        currentScreen = nil
    }

    private func repositionToCursorScreen(force: Bool) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let screen else { return }
        currentScreen = screen

        // Anclar al BORDE INFERIOR real de la pantalla (screen.frame), NO al
        // área visible: así el pill se queda abajo siempre, aunque el Dock
        // aparezca, se oculte o salte a esta pantalla (era la causa de que
        // "subiera" solo al reconfigurarse la pantalla). Flota por encima del
        // Dock si lo hay (es un overlay).
        let full = screen.frame
        let margin = wisprRunning ? Self.bottomMarginAboveWispr : Self.bottomMarginWisprSlot
        let target = NSRect(
            origin: NSPoint(x: full.midX - Self.size.width / 2,
                            y: full.minY + margin),
            size: Self.size)

        // AUTO-CORRECCIÓN: si el panel se desplazó (p.ej. tras un fallo de
        // configuración de pantalla), vuelve a su sitio en cuanto se mueva el
        // cursor. Si ya está donde toca, no hace nada (barato, sin parpadeo).
        let cur = panel.frame
        if !force, abs(cur.origin.x - target.origin.x) < 1,
           abs(cur.origin.y - target.origin.y) < 1 {
            return
        }
        panel.setFrame(target, display: true)
    }
}
