import SwiftUI
import UIKit

/// One place for the app's visual language.
///
/// The launcher is a dark utility surface: a matte charcoal canvas, slightly
/// raised neutral panels, hairline separators and crisp SF text. Colour is
/// deliberately scarce — the player's accent is reserved for selection,
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

struct SparkPanelModifier: ViewModifier {

    var cornerRadius: CGFloat = 12
    var fill: Color = SparkTheme.panel
    var borderOpacity: Double = 0.08

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(borderOpacity), lineWidth: SparkTheme.hairlineWidth)
            )
    }
}

extension View {

    /// Neutral elevated surface used by sections, rows and banners.
    func sparkPanel(
        cornerRadius: CGFloat = 12,
        fill: Color = SparkTheme.panel,
        borderOpacity: Double = 0.08
    ) -> some View {
        modifier(SparkPanelModifier(cornerRadius: cornerRadius, fill: fill, borderOpacity: borderOpacity))
    }

    /// Uppercase caption used above grouped controls.
    func sparkSectionLabel() -> some View {
        self
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundColor(SparkTheme.textSecondary)
    }
}
