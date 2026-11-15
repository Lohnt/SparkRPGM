import SwiftUI
import UIKit

/// One place for the app's visual language.
///
/// The launcher is a dark utility surface: a matte charcoal canvas, slightly
/// raised neutral panels, hairline separators and crisp SF text. Colour is
/// deliberately scarce: the player's accent is reserved for selection,
/// controls and the per-game line colour.
enum SparkTheme {

    // MARK: - Surfaces

    static let canvas = Color(hex: "#0E0E10")
    static let panel = Color(hex: "#16161A")
    static let panelRaised = Color(hex: "#1C1C21")
    static let rowHighlight = Color(hex: "#222228")

    // MARK: - Text

    static let textPrimary = Color(hex: "#F5F5F7")
    static let textSecondary = Color(hex: "#8E8E93")
    static let textTertiary = Color(hex: "#5C5C63")

    // MARK: - Lines

    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)

    /// A true hairline on the current display: 0.5pt on 2x, 0.33pt on 3x.
    static var hairlineWidth: CGFloat {
        max(0.5, 1 / UIScreen.main.scale)
    }
}

// MARK: - Liquid Glass

/// Native iOS 15 blur behind every Liquid Glass surface.
///
/// Wraps UIKit's `UIVisualEffectView` with `.systemThinMaterialDark` so the
/// underlying wallpaper and ambient cover art visibly shine and refract through
/// every panel while keeping foreground text legible.
struct VisualEffectBlur: UIViewRepresentable {

    var style: UIBlurEffect.Style = .systemThinMaterialDark

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

// MARK: - Panels

/// Background for panels, cards and rows.
///
/// Flat mode is a matte fill. Liquid Glass mode layers a real
/// `UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))` blur,
/// a very faint translucent white tint (at most 0.04 * intensity) to let colors
/// refract without flat grey murkiness, and a subtle glossy gradient over the top 28%.
struct SparkSurfaceBackground: View {

    @EnvironmentObject private var launcher: LauncherSettingsStore

    var cornerRadius: CGFloat = 12
    var fill: Color = SparkTheme.panel

    private var intensity: Double {
        min(1, max(0, launcher.settings.liquidGlassIntensity))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if launcher.settings.liquidGlassEnabled {
                VisualEffectBlur(style: .systemThinMaterialDark)
                    .clipShape(shape)

                // Translucent refraction layer instead of heavy dark #16161C
                shape.fill(Color.white.opacity(0.04 * intensity))

                // Subtle top glossy gradient over the top 28% of the panel
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.14 * intensity), location: 0.0),
                        .init(color: Color.clear, location: 0.28),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
            } else {
                shape.fill(fill)
            }
        }
        .shadow(
            color: launcher.settings.liquidGlassEnabled ? Color.black.opacity(0.35) : Color.clear,
            radius: 10,
            x: 0,
            y: 4
        )
    }
}

/// Hairline in flat mode, directional specular rim border and inner inset highlight in Liquid Glass.
struct SparkSurfaceBorder: View {

    @EnvironmentObject private var launcher: LauncherSettingsStore

    var cornerRadius: CGFloat = 12
    var borderOpacity: Double = 0.08

    private var intensity: Double {
        min(1, max(0, launcher.settings.liquidGlassIntensity))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if launcher.settings.liquidGlassEnabled {
            ZStack {
                // Outer 1pt directional specular rim border (top-left to bottom-right)
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.50 * intensity),
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.28 * intensity),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

                // Inner 0.5pt inset highlight
                RoundedRectangle(
                    cornerRadius: max(0, cornerRadius - 0.5),
                    style: .continuous
                )
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28 * intensity),
                            Color.white.opacity(0.04 * intensity),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
                .padding(0.5)
            }
        } else {
            shape.strokeBorder(
                Color.white.opacity(borderOpacity),
                lineWidth: SparkTheme.hairlineWidth
            )
        }
    }
}

struct SparkPanelModifier: ViewModifier {

    var cornerRadius: CGFloat = 12
    var fill: Color = SparkTheme.panel
    var borderOpacity: Double = 0.08

    func body(content: Content) -> some View {
        content
            .background(
                SparkSurfaceBackground(cornerRadius: cornerRadius, fill: fill)
            )
            .overlay(
                SparkSurfaceBorder(cornerRadius: cornerRadius, borderOpacity: borderOpacity)
                    .allowsHitTesting(false)
            )
    }
}

extension View {

    /// Surface fill only. Pair with `sparkBorder` when the content must stay
    /// above the border, as cover cards do.
    func sparkSurface(
        cornerRadius: CGFloat = 12,
        fill: Color = SparkTheme.panel
    ) -> some View {
        background(SparkSurfaceBackground(cornerRadius: cornerRadius, fill: fill))
    }

    /// Border only, so callers that draw their own fill still pick up the
    /// specular highlight.
    func sparkBorder(
        cornerRadius: CGFloat = 12,
        borderOpacity: Double = 0.08
    ) -> some View {
        overlay(
            SparkSurfaceBorder(cornerRadius: cornerRadius, borderOpacity: borderOpacity)
                .allowsHitTesting(false)
        )
    }

    /// Neutral elevated surface used by sections, rows and banners.
    func sparkPanel(
        cornerRadius: CGFloat = 12,
        fill: Color = SparkTheme.panel,
        borderOpacity: Double = 0.08
    ) -> some View {
        modifier(SparkPanelModifier(cornerRadius: cornerRadius, fill: fill, borderOpacity: borderOpacity))
    }
}

extension Text {

    /// Uppercase caption used above grouped controls.
    ///
    /// Declared on `Text` because `View.tracking(_:)` is iOS 16+, while
    /// `Text.tracking(_:)` has shipped since iOS 13.
    func sparkSectionLabel() -> Text {
        self
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundColor(SparkTheme.textSecondary)
    }
}
