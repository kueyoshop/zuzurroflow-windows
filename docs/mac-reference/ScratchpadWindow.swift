import AppKit
import SwiftUI

/// Scratchpad clonado de Wispr Flow: panel flotante con pestañas de notas,
/// barra lateral colapsable (notas / búsqueda), Transforms con IA, barra de
/// formato y copiar. Dictas dentro o escribes a mano. Todo local.
@MainActor
final class ScratchpadWindowController {
    static let shared = ScratchpadWindowController()
    private var panel: NSPanel?
    private var model: ScratchpadModel?
    /// Lo inyecta el AppDelegate al arrancar: lo usan los Transforms del
    /// Scratchpad (reescritura con IA a demanda).
    var formatter: Formatter?

    /// Tamaños de la ventana: normal y expandida (botón ⤢ del título).
    static let normalSize = NSSize(width: 560, height: 460)
    static let expandedSize = NSSize(width: 980, height: 760)

    func show(appState: AppState) {
        if panel == nil {
            let m = ScratchpadModel()
            model = m
            let hosting = NSHostingController(
                rootView: ScratchpadView(appState: appState, model: m))
            let p = NSPanel(contentViewController: hosting)
            p.title = "Scratchpad"
            // Editable (debe poder ser key para dictar/escribir dentro) y
            // SIEMPRE encima. Sin .nonactivatingPanel: al enfocarlo, el
            // dictado detecta su editor y el texto entra AQUÍ.
            p.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.isMovableByWindowBackground = true
            p.isFloatingPanel = true
            p.level = .floating
            p.becomesKeyOnlyIfNeeded = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.setContentSize(Self.normalSize)
            p.minSize = NSSize(width: 460, height: 360)
            p.setFrameAutosaveName("ScratchpadPanel")
            panel = p

            m.onToggleExpand = { [weak self] expanded in
                self?.resize(expanded: expanded)
            }
            m.onClose = { [weak self] in self?.panel?.orderOut(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Expande/reduce manteniendo fija la esquina SUPERIOR izquierda (si no,
    /// la ventana “salta” hacia arriba al crecer).
    private func resize(expanded: Bool) {
        guard let panel else { return }
        let target = expanded ? Self.expandedSize : Self.normalSize
        let sized = panel.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = sized.size
        frame.origin.y = topEdge - sized.height
        panel.setFrame(frame, display: true, animate: true)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// ¿Es el Scratchpad la ventana con foco de teclado ahora mismo?
    /// (para decidir que el dictado entra AQUÍ y no en la app anterior)
    var isKeyWindow: Bool { panel?.isKeyWindow ?? false }

    /// Reasegura el foco en el Scratchpad (antes de pegar el dictado en él).
    func focus() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Modelo

@MainActor
final class ScratchpadModel: ObservableObject {
    @Published var notes: [ScratchNote] = []
    /// Pestañas abiertas (ids de nota), en orden.
    @Published var openTabs: [UUID] = []
    @Published var currentID: UUID?
    @Published var sidebarExpanded = true
    @Published var isExpanded = false
    @Published var panel: BottomPanel = .none
    @Published var searchQuery = ""
    @Published var searching = false
    @Published var renaming = false
    @Published var transforming = false

    enum BottomPanel { case none, transforms, formatting }

    var onToggleExpand: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    init() {
        notes = ScratchpadStore.shared.loadAll()
        if notes.isEmpty {
            let fresh = ScratchNote()
            notes = [fresh]
            ScratchpadStore.shared.save(fresh)
        }
        let first = notes.max(by: { $0.updatedAt < $1.updatedAt }) ?? notes[0]
        openTabs = [first.id]
        currentID = first.id
    }

    var current: ScratchNote? {
        guard let currentID else { return nil }
        return notes.first { $0.id == currentID }
    }

    var filteredNotes: [ScratchNote] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = notes.sorted { $0.updatedAt > $1.updatedAt }
        guard !q.isEmpty else { return sorted }
        return sorted.filter {
            $0.displayTitle.lowercased().contains(q) || $0.plain.lowercased().contains(q)
        }
    }

    func newNote() {
        let n = ScratchNote()
        notes.append(n)
        ScratchpadStore.shared.save(n)
        openTabs.append(n.id)
        currentID = n.id
        panel = .none
    }

    func open(_ id: UUID) {
        if !openTabs.contains(id) { openTabs.append(id) }
        currentID = id
    }

    func closeTab(_ id: UUID) {
        openTabs.removeAll { $0 == id }
        if currentID == id { currentID = openTabs.last }
        if openTabs.isEmpty { newNote() }
    }

    func update(_ note: ScratchNote) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i] = note
        } else {
            notes.append(note)
        }
        ScratchpadStore.shared.save(note)
    }

    func deleteNote(_ id: UUID) {
        notes.removeAll { $0.id == id }
        ScratchpadStore.shared.delete(id: id)
        closeTab(id)
        if notes.isEmpty { newNote() }
    }

    func toggleExpand() {
        isExpanded.toggle()
        onToggleExpand?(isExpanded)
    }
}

/// Botón-icono del marco (título): sutil, con hover como en Wispr.
private struct PadIcon: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Pad.ink)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Pad.selected : (hovering ? Pad.hover : .clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Paleta (calcada de las capturas de Wispr)

private enum Pad {
    static let chrome = Color(red: 0.957, green: 0.949, blue: 0.937)   // crema del marco
    static let sheet = Color.white                                      // hoja del editor
    static let hover = Color.black.opacity(0.05)
    static let selected = Color.black.opacity(0.07)
    static let hairline = Color.black.opacity(0.08)
    static let ink = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let inkSoft = Color.black.opacity(0.55)
    static let pill = Color(red: 0.11, green: 0.11, blue: 0.12)         // botón Copy
}

// MARK: - Vista principal

struct ScratchpadView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: ScratchpadModel
    @StateObject private var waveform = WaveformModel()

    @State private var text = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var loadedID: UUID?
    @State private var copied = false
    @State private var titleDraft = ""
    @State private var transformPrompt = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(Pad.hairline)
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Pad.hairline)
                editorArea
            }
        }
        .background(Pad.chrome)
        .onAppear { loadCurrent() }
        .onChange(of: model.currentID) { loadCurrent() }
        .onChange(of: text) { persist() }
        .onChange(of: appState.recordingState) {
            waveform.setActive(appState.recordingState == .recording)
        }
        .onChange(of: appState.audioLevel) { waveform.setLevel(appState.audioLevel) }
    }

    // MARK: Barra de título (icono · pestañas · + · expandir · cerrar)

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Pad.ink)
                .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.openTabs, id: \.self) { id in
                        tabChip(id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { model.newNote() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(PadIcon())
            .help("Nueva nota")

            Button { model.toggleExpand() } label: {
                Image(systemName: model.isExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(PadIcon())
            .help(model.isExpanded ? "Reducir" : "Expandir")

            Button { model.onClose?() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(PadIcon())
            .help("Cerrar")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private func tabChip(_ id: UUID) -> some View {
        let note = model.notes.first { $0.id == id }
        let isCurrent = model.currentID == id
        return HStack(spacing: 6) {
            if isCurrent, model.renaming {
                TextField("Untitled", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 90)
                    .onSubmit { commitRename() }
            } else {
                Text(note?.displayTitle ?? "Untitled")
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Pad.ink : Pad.inkSoft)
                    .lineLimit(1)
                    .onTapGesture {
                        if isCurrent {
                            titleDraft = note?.title == "Untitled" ? "" : (note?.title ?? "")
                            model.renaming = true
                        } else {
                            model.open(id)
                        }
                    }
            }
            Button { model.closeTab(id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Pad.inkSoft)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isCurrent ? Color.white : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isCurrent ? Pad.hairline : .clear, lineWidth: 1)
        )
        .help("Clic en el nombre para renombrar")
    }

    private func commitRename() {
        guard var n = model.current else { return }
        let t = titleDraft.trimmingCharacters(in: .whitespaces)
        n.title = t.isEmpty ? "Untitled" : t
        model.update(n)
        model.renaming = false
    }

    // MARK: Barra lateral

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarRow(icon: "sidebar.left",
                       label: model.sidebarExpanded ? "Collapse Notes" : nil,
                       selected: false) {
                withAnimation(.easeOut(duration: 0.15)) { model.sidebarExpanded.toggle() }
            }
            sidebarRow(icon: "square.and.pencil",
                       label: model.sidebarExpanded ? "New note" : nil,
                       selected: false) { model.newNote() }

            if model.sidebarExpanded {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                    TextField("Search notes...", text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            } else {
                sidebarRow(icon: "magnifyingglass", label: nil, selected: false) {
                    withAnimation { model.sidebarExpanded = true }
                }
            }

            if model.sidebarExpanded {
                notesList
            }

            Spacer(minLength: 0)

            sidebarRow(icon: "sparkles",
                       label: model.sidebarExpanded ? "Transforms" : nil,
                       selected: model.panel == .transforms) {
                model.panel = model.panel == .transforms ? .none : .transforms
            }
            sidebarRow(icon: "textformat",
                       label: model.sidebarExpanded ? "Formatting" : nil,
                       selected: model.panel == .formatting) {
                model.panel = model.panel == .formatting ? .none : .formatting
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(width: model.sidebarExpanded ? 160 : 46, alignment: .leading)
    }

    private var notesList: some View {
        Group {
            if model.filteredNotes.isEmpty || (model.notes.count == 1 && model.notes[0].plain.isEmpty && model.searchQuery.isEmpty) {
                Text("No notes yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Pad.inkSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(model.filteredNotes) { n in
                            Button { model.open(n.id) } label: {
                                Text(n.displayTitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(n.id == model.currentID ? Pad.ink : Pad.inkSoft)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(n.id == model.currentID ? Pad.selected : .clear))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Eliminar nota", role: .destructive) {
                                    model.deleteNote(n.id)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func sidebarRow(icon: String, label: String?, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 16)
                if let label {
                    Text(label).font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(Pad.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: label == nil ? nil : .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Pad.selected : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Editor + paneles

    private var editorArea: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text, selection: $selection)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .focused($editorFocused)

                    if text.characters.isEmpty {
                        placeholder.padding(.horizontal, 17).padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }

                if model.panel == .formatting { formattingBar }
                if model.panel == .transforms { transformsPanel }
            }
            .background(Pad.sheet)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(8)

            if model.panel != .transforms {
                copyButton.padding(20)
            }
        }
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            Text("fn")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Pad.inkSoft)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Circle().fill(Pad.hover))
            Text(appState.recordingState == .recording ? "dictando…" : "to dictate")
                .font(.system(size: 14))
                .foregroundStyle(Pad.inkSoft)
            if appState.recordingState == .recording {
                WaveformView(model: waveform, color: WaveformView.settingsColor)
                    .frame(width: 44, height: 12)
            }
        }
    }

    private var copyButton: some View {
        Button {
            let ns = NSAttributedString(text)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ns.string, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text(copied ? "Copied" : "Copy").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Pad.pill))
        }
        .buttonStyle(.plain)
    }

    // MARK: Transforms (IA)

    private var transformsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Pad.hairline)
            HStack(spacing: 8) {
                transformChip("More concise", "Hazlo más conciso, sin perder información esencial.")
                transformChip("More professional", "Reescríbelo en un tono más profesional.")
                transformChip("More casual", "Reescríbelo en un tono más casual y cercano.")
                Button { runTransform("Reescríbelo mejorando la claridad y la redacción.") } label: {
                    Image(systemName: model.transforming
                          ? "circle.dotted" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(Pad.inkSoft)
                        .rotationEffect(.degrees(model.transforming ? 360 : 0))
                        .animation(model.transforming
                                   ? .linear(duration: 1).repeatForever(autoreverses: false)
                                   : .default, value: model.transforming)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                TextField("Follow up or ask a question", text: $transformPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { runTransform(transformPrompt); transformPrompt = "" }
                Text("Press Enter or").font(.system(size: 10)).foregroundStyle(Pad.inkSoft)
                Button {
                    runTransform(transformPrompt); transformPrompt = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Pad.pill))
                }
                .buttonStyle(.plain)
                .disabled(model.transforming)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .disabled(model.transforming)
    }

    private func transformChip(_ label: String, _ instruction: String) -> some View {
        Button { runTransform(instruction) } label: {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Pad.ink)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Pad.hover))
        }
        .buttonStyle(.plain)
    }

    private func runTransform(_ instruction: String) {
        let plain = NSAttributedString(text).string
        let instr = instruction.trimmingCharacters(in: .whitespaces)
        guard !plain.trimmingCharacters(in: .whitespaces).isEmpty, !instr.isEmpty,
              !model.transforming else { return }
        model.transforming = true
        Task {
            let out = await ScratchpadWindowController.shared.formatter?
                .transform(text: plain, instruction: instr)
            await MainActor.run {
                model.transforming = false
                guard let out else { return }
                text = AttributedString(out)
                persist()
            }
        }
    }

    // MARK: Formatting

    private var formattingBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Pad.hairline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    fmtButton("bold") { toggleBold() }
                    fmtButton("italic") { toggleItalic() }
                    fmtButton("underline") { toggleUnderline() }
                    fmtButton("chevron.left.forwardslash.chevron.right") { toggleMono() }
                    Divider().frame(height: 16).overlay(Pad.hairline)
                    fmtButton("list.bullet") { prefixLines("• ") }
                    fmtButton("list.number") { numberLines() }
                    fmtButton("checklist") { prefixLines("☐ ") }
                    fmtButton("text.quote") { prefixLines("> ") }
                    fmtButton("list.dash") { prefixLines("- ") }
                    fmtButton("link") { wrapSelection("[", "](url)") }
                    fmtButton("tablecells") { insertTable() }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
        }
    }

    private func fmtButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Pad.ink)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Formato sobre la selección (API de texto enriquecido de macOS 26)

    private func toggleBold() {
        text.transformAttributes(in: &selection) { c in
            let f = c.font ?? .system(size: 14)
            c.font = isBoldActive ? f : f.bold()
        }
        persist()
    }

    private var isBoldActive: Bool {
        // Aproximación: si TODA la selección ya venía en negrita, se quita.
        selection.typingAttributes(in: text).font.map {
            "\($0)".contains("bold")
        } ?? false
    }

    private func toggleItalic() {
        text.transformAttributes(in: &selection) { c in
            let f = c.font ?? .system(size: 14)
            c.font = f.italic()
        }
        persist()
    }

    private func toggleUnderline() {
        text.transformAttributes(in: &selection) { c in
            c.underlineStyle = (c.underlineStyle == nil) ? .single : nil
        }
        persist()
    }

    private func toggleMono() {
        text.transformAttributes(in: &selection) { c in
            c.font = .system(size: 13, design: .monospaced)
        }
        persist()
    }

    /// Antepone un marcador a las líneas tocadas por la selección.
    private func prefixLines(_ marker: String) {
        applyToSelectedLines { line in line.hasPrefix(marker) ? line : marker + line }
    }

    private func numberLines() {
        var n = 0
        applyToSelectedLines { line in
            n += 1
            return "\(n). " + line
        }
    }

    private func applyToSelectedLines(_ body: (String) -> String) {
        let ns = NSAttributedString(text).string
        guard !ns.isEmpty else { return }
        let lines = ns.components(separatedBy: "\n")
        let out = lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : body($0) }
            .joined(separator: "\n")
        text = AttributedString(out)
        persist()
    }

    private func wrapSelection(_ pre: String, _ post: String) {
        let ns = NSAttributedString(text).string
        text = AttributedString(ns + "\n" + pre + "texto" + post)
        persist()
    }

    private func insertTable() {
        let table = "\n| Columna | Columna |\n| --- | --- |\n|  |  |\n"
        let ns = NSAttributedString(text).string
        text = AttributedString(ns + table)
        persist()
    }

    // MARK: Carga / guardado

    private func loadCurrent() {
        guard let n = model.current else { return }
        guard loadedID != n.id else { return }
        loadedID = n.id
        text = ScratchpadStore.attributed(from: n.rtf, fallbackPlain: n.plain)
        selection = AttributedTextSelection()
        model.renaming = false
        editorFocused = true
    }

    private func persist() {
        guard var n = model.current else { return }
        n.plain = NSAttributedString(text).string
        n.rtf = ScratchpadStore.rtf(from: text)
        model.update(n)
    }
}
