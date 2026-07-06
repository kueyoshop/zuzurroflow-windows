import AppKit
import SwiftUI

/// Toasts estilo Wispr: aviso mini oscuro abajo-centro (misma zona que el
/// pill), con botón de acción opcional (Deshacer) y una barra blanca que se
/// va llenando — al llenarse, fade-out y desaparece.
@MainActor
final class ToastController {
    private var panel: OverlayPanel?
    private var dismissWork: DispatchWorkItem?

    private static let size = NSSize(width: 340, height: 44)
    private static let bottomMargin: CGFloat = 74   // encima del hueco del pill

    /// Muestra un toast. `action` con `actionTitle` añade el botón (Deshacer…).
    func show(_ message: String,
              actionTitle: String? = nil,
              duration: TimeInterval = 3.0,
              action: (() -> Void)? = nil) {
        dismiss(immediately: true)

        let view = ToastView(
            message: message,
            actionTitle: actionTitle,
            duration: duration,
            onAction: { [weak self] in
                action?()
                self?.dismiss(immediately: false)
            }
        )

        let hosting = NSHostingView(rootView: view)
        // Ajustar al contenido real (mensajes largos/cortos).
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(180, min(460, fitting.width)),
                          height: max(40, fitting.height))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        position(panel, size: size)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        // Autodesaparición al llenarse la barra.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(immediately: false) }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss(immediately: Bool) {
        dismissWork?.cancel()
        dismissWork = nil
        guard let panel else { return }
        self.panel = nil
        if immediately {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            })
        }
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Self.bottomMargin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// La vista del toast: mensaje + botón opcional + barra de progreso que se llena.
struct ToastView: View {
    let message: String
    let actionTitle: String?
    let duration: TimeInterval
    let onAction: () -> Void

    @State private var progress: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                if let actionTitle {
                    Button(action: onAction) {
                        Text(actionTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Barra que se va llenando (indicador del tiempo de vida).
            GeometryReader { geo in
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(width: geo.size.width * progress, height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.07).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            withAnimation(.linear(duration: duration)) {
                progress = 1.0
            }
        }
    }
}
