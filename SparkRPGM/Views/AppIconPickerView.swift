import SwiftUI
import UIKit

/// Every icon this build ships. The `rawValue` doubles as the
/// `CFBundleAlternateIcons` key in `Info.plist`, so the two stay in lockstep.
enum AppIconOption: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case editor = "Editor"
    case orbit = "Orbit"
    case vinyl = "Vinyl"
    case cosmos = "Cosmos"
    case amethyst = "Amethyst"
    case y2kDisc = "Y2K Disc"
    case cassette = "Cassette"
    case invincible = "Invincible"
    case blueprint = "Blueprint"

    var id: String { rawValue }

    var title: String { rawValue }

    /// `nil` restores the primary `AppIcon`.
    var alternateName: String? {
        self == .default ? nil : rawValue
    }

    /// 1024px preview shipped in `Resources/IconPreviews`.
    var previewName: String {
        switch self {
        case .default: return "PreviewDefault"
        case .y2kDisc: return "PreviewY2KDisc"
        default: return "Preview" + rawValue
        }
    }

    /// Loose PNGs iOS resolves for `CFBundleIconFiles`. They must sit at the
    /// root of `SparkRPGM.app`, never in an `IconAssets` subfolder.
    var bundleFileNames: [String] {
        guard let name = alternateName else { return [] }
        return [
            "\(name).png",
            "\(name)@2x.png",
            "\(name)@3x.png",
            "\(name)~ipad.png",
            "\(name)@2x~ipad.png",
            "\(name)-76.png",
            "\(name)-76@2x.png",
            "\(name)-83.5.png",
            "\(name)-83.5@2x.png",
            "\(name)-83.5@2x~ipad.png",
        ]
    }

    /// Any icon files this build failed to copy into the bundle root.
    static func missingBundleFiles(for option: AppIconOption) -> [String] {
        option.bundleFileNames.filter { file in
            let nsName = file as NSString
            let resource = nsName.deletingPathExtension
            let ext = nsName.pathExtension
            return Bundle.main.url(forResource: resource, withExtension: ext) == nil
        }
    }

    static func current() -> AppIconOption {
        guard let name = UIApplication.shared.alternateIconName else { return .default }
        return AppIconOption(rawValue: name) ?? .default
    }

    /// A previously selected icon may no longer exist after an update.
    static func isKnown(alternateName name: String?) -> Bool {
        guard let name = name else { return true }
        return AppIconOption(rawValue: name) != nil
    }
}

/// Five-column icon grid. Each tile is the squircle preview plus one label, and
/// the selection outline hugs the preview only.
struct AppIconPickerView: View {

    @EnvironmentObject private var launcher: LauncherSettingsStore

    @State private var selected: AppIconOption = AppIconOption.current()
    @State private var errorText: String?
    @State private var isApplying = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 14),
        count: 5
    )

    private var accent: Color { launcher.settings.accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 16) {
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
        .onAppear(perform: syncSelection)
    }

    private func tile(_ option: AppIconOption) -> some View {
        let isSelected = selected == option

        return Button {
            apply(option)
        } label: {
            VStack(spacing: 8) {
                iconPreview(for: option)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 56, maxHeight: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(
                                isSelected ? accent : Color.white.opacity(0.08),
                                lineWidth: 1.5
                            )
                    )

                Text(option.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Color.white : Color(hex: "#D1D1D6"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .opacity(isApplying ? 0.6 : 1)
            .contentShape(Rectangle())
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
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(SparkTheme.rowHighlight)
                .overlay(
                    Text(option.title.prefix(1).uppercased())
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(SparkTheme.textTertiary)
                )
        }
    }

    private func syncSelection() {
        guard UIApplication.shared.supportsAlternateIcons else {
            selected = .default
            return
        }

        if !AppIconOption.isKnown(alternateName: UIApplication.shared.alternateIconName) {
            // The persisted icon was removed from a previous build. Fall back
            // to the primary icon instead of leaving a dangling name.
            UIApplication.shared.setAlternateIconName(nil) { _ in }
            launcher.settings.appIconName = nil
            selected = .default
            return
        }

        let option = AppIconOption.current()
        selected = option

        let missing = AppIconOption.missingBundleFiles(for: option)
        if !missing.isEmpty {
            errorText = "This build is missing \(missing.joined(separator: ", ")) from the app bundle root. Reinstall SparkRPGM, then choose the icon again."
        }
    }

    private func apply(_ option: AppIconOption) {
        guard option != selected, !isApplying else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorText = "This build does not bundle alternate icons."
            return
        }

        let missing = AppIconOption.missingBundleFiles(for: option)
        guard missing.isEmpty else {
            errorText = "This build is missing \(missing.joined(separator: ", ")) from the app bundle root. iOS cannot switch to an icon it cannot find, so the icon files must be copied flat into SparkRPGM.app."
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
