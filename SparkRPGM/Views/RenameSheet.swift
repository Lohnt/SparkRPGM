import SwiftUI

struct RenameSheet: View {

    let game: Game
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var errorText: String?
    @FocusState private var focused: Bool

    init(game: Game, onSave: @escaping (String) -> Void) {
        self.game = game
        self.onSave = onSave
        _text = State(initialValue: game.title)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.10).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    Text("Rename game")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    Text("This renames the folder in Documents/games and moves the matching save folder with it.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Game name", text: $text)
                        .focused($focused)
                        .textFieldStyle(PlainTextFieldStyle())
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if let errorText = errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                    }

                    Spacer()

                    HStack(spacing: 12) {
                        Button("Cancel") { dismiss() }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button("Save") { save() }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(red: 0.49, green: 0.36, blue: 1.0))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(22)
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
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
