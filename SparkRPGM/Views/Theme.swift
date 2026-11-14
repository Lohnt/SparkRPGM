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

// MARK: - Panels

/// Background for panels, cards and rows.
///
/// Flat mode is a matte fill. Liquid Glass mode layers an iOS 15 material, a
/// translucent tint of the requested fill and a top sheen, so text stays crisp
/// while the wallpaper reads through the surface.
struct SparkSurfaceBackground: View {

    @EnvironmentObject private var launcher: LauncherSettingsStore

    var cornerRadius: CGFloat = 12
    var fill: Color = SparkTheme.panel

    private var intensity: Double {
        min(1, max(0, launcher.settings.liquidGlassIntensity))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glass = launcher.settings.liquidGlassEnabled

        ZStack {
            if glass {
                // Material first, then a light tint. Keeping the tint under
                // 0.5 lets the wallpaper and cover art refract through instead
                // of turning the panel into flat grey.
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(hex: "#121216").opacity(0.45 - 0.25 * intensity))
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.14 * intensity),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.35)
                    )
                )
            } else {
                shape.fill(fill)
            }
        }
        .compositingGroup()
        .shadow(
            color: Color.black.opacity(glass ? 0.05 + 0.20 * intensity : 0),
            radius: glass ? 3 + 10 * intensity : 0,
            x: 0,
            y: glass ? 4 : 0
        )
    }
}

/// Hairline in flat mode, specular top-edge highlight in Liquid Glass mode.
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
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.30 * intensity),
                        Color.white.opacity(0.06),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.5
            )
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
