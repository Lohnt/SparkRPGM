import SwiftUI

/// Sheet used by `Change Line Color` in a game's long-press menu.
///
/// Stores a per-game hex override in `GameMetadata.accentColorHex`. Clearing the
/// override (or tapping *Launcher Colour*) falls back to the launcher-wide line
/// colour, which may itself be *Auto by engine*.
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

    private var effectiveColor: Color {
        selection.isEmpty ? launcher.settings.lineColor(for: game) : Color(hex: selection)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        previewSection
                        presetSection
                        customSection
                        fallbackSection
                    }
                    .padding(20)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("Line Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(launcher.settings.accentColor)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Sections

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(game.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)

            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(effectiveColor)
                    .frame(width: 4)
                    .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(game.statsLine)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.leading, 12)

                Spacer(minLength: 8)
            }
            .padding(.trailing, 14)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Presets")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(LauncherSettings.linePresets, id: \.self) { hex in
                    Button {
                        apply(hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Circle().stroke(
                                    Color.white.opacity(isSelected(hex) ? 0.95 : 0.12),
                                    lineWidth: 2
                                )
                            )
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            ColorPicker(
                "Pick a colour",
                selection: Binding(
                    get: { effectiveColor },
                    set: { apply($0.hexString) }
                ),
                supportsOpacity: false
            )
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.7))

            Button {
                apply(game.engine.badgeColor.hexString)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wand.and.stars")
                    Text("Match \(game.engine.rawValue) engine colour")
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.07))
                .foregroundColor(.white.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                selection = ""
                store.setLineColor(nil, for: game)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Use Launcher Colour")
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.06))
                .foregroundColor(.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Text(launcher.settings.accentLineAutoByEngine
                 ? "The launcher line colour is currently automatic (one colour per engine)."
                 : "The launcher line colour is \(launcher.settings.accentLineHex).")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
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
