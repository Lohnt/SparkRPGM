import SwiftUI
import UIKit

struct LauncherCustomizationView: View {

    @EnvironmentObject private var launcher: LauncherSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var preview: UIImage?
    @State private var isSavingWallpaper = false
    @State private var errorText: String?

    private var accent: Color { launcher.settings.accentColor }

    var body: some View {
        NavigationView {
            ZStack {
                SparkTheme.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerPanel
                        accentPanel
                        accentLinePanel
                        layoutPanel
                        wallpaperPanel
                        panel("APP ICON") {
                            AppIconPickerView()
                        }
                        resetButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(accent)
                }
            }
            .onAppear(perform: loadPreview)
            .onChange(of: launcher.wallpaperRevision) { _ in loadPreview() }
            .onChange(of: launcher.settings.wallpaperVersion) { _ in loadPreview() }
            .alert(item: Binding(
                get: { errorText.map { WallpaperAlert(message: $0) } },
                set: { if $0 == nil { errorText = nil } }
            )) { item in
                Alert(
                    title: Text("Wallpaper"),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
    }

    // MARK: - Panels

    private var headerPanel: some View {
        panel("LAUNCHER NAME") {
            TextField("SparkRPGM", text: binding(\.headerTitle))
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 15))
                .foregroundColor(SparkTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )

            Text("Shown at the top of the library.")
                .font(.system(size: 11))
                .foregroundColor(SparkTheme.textTertiary)
        }
    }

