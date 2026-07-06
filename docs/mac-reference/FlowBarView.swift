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

    var body: some View {
        HStack(alignment: .center, spacing: 2.4) {
            ForEach(0..<WaveformModel.barCount, id: \.self) { i in
                Capsule()
                    .fill(Color(red: 1.0, green: 0.27, blue: 0.23))
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

    @State private var hoveringMini = false
    private var expanded: Bool { appState.recordingState != .idle }

    var body: some View {
        ZStack {
            // Contenido expandido (se desvanece/escala junto al morph)
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
                    case .recording:
                        WaveformView(model: waveform)
                    case .transcribing, .formatting, .pasting:
                        ProcessingDotsView()
                    default:
                        WaveformView(model: waveform)
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
            .opacity(expanded ? 1 : 0)
            .scaleEffect(expanded ? 1 : 0.4)
            .allowsHitTesting(expanded)
        }
        // La cápsula ES el elemento que se transforma de mini a grande.
        // Mini: más fina, relleno gris oscuro y borde ROJO marcado (marca de
        // la casa — el mismo rojo del waveform). Expandida: negra, borde sutil.
        .frame(width: expanded ? 118 : 40, height: expanded ? 26 : 8.5)
        .background(
            Capsule()
                // Mini semitransparente (deja intuir lo que hay detrás, como
                // Wispr); expandida negra sólida. SIN sombras en ningún estado
                // (sobre fondos blancos el halo se veía horrible).
                .fill(expanded ? Color.black : Color.black.opacity(0.55))
                .overlay(
                    // strokeBorder = línea hacia DENTRO, sin fundirse con el
                    // fondo; filo nítido estilo Wispr.
                    Capsule().strokeBorder(
                        Color.white.opacity(expanded ? 0.18 : 0.8),
                        lineWidth: expanded ? 0.5 : 0.75
                    )
                )
        )
        .contentShape(Capsule())
        // Hover sobre la mini: crece un poquito (misma familia de muelle que
        // el morph) — pista intuitiva de que es clicable.
        .scaleEffect(!expanded && hoveringMini ? 1.18 : 1.0)
        .onHover { inside in
            hoveringMini = inside
        }
        .onTapGesture {
            if !expanded { onIdleTap() }   // mini → empezar manos libres
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: expanded)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hoveringMini)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // centrado en el panel
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
