import SwiftUI
import UIKit

enum AppIconOption: String, CaseIterable, Identifiable {
    case primary = "Default"
    case midnight = "Midnight"
    case retro = "Retro"
    case crimson = "Crimson"
    case neon = "Neon"
    case minimal = "Minimal"

    var id: String { rawValue }

    /// `nil` restores the primary AppIcon.
    var alternateName: String? {
        self == .primary ? nil : rawValue
    }

    var previewName: String { "Preview" + rawValue }

    var subtitle: String {
        switch self {
        case .primary: return "Spark violet"
        case .midnight: return "Deep navy"
        case .retro: return "Sunset pixel"
        case .crimson: return "Ember gold"
        case .neon: return "Neon grid"
        case .minimal: return "Monochrome"
        }
    }

    static func current() -> AppIconOption {
        guard let name = UIApplication.shared.alternateIconName else { return .primary }
        return AppIconOption(rawValue: name) ?? .primary
    }
}

struct AppIconPickerView: View {

    @EnvironmentObject private var launcher: LauncherSettingsStore
    @State private var selected: AppIconOption = AppIconOption.current()
    @State private var errorText: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Icon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            if !UIApplication.shared.supportsAlternateIcons {
                Text("Alternate icons are unavailable in this build. Install the SparkRPGM IPA built by GitHub Actions to switch icons.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(AppIconOption.allCases) { option in
                    Button {
                        apply(option)
                    } label: {
                        VStack(spacing: 7) {
                            ZStack {
                                iconPreview(for: option)
                                    .frame(width: 62, height: 62)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                if selected == option {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(launcher.settings.accentColor, lineWidth: 2.5)
                                }
                            }
                            Text(option.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(selected == option ? .white : .white.opacity(0.55))
                            Text(option.subtitle)
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.32))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(selected == option ? 0.10 : 0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }

            if let errorText = errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 1, green: 0.46, blue: 0.46))
            }
        }
    }

    @ViewBuilder
    private func iconPreview(for option: AppIconOption) -> some View {
        if let image = UIImage(named: option.previewName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [launcher.settings.accentColor, Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                Image(systemName: "sparkles")
                    .foregroundColor(.white.opacity(0.8))
            )
        }
    }

    private func apply(_ option: AppIconOption) {
        guard option != selected else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorText = "This build does not bundle alternate icons."
            return
        }

        UIApplication.shared.setAlternateIconName(option.alternateName) { error in
            DispatchQueue.main.async {
                if let error = error {
                    errorText = error.localizedDescription
                    return
                }
                selected = option
                launcher.settings.appIconName = option.alternateName
                errorText = nil
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}
