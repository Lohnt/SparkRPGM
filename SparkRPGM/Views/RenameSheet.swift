import SwiftUI

struct RenameSheet: View {

    let game: Game
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var launcher: LauncherSettingsStore

    @State private var text: String
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var accent: Color { launcher.settings.accentColor }

    init(game: Game, onSave: @escaping (String) -> Void) {
        self.game = game
        self.onSave = onSave
        _text = State(initialValue: game.title)
    }

    var body: some View {
        NavigationView {
            ZStack {
                SparkTheme.canvas.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Rename game")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(SparkTheme.textPrimary)

                    Text("Renames the folder in Documents/games and moves the matching save folder with it.")
                        .font(.system(size: 12))
                        .foregroundColor(SparkTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Game name", text: $text)
                        .focused($focused)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 15))
                        .foregroundColor(SparkTheme.textPrimary)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
                        )

                    if let errorText = errorText {
                        Text(errorText)
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.42))
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        Button("Cancel") { dismiss() }
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.white.opacity(0.06))
                            .foregroundColor(SparkTheme.textSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                        Button("Save") { save() }
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(accent)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
                .padding(22)
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focused = true
            }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "Enter a name first."
            return
        }
        onSave(trimmed)
        dismiss()
    }
}
