import AppKit
import SwiftUI

/// Scratchpad estilo Wispr (núcleo): panel flotante SIEMPRE encima donde
/// dictas directo (con waveform en vivo), se autoguarda en local y puedes
/// editar / copiar / limpiar. Sin nube — todo se queda en este Mac.
@MainActor
final class ScratchpadWindowController {
    static let shared = ScratchpadWindowController()
    private var panel: NSPanel?

    func show(appState: AppState) {
        if panel == nil {
            let hosting = NSHostingController(rootView: ScratchpadView(appState: appState))
            let p = NSPanel(contentViewController: hosting)
            p.title = "Scratchpad"
            // Editable (debe poder ser key para dictar/escribir dentro) y
            // SIEMPRE encima. Sin .nonactivatingPanel: al enfocarlo, el
            // dictado detecta su editor y el texto entra AQUÍ.
            p.styleMask = [.titled, .closable, .resizable, .utilityWindow]
            p.isFloatingPanel = true
            p.level = .floating
            p.becomesKeyOnlyIfNeeded = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.setContentSize(NSSize(width: 400, height: 340))
            p.minSize = NSSize(width: 300, height: 200)
            p.setFrameAutosaveName("ScratchpadPanel")
            panel = p
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
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

struct ScratchpadView: View {
    @ObservedObject var appState: AppState
    @StateObject private var waveform = WaveformModel()
    @State private var text = ScratchpadStore.shared.load()
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(Color.dictatorYellow)
                Text("Scratchpad").font(.headline)

                Spacer()

                // Waveform en vivo mientras dictas (como Wispr).
                if appState.recordingState == .recording {
                    WaveformView(model: waveform, color: WaveformView.settingsColor)
                        .frame(width: 56, height: 16)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copiar todo")

                Button {
                    text = ""
                    ScratchpadStore.shared.save("")
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Vaciar")
            }
            .padding(10)

            Divider()

            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(6)
                .onChange(of: text) { ScratchpadStore.shared.save(text) }

            Divider()
            HStack {
                Text(appState.recordingState == .recording
                     ? "Dictando aquí…"
                     : "Dicta con tu atajo — el texto entra aquí. Se guarda solo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(wordCount) palabras")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.dashboardBackground.ignoresSafeArea())
        .onChange(of: appState.recordingState) {
            waveform.setActive(appState.recordingState == .recording)
        }
        .onChange(of: appState.audioLevel) {
            waveform.setLevel(appState.audioLevel)
        }
        .onAppear {
            // Recargar por si se editó/pegó desde otra ruta.
            let disk = ScratchpadStore.shared.load()
            if disk != text { text = disk }
        }
    }

    private var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
