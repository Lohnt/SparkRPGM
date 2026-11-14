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
        case .primary: return "Violet"
        case .midnight: return "Navy"
        case .retro: return "Sunset"
        case .crimson: return "Ember"
        case .neon: return "Neon"
        case .minimal: return "Mono"
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
    @State private var isApplying = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var accent: Color { launcher.settings.accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AppIconOption.allCases) { option in
                    tile(option)
                }
            }

            if !UIApplication.shared.supportsAlternateIcons {
                Text("Alternate icons are unavailable in this build.")
                    .font(.system(size: 11))
                    .foregroundColor(SparkTheme.textSecondary)
            }

            if let errorText = errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.95, green: 0.48, blue: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            selected = AppIconOption.current()
        }
    }

    private func tile(_ option: AppIconOption) -> some View {
        let isSelected = selected == option

        return Button {
            apply(option)
        } label: {
            VStack(spacing: 7) {
                iconPreview(for: option)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(option.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? SparkTheme.textPrimary : SparkTheme.textSecondary)
                    .lineLimit(1)

                Text(option.subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(SparkTheme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: "#1E1E24"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? accent.opacity(0.9) : Color.white.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .opacity(isApplying ? 0.6 : 1)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isApplying)
    }

    @ViewBuilder
    private func iconPreview(for option: AppIconOption) -> some View {
        if let image = UIImage(named: option.previewName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SparkTheme.rowHighlight)
                .overlay(
                    Text(option.alternateName?.prefix(1).uppercased() ?? "S")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(SparkTheme.textTertiary)
                )
        }
    }

    private func apply(_ option: AppIconOption) {
        guard option != selected, !isApplying else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorText = "This build does not bundle alternate icons."
            return
        }

        isApplying = true

        UIApplication.shared.setAlternateIconName(option.alternateName) { error in
            DispatchQueue.main.async {
                isApplying = false

                if let error = error {
                    errorText = "iOS rejected the icon change: \(error.localizedDescription)"
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
