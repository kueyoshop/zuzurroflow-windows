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

    /// En reposo y con el cursor encima → la cápsula se contrae y emergen los
    /// tres círculos.
    private var collapsedToCircles: Bool { !expanded && hovering }

    var body: some View {
        ZStack {
            // UNA sola cápsula que se TRANSFORMA (morph de tamaño) entre mini
            // y grande — no un fade entre dos vistas. Standalone (no es el
            // fondo del contenido) → su contorno siempre es una cápsula
            // limpia. Al hacer hover en reposo, se contrae mientras emergen
            // los círculos.
            // Relleno de la cápsula (el borde va APARTE, encima de todo).
            Capsule()
                .fill(expanded ? Color.black : Color.black.opacity(0.55))
                .frame(width: expanded ? 124 : 40, height: expanded ? 28 : 8.5)
                .scaleEffect(collapsedToCircles ? 0.3 : 1)
                .opacity(collapsedToCircles ? 0 : 1)
                .contentShape(Capsule())
                .allowsHitTesting(!collapsedToCircles)
                .onTapGesture { if !expanded { onIdleTap() } }   // tap = manos libres

            // Contenido de grabación: emerge dentro de la cápsula grande al
            // expandirse (escala + opacidad acompañando al morph).
            expandedContent
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded ? 1 : 0.4)
                .allowsHitTesting(expanded)

            // BORDE por ENCIMA de todo: nada lo tapa y se ve nítido incluso
            // sobre fondos oscuros (con 0.18 en overlay se perdía por arriba).
            Capsule()
                .strokeBorder(Color.white.opacity(expanded ? 0.3 : 0.8), lineWidth: 0.75)
                .frame(width: expanded ? 124 : 40, height: expanded ? 28 : 8.5)
                .scaleEffect(collapsedToCircles ? 0.3 : 1)
                .opacity(collapsedToCircles ? 0 : 1)
                .allowsHitTesting(false)

            // Accesos del hover: EMERGEN con muelle desde pequeño (crecen, es
            // una transformación — no un fade).
            hoverToolbar
                .scaleEffect(collapsedToCircles ? 1 : 0.35)
                .opacity(collapsedToCircles ? 1 : 0)
                .allowsHitTesting(collapsedToCircles)
        }
        .frame(width: 130, height: 32)          // región estable de hover
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Muelles con rebote leve → sensación de "transformación" viva pero
        // sin temblor (damping alto).
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: expanded)
        .animation(.spring(response: 0.30, dampingFraction: 0.8), value: hovering)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // centrado en el panel
    }

    // Tres círculos INDIVIDUALES y aislados (estilo Wispr), cada uno con su
    // propio fondo y borde — sin contenedor común.
    private var hoverToolbar: some View {
        HStack(spacing: 9) {
            Menu {
                Button("Auto (español · inglés)") { setLang(.auto) }
                Button("Español") { setLang(.es) }
                Button("English") { setLang(.en) }
            } label: {
                ToolCircle {
                    if langMode == .auto {
                        Image(systemName: "globe")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        Text(langMode == .es ? "ES" : "EN")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
            }
            // .button + buttonStyle(.plain): el menú conserva el CÍRCULO de
            // fondo del label (con .borderlessButton se perdía y solo quedaba
            // el icono, descuadrando el estilo respecto a los otros dos).
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Idioma de transcripción")

            Button(action: onOpenScratchpad) {
                ToolCircle {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .buttonStyle(.plain)
            .help("Scratchpad")

            Button(action: onOpenSettings) {
                ToolCircle {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .buttonStyle(.plain)
            .help("Ajustes")
        }
    }

    // Contenido de grabación (✕ · waveform · ✓). Va SOBRE la cápsula que
    // morphea; sin fondo/cápsula propios (ese fondo lo pone la cápsula única).
    private var expandedContent: some View {
        HStack(spacing: 9) {
            Button(action: onCancel) {
                ZStack {
                    Circle().fill(.white.opacity(0.16))
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 20, height: 20)
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
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(appState.recordingState != .recording)
        }
    }

    private func setLang(_ m: ASRLanguageMode) {
        langMode = m
        SettingsStore.shared.asrLanguageMode = m
        Log.info("[FlowBar] Idioma → \(m.rawValue)")
    }

}

/// Círculo aislado de los accesos del pill (idioma/Scratchpad/Ajustes) con su
/// propio fondo oscuro y borde. Gestiona SU PROPIO hover: al pasar el cursor,
/// crece un poco y se le iluminan fondo y borde — feedback sutil de que está
/// activo, sin distraer.
struct ToolCircle<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(hovering ? 0.62 : 0.8))
            content
        }
        .frame(width: 27, height: 27)
        .overlay(
            Circle().strokeBorder(
                Color.white.opacity(hovering ? 0.75 : 0.38),
                lineWidth: hovering ? 1 : 0.75)
        )
        .scaleEffect(hovering ? 1.12 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.13), value: hovering)
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
