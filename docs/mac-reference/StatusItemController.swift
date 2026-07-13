import AppKit
import Combine

/// Icono de la barra de menú con estados (idle/recording/processing)
/// y menú contextual. Equivalente al TrayIcon del MVP Python.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()

    var onToggleRecording: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    var onOpenScratchpad: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Últimos dictados para el submenu Recientes.
    var recentProvider: (() -> [String])?
    var onPasteRecent: ((String) -> Void)?

    init(appState: AppState) {
        self.appState = appState
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        buildMenu()
        updateIcon(for: appState.recordingState)

        appState.$recordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateIcon(for: state) }
            .store(in: &cancellables)
    }

    private func buildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "Dictator", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        menu.addItem(makeItem("Grabar / Parar", #selector(toggleTapped)))
        menu.addItem(.separator())

        // Selector de motor de pulido IA
        let aiItem = NSMenuItem(title: "Pulido IA", action: nil, keyEquivalent: "")
        let aiMenu = NSMenu()
        for engine in FormatterEngine.allCases {
            let title: String
            switch engine {
            case .anthropic: title = "Claude (Anthropic) — máx. calidad, ~1-2s — recomendado"
            case .apple: title = "Apple (local, ~1s) — más flojo"
            case .kie: title = "Claude vía Kie (lento, 7-8s)"
            case .off: title = "Desactivado (texto crudo)"
            }
            let mi = NSMenuItem(title: title, action: #selector(engineTapped(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = engine.rawValue
            aiMenu.addItem(mi)
        }
        aiItem.submenu = aiMenu
        menu.addItem(aiItem)
        self.aiMenu = aiMenu
        refreshEngineChecks()

        menu.addItem(.separator())

        // Recientes: se rellena al abrir el menú (menuNeedsUpdate).
        let recentItem = NSMenuItem(title: "Recientes", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("Scratchpad…", #selector(scratchpadTapped)))
        menu.addItem(makeItem("Dashboard…", #selector(dashboardTapped)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Salir", #selector(quitTapped)))

        item.menu = menu
    }

    // NSMenuDelegate: reconstruir Recientes cada vez que se abre.
    // AppKit siempre lo llama en main; se lo garantizamos al compilador.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        nonisolated(unsafe) let menu = menu
        MainActor.assumeIsolated {
            menu.removeAllItems()
            let recents = recentProvider?() ?? []
            if recents.isEmpty {
                let empty = NSMenuItem(title: "(sin dictados aún)", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            for text in recents {
                let title = text.count > 46 ? String(text.prefix(46)) + "…" : text
                let mi = NSMenuItem(title: title, action: #selector(recentTapped(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = text
                menu.addItem(mi)
            }
        }
    }

    @objc private func recentTapped(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        onPasteRecent?(text)
    }

    private var aiMenu: NSMenu?

    private func refreshEngineChecks() {
        let current = SettingsStore.shared.formatterEngine.rawValue
        aiMenu?.items.forEach { mi in
            mi.state = (mi.representedObject as? String == current) ? .on : .off
        }
    }

    @objc private func engineTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = FormatterEngine(rawValue: raw) else { return }
        SettingsStore.shared.formatterEngine = engine
        refreshEngineChecks()
        Log.info("[Settings] Motor de pulido: \(engine.rawValue)")
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    /// Logo del usuario como template (macOS lo pinta blanco/negro según el
    /// fondo de la barra); tinte por estado.
    private static let logoImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png",
                                        subdirectory: "branding"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()

    private func updateIcon(for state: RecordingState) {
        guard let button = item.button else { return }

        let description: String
        let tint: NSColor?
        switch state {
        case .idle:
            (description, tint) = ("Dictator — listo", nil)
        case .recording:
            (description, tint) = ("Grabando…", .systemRed)
        case .transcribing, .formatting:
            (description, tint) = ("Procesando…", .systemOrange)
        case .pasting:
            (description, tint) = ("Pegando…", nil)
        }

        if let logo = Self.logoImage {
            button.image = logo
        } else {
            // Fallback si el logo no está en el bundle.
            let img = NSImage(systemSymbolName: "mic", accessibilityDescription: description)
            img?.isTemplate = true
            button.image = img
        }
        button.contentTintColor = tint
        button.toolTip = description
    }

    @objc private func toggleTapped() { onToggleRecording?() }
    @objc private func dashboardTapped() { onOpenDashboard?() }
    @objc private func scratchpadTapped() { onOpenScratchpad?() }
    @objc private func quitTapped() { onQuit?() }
}
