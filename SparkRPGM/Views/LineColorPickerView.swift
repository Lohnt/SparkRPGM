import SwiftUI

/// Sheet used by `Change Line Color` in a game's long-press menu.
///
/// Stores a per-game hex override in `GameMetadata.accentColorHex`. Clearing the
/// override falls back to the launcher-wide line colour, which may itself be
/// coloured by engine.
struct LineColorPickerView: View {

    let game: Game

    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var launcher: LauncherSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String

    init(game: Game) {
        self.game = game
        _selection = State(initialValue: game.lineColorHex ?? "")
    }

    private var accent: Color { launcher.settings.accentColor }

    private var effectiveColor: Color {
        selection.isEmpty ? launcher.settings.lineColor(for: game) : Color(hex: selection)
    }

    var body: some View {
        NavigationView {
            ZStack {
                SparkTheme.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        previewSection
                        presetSection
                        customSection
                        fallbackSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("Line Colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(accent)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var previewSection: some View {
        section("PREVIEW") {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(effectiveColor)
                    .frame(width: 4)
                    .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SparkTheme.textPrimary)
                        .lineLimit(1)
                    Text(game.statsLine)
                        .font(.system(size: 11))
                        .foregroundColor(SparkTheme.textSecondary)
                }
                .padding(.leading, 12)

                Spacer(minLength: 8)
            }
            .padding(.trailing, 14)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(SparkTheme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
            )
        }
    }

    private var presetSection: some View {
        section("PRESETS") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(LauncherSettings.linePresets, id: \.self) { hex in
                    Button {
                        apply(hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle().stroke(
                                    Color.white.opacity(isSelected(hex) ? 0.9 : 0.10),
                                    lineWidth: isSelected(hex) ? 2 : 1
                                )
                            )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    private var customSection: some View {
        section("CUSTOM") {
            ColorPicker(
                "Pick a colour",
                selection: Binding(
                    get: { effectiveColor },
                    set: { apply($0.hexString) }
                ),
                supportsOpacity: false
            )
            .font(.system(size: 13))
            .foregroundColor(SparkTheme.textSecondary)

            Button {
                apply(game.engine.badgeColor.hexString)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11))
                    Text("Match \(game.engine.rawValue) engine colour")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .foregroundColor(SparkTheme.textSecondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                selection = ""
                store.setLineColor(nil, for: game)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                    Text("Use Launcher Colour")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .foregroundColor(SparkTheme.textSecondary)
            }
            .buttonStyle(PlainButtonStyle())

            Text(launcher.settings.accentLineAutoByEngine
                 ? "The launcher line colour is currently automatic, one colour per engine."
                 : "The launcher line colour is \(launcher.settings.accentLineHex).")
                .font(.system(size: 10))
                .foregroundColor(SparkTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .sparkSectionLabel()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .sparkPanel(cornerRadius: 14)
    }

    // MARK: - Actions

    private func apply(_ hex: String) {
        selection = hex
        store.setLineColor(hex, for: game)
    }

    private func isSelected(_ hex: String) -> Bool {
        !selection.isEmpty && selection.lowercased() == hex.lowercased()
    }
}
