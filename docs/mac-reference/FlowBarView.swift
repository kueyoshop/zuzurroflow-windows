import SwiftUI

/// Modelo del waveform estilo Wispr: pocas barras gruesas que reaccionan
/// SOLO cuando hay voz — en silencio quedan quietas al mínimo.
@MainActor
final class WaveformModel: ObservableObject {
    static let barCount = 12
    /// Por debajo de este nivel se considera silencio (barras quietas).
    private static let silenceGate: CGFloat = 0.10
    private static let restHeight: CGFloat = 0.12

    @Published private(set) var heights: [CGFloat] = Array(repeating: restHeight, count: barCount)
    private var targets: [CGFloat] = Array(repeating: restHeight, count: barCount)
    private var timer: Timer?

    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.tick() }
            }
        } else {
            timer?.invalidate()
            timer = nil
            heights = Array(repeating: Self.restHeight, count: Self.barCount)
            targets = heights
        }
    }

    func setLevel(_ level: Float) {
        let lvl = CGFloat(level)

        // Silencio: todas las barras al reposo, sin jitter aleatorio.
        guard lvl > Self.silenceGate else {
            targets = Array(repeating: Self.restHeight, count: Self.barCount)
            return
        }

        let center = CGFloat(Self.barCount - 1) / 2
        for i in 0..<Self.barCount {
            let dist = abs(CGFloat(i) - center) / center
            let envelope = 1.0 - dist * dist * 0.55
            // La variación aleatoria escala con la voz: voz floja → casi uniforme.
            let variation = 1.0 - CGFloat.random(in: 0...0.6) * lvl
            targets[i] = min(1.0, max(Self.restHeight, lvl * 1.35 * envelope * variation))
        }
    }

    private func tick() {
        var next = heights
        for i in 0..<Self.barCount {
            next[i] += (targets[i] - next[i]) * 0.35
        }
        heights = next
    }
}

struct WaveformView: View {
    @ObservedObject var model: WaveformModel
    /// Color de las ondas — configurable en Ajustes → Ondas de voz.
    var color: Color = WaveformView.defaultColor

    static let defaultColor = Color(red: 1.0, green: 0.27, blue: 0.23)

    /// El color guardado por el usuario (o el rojo de siempre).
    static var settingsColor: Color {
        Color(hex: SettingsStore.shared.waveformColorHex) ?? defaultColor
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2.4) {
            ForEach(0..<WaveformModel.barCount, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.8, height: max(2.8, model.heights[i] * 13))
            }
        }
        .frame(height: 16)
    }
}

/// El pill estilo Wispr: ✕ | waveform/estado | botón stop.
/// El Flow Bar que respira (como Wispr): en reposo es una pastillita mini
/// siempre visible; al dictar SE EXPANDE con animación al pill completo
/// (waveform + botones) y al terminar se encoge de vuelta. Un solo elemento
/// que se transforma — no dos que aparecen/desaparecen.
/// Click en la mini = empezar manos libres (como Wispr).
struct FlowBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var waveform: WaveformModel
    var onCancel: () -> Void
    var onStop: () -> Void
    var onIdleTap: () -> Void
    var onOpenScratchpad: () -> Void
    var onOpenSettings: () -> Void

    @State private var hovering = false
    @State private var langMode = SettingsStore.shared.asrLanguageMode
    private var expanded: Bool { appState.recordingState != .idle }

    var body: some View {
        ZStack {
            if expanded {
                expandedPill
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                idleContent
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: expanded)
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: hovering)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // centrado en el panel
    }

    // Reposo: mini pastilla que, al pasar el cursor, revela los accesos
    // rápidos (idioma · Scratchpad · Ajustes) — estilo Wispr. La región de
    // hover es fija y abarca la barra entera, así moverse entre botones no la
    // colapsa.
    private var idleContent: some View {
        ZStack {
            miniPill
                .opacity(hovering ? 0 : 1)
                .scaleEffect(hovering ? 0.5 : 1)
            hoverToolbar
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.5)
                .allowsHitTesting(hovering)
        }
        .frame(width: 130, height: 32)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var miniPill: some View {
        Capsule()
            .fill(Color.black.opacity(0.55))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.8), lineWidth: 0.75))
            .frame(width: 40, height: 8.5)
            .contentShape(Capsule())
            .onTapGesture { onIdleTap() }   // tap en la mini = manos libres
    }

    private var hoverToolbar: some View {
        HStack(spacing: 7) {
            Menu {
                Button("Auto (español · inglés)") { setLang(.auto) }
                Button("Español") { setLang(.es) }
                Button("English") { setLang(.en) }
            } label: {
                circle {
                    if langMode == .auto {
                        Image(systemName: "globe")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        Text(langMode == .es ? "ES" : "EN")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Idioma de transcripción")

            circleButton(icon: "square.and.pencil", action: onOpenScratchpad)
                .help("Scratchpad")
            circleButton(icon: "gearshape.fill", action: onOpenSettings)
                .help("Ajustes")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    private var expandedPill: some View {
        HStack(spacing: 7) {
            Button(action: onCancel) {
                ZStack {
                    Circle().fill(.white.opacity(0.16))
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)

            ZStack {
                switch appState.recordingState {
                case .transcribing, .formatting, .pasting:
                    ProcessingDotsView()
                default:
                    WaveformView(model: waveform, color: WaveformView.settingsColor)
                }
            }
            .frame(width: 56, height: 16)

            Button(action: onStop) {
                ZStack {
                    Circle().fill(.white.opacity(appState.recordingState == .recording ? 1.0 : 0.45))
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(appState.recordingState != .recording)
        }
        .frame(width: 118, height: 26)
        .background(
            Capsule().fill(Color.black)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        )
    }

    private func setLang(_ m: ASRLanguageMode) {
        langMode = m
        SettingsStore.shared.asrLanguageMode = m
        Log.info("[FlowBar] Idioma → \(m.rawValue)")
    }

    private func circle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Circle().fill(.white.opacity(0.16))
            content()
        }
        .frame(width: 24, height: 24)
    }

    private func circleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circle {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .buttonStyle(.plain)
    }
}

/// Puntos animados mientras transcribe/pega.
struct ProcessingDotsView: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(phase == i ? 0.9 : 0.3))
                    .frame(width: 4, height: 4)
            }
        }
        .onAppear { animate() }
    }

    private func animate() {
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = (phase + 1) % 3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { animate() }
    }
}