    private var accentPanel: some View {
        panel("ACCENT COLOUR") {
            HStack(spacing: 10) {
                ForEach(LauncherSettings.accentPresets, id: \.self) { hex in
                    Button {
                        launcher.settings.accentHex = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle().stroke(
                                    Color.white.opacity(
                                        launcher.settings.accentHex.lowercased() == hex.lowercased() ? 0.9 : 0.10
                                    ),
                                    lineWidth: launcher.settings.accentHex.lowercased() == hex.lowercased() ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            ColorPicker(
                "Custom accent",
                selection: Binding(
                    get: { Color(hex: launcher.settings.accentHex) },
                    set: { launcher.settings.accentHex = $0.hexString }
                ),
                supportsOpacity: false
            )
            .font(.system(size: 13))
            .foregroundColor(SparkTheme.textSecondary)
        }
    }

    private var accentLinePanel: some View {
        panel("GAME LINE COLOUR") {
            Text("The 4pt bar on the left of every list row.")
                .font(.system(size: 11))
                .foregroundColor(SparkTheme.textTertiary)

            HStack(spacing: 9) {
                ForEach(Array(LauncherSettings.linePresets.prefix(7)), id: \.self) { hex in
                    Button {
                        launcher.settings.accentLineHex = hex
                        launcher.settings.accentLineAutoByEngine = false
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().stroke(
                                    Color.white.opacity(
                                        !launcher.settings.accentLineAutoByEngine
                                            && launcher.settings.accentLineHex.lowercased() == hex.lowercased()
                                            ? 0.9 : 0.10
                                    ),
                                    lineWidth: 1.5
                                )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            ColorPicker(
                "Custom line colour",
                selection: Binding(
                    get: { Color(hex: launcher.settings.accentLineHex) },
                    set: {
                        launcher.settings.accentLineHex = $0.hexString
                        launcher.settings.accentLineAutoByEngine = false
                    }
                ),
                supportsOpacity: false
            )
            .font(.system(size: 13))
            .foregroundColor(SparkTheme.textSecondary)
            .disabled(launcher.settings.accentLineAutoByEngine)
            .opacity(launcher.settings.accentLineAutoByEngine ? 0.4 : 1)

            Toggle(isOn: binding(\.accentLineAutoByEngine)) {
                Text("Colour by engine")
                    .font(.system(size: 13))
                    .foregroundColor(SparkTheme.textPrimary)
            }
            .toggleStyle(SwitchToggleStyle(tint: accent))

            Text("A game can override this from its long-press menu.")
                .font(.system(size: 10))
                .foregroundColor(SparkTheme.textTertiary)
        }
    }

    private var layoutPanel: some View {
        panel("LIBRARY") {
            Picker("Library style", selection: binding(\.viewStyle)) {
                ForEach(LibraryViewStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(SegmentedPickerStyle())

            Text(launcher.settings.viewStyle.subtitle)
                .font(.system(size: 11))
                .foregroundColor(SparkTheme.textTertiary)

            if launcher.settings.viewStyle == .prismIcons {
                Picker("Card size", selection: binding(\.cardSize)) {
                    ForEach(CardSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }

            HStack {
                Text("Sort")
                    .font(.system(size: 13))
                    .foregroundColor(SparkTheme.textPrimary)
                Spacer()
                Picker("Sort", selection: binding(\.sort)) {
                    ForEach(LibrarySort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .accentColor(accent)
            }
        }
    }

    private var wallpaperPanel: some View {
        panel("BACKGROUND") {
            wallpaperPreview

            HStack(spacing: 8) {
                actionButton(title: "Photos", symbol: "photo.on.rectangle") {
                    presentWallpaperPhoto()
                }
                actionButton(title: "Files", symbol: "folder") {
                    presentWallpaperFile()
                }
                if launcher.wallpaperExists {
                    actionButton(title: "Remove", symbol: "trash", destructive: true) {
                        launcher.removeWallpaper()
                        preview = nil
                    }
                }
                Spacer(minLength: 0)
            }

            if isSavingWallpaper {
                Text("Saving…")
                    .font(.system(size: 11))
                    .foregroundColor(SparkTheme.textSecondary)
            }

            sliderRow(title: "Blur", value: binding(\.wallpaperBlur), range: 0...30, format: { "\(Int($0))" })
            sliderRow(title: "Dim", value: binding(\.dimOpacity), range: 0...0.75, format: { "\(Int($0 * 100))%" })

            Divider()
                .background(SparkTheme.hairline)

            Toggle(isOn: binding(\.ambientCoverEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply cover tint to background")
                        .font(.system(size: 13))
                        .foregroundColor(SparkTheme.textPrimary)
                    Text("Blends the most recently played cover behind the header.")
                        .font(.system(size: 10))
                        .foregroundColor(SparkTheme.textTertiary)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: accent))

            if launcher.settings.ambientCoverEnabled {
                sliderRow(
                    title: "Cover intensity",
                    value: binding(\.ambientCoverIntensity),
                    range: 0...1,
                    format: { "\(Int($0 * 100))%" }
                )
            }
        }
    }

    private var wallpaperPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SparkTheme.panelRaised)

            if let preview = preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: CGFloat(max(0, launcher.settings.wallpaperBlur)) * 0.5)
                    .clipped()
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(SparkTheme.textTertiary)
                    Text("No wallpaper")
                        .font(.system(size: 10))
                        .foregroundColor(SparkTheme.textTertiary)
                }
            }

            Color.black.opacity(min(launcher.settings.dimOpacity, 0.28))

            HStack {
                Text(launcher.settings.headerTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SparkTheme.textPrimary)
                Spacer()
            }
            .padding(12)
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
        )
    }

    private var resetButton: some View {
        Button {
            launcher.resetAppearance()
            loadPreview()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
                Text("Reset appearance")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundColor(SparkTheme.textSecondary)
            .sparkPanel(cornerRadius: 10, fill: SparkTheme.panel)
        }
    }

    // MARK: - Building blocks

    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .sparkSectionLabel()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .sparkPanel(cornerRadius: 14)
    }

    private func actionButton(
        title: String,
        symbol: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(destructive ? Color.red.opacity(0.14) : Color.white.opacity(0.06))
            )
            .foregroundColor(destructive ? Color(red: 0.95, green: 0.48, blue: 0.45) : SparkTheme.textSecondary)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(SparkTheme.textSecondary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(SparkTheme.textTertiary)
            }
            Slider(value: value, in: range)
                .accentColor(accent)
        }
    }

    // MARK: - Helpers

    private func binding<T>(_ keyPath: WritableKeyPath<LauncherSettings, T>) -> Binding<T> {
        Binding(
            get: { launcher.settings[keyPath: keyPath] },
            set: { launcher.settings[keyPath: keyPath] = $0 }
        )
    }

    private func loadPreview() {
        preview = nil
        guard FileManager.default.fileExists(atPath: AppPaths.wallpaper.path) else { return }

        let url = AppPaths.wallpaper
        DispatchQueue.global(qos: .userInitiated).async {
            let image = autoreleasepool {
                ThumbnailCache.downsample(url: url, maxPixel: 900)
            }
            DispatchQueue.main.async {
                preview = image
            }
        }
    }

    // MARK: - Pickers

    private func presentWallpaperPhoto() {
        PhotoPickerPresenter.shared.present { image in
            applyWallpaper(image)
        }
    }

    private func presentWallpaperFile() {
        DocumentPickerPresenter.shared.present(
            contentTypes: DocumentPickerTypes.images,
            allowsMultipleSelection: false
        ) { documents in
            guard let document = documents.first else { return }
            isSavingWallpaper = true

            DispatchQueue.global(qos: .userInitiated).async {
                let data = try? Data(contentsOf: document.url, options: .mappedIfSafe)
                let image = data.flatMap { UIImage(data: $0) }
                DispatchQueue.main.async {
                    applyWallpaper(image)
                }
            }
        }
    }

    private func applyWallpaper(_ image: UIImage?) {
        guard let image = image else {
            isSavingWallpaper = false
            errorText = "That image could not be read."
            return
        }

        isSavingWallpaper = true
        launcher.setWallpaper(image) { success in
            isSavingWallpaper = false
            if success {
                errorText = nil
                loadPreview()
            } else {
                errorText = "The wallpaper could not be saved."
            }
        }
    }
}

private struct WallpaperAlert: Identifiable {
    let id = UUID()
    let message: String
}
