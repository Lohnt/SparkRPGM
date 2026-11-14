import SwiftUI
import UIKit

/// Thin UIVisualEffectView bridge (iOS 13+), used for the translucent cards,
/// pill bars and control clusters.
struct BlurView: UIViewRepresentable {

    var style: UIBlurEffect.Style = .systemUltraThinMaterialDark
    var alpha: CGFloat = 1

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.alpha = alpha
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
        uiView.alpha = alpha
    }
}

struct GlassBackground: ViewModifier {

    var cornerRadius: CGFloat = 18
    var opacity: Double = 0.35
    var strokeOpacity: Double = 0.10

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    BlurView(style: .systemUltraThinMaterialDark)
                    Color.black.opacity(opacity)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18, opacity: Double = 0.35) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, opacity: opacity))
    }
}
