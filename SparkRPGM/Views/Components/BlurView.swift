import SwiftUI
import UIKit

/// Thin `UIVisualEffectView` bridge (iOS 13+).
///
/// Only the in-game top bar uses it: a light material over a live game keeps
/// the controls legible without hiding what is happening underneath.
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
