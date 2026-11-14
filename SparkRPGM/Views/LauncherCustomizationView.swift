import SwiftUI
import UIKit

private enum WallpaperRoute: Identifiable {
    case photo
    case file

    var id: String {
        switch self {
        case .photo: return "photo"
        case .file: return "file"
        }
    }
}

struct LauncherCustomizationView: View {

    @EnvironmentObject private var launcher: LauncherSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var wallpaperRoute: WallpaperRoute?
    @State private var preview: UIImage?
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headerSection
                        accentSection
                        accentLineSection
                        layoutSection
                        wallpaperSection
                        AppIconPickerView()
                            .padding(16)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        resetSection
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Customize Launcher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(launcher.settings.accentColor)
                }
            }
            .sheet(item: $wallpaperRoute) { route in
                switch route {
                case .photo:
                    PhotoPicker(isPresented: wallpaperBinding()) { image in
                        applyWallpaper(image)
                    }
                case .file:
                    FilePicker(
                        isPresented: wallpaperBinding(),
                        contentTypes: FilePickerTypes.images,
                        allowsMultipleSelection: false,
                        onPicked: { urls in
                            guard let url = urls.first else { return }
                            let scope = SecurityScopedResource(url)
                            defer { _ = scope }
                            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                                errorText = "That image could not be read."
                                return
                            }
                            applyWallpaper(image)
                        }
                    )
                }
            }
            .onAppear(perform: loadPreview)
            .onChange(of: launcher.settings.wallpaperVersion) { _ in loadPreview() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launcher Header")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            TextField("SparkRPGM", text: binding(\.headerTitle))
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .padding(12)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Shown in the navigation bar and as the big library title.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accent Colour")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            HStack(spacing: 10) {
                ForEach(LauncherSettings.accentPresets, id: \.self) { hex in
                    Button {
                        launcher.settings.accentHex = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().stroke(
                                    Color.white.opacity(launcher.settings.accentHex.lowercased() == hex.lowercased() ? 0.95 : 0.12),
                                    lineWidth: 2
                                )
                            )
                    }
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
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.7))
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var accentLineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accent Line")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            Text("The 4pt bar on the left edge of every Spark Lines row.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(Array(LauncherSettings.linePresets.prefix(7)), id: \.self) { hex in
                    Button {
                        launcher.settings.accentLineHex = hex
                        launcher.settings.accentLineAutoByEngine = false
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().stroke(
                                    Color.white.opacity(
                                        !launcher.settings.accentLineAutoByEngine
                                            && launcher.settings.accentLineHex.lowercased() == hex.lowercased()
                                            ? 0.95 : 0.12
                                    ),
                                    lineWidth: 2
                                )
                            )
                    }
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
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.7))
            .disabled(launcher.settings.accentLineAutoByEngine)
            .opacity(launcher.settings.accentLineAutoByEngine ? 0.4 : 1)

            Toggle(isOn: binding(\.accentLineAutoByEngine)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-colour by engine")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    Text("MV blue, MZ green, 2000 gold, XP purple…")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: launcher.settings.accentColor))

            Text("A game can override this from its long-press menu → Change Line Color.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library Layout")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            Picker("Library style", selection: binding(\.viewStyle)) {
                ForEach(LibraryViewStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(SegmentedPickerStyle())

            HStack(spacing: 6) {
                Image(systemName: launcher.settings.viewStyle.symbolName)
                    .font(.system(size: 10))
                    .foregroundColor(launcher.settings.accentColor)
                Text(launcher.settings.viewStyle.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Picker("Sort", selection: binding(\.sort)) {
                    ForEach(LibrarySort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .accentColor(launcher.settings.accentColor)
            }

            Text("Card glass opacity")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
            slider(\.glassOpacity, range: 0...0.85)
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var wallpaperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wallpaper")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.12, green: 0.10, blue: 0.22), Color.black],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let preview = preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: CGFloat(max(0, launcher.settings.wallpaperBlur)))
                        .clipped()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .foregroundColor(.white.opacity(0.3))
                        Text("No wallpaper")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }

                Color.black.opacity(launcher.settings.dimOpacity)

                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(launcher.settings.accentColor)
                    Text(launcher.settings.headerTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(14)
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            HStack(spacing: 8) {
                actionButton(title: "Photos", symbol: "photo.on.rectangle") {
                    wallpaperRoute = .photo
                }
                actionButton(title: "Files", symbol: "folder") {
                    wallpaperRoute = .file
                }
                if launcher.wallpaperExists {
                    actionButton(title: "Remove", symbol: "trash", destructive: true) {
                        launcher.removeWallpaper()
                        preview = nil
                    }
                }
            }

            if let errorText = errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 1, green: 0.46, blue: 0.46))
            }

            sliderRow(title: "Background blur", value: binding(\.wallpaperBlur), range: 0...30, format: { "\(Int($0))" })
            sliderRow(title: "Dim overlay", value: binding(\.dimOpacity), range: 0...0.85, format: { "\(Int($0 * 100))%" })
            sliderRow(title: "Card glass", value: binding(\.glassOpacity), range: 0...0.85, format: { "\(Int($0 * 100))%" })
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var resetSection: some View {
        Button {
            launcher.resetAppearance()
        } label: {
            HStack {
                Image(systemName: "arrow.counterclockwise")
                Text("Reset appearance")
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.06))
            .foregroundColor(.white.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Building blocks

    private func actionButton(title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(destructive ? Color.red.opacity(0.18) : Color.white.opacity(0.08))
            .foregroundColor(destructive ? Color(red: 1, green: 0.55, blue: 0.55) : .white.opacity(0.8))
            .clipShape(Capsule())
        }
    }

    private func slider(_ keyPath: WritableKeyPath<LauncherSettings, Double>, range: ClosedRange<Double>) -> some View {
        Slider(value: binding(keyPath), in: range)
            .accentColor(launcher.settings.accentColor)
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
            Slider(value: value, in: range)
                .accentColor(launcher.settings.accentColor)
        }
    }

    // MARK: - Helpers

    private func binding<T>(_ keyPath: WritableKeyPath<LauncherSettings, T>) -> Binding<T> {
        Binding(
            get: { launcher.settings[keyPath: keyPath] },
            set: { launcher.settings[keyPath: keyPath] = $0 }
        )
    }

    private func wallpaperBinding() -> Binding<Bool> {
        Binding(
            get: { wallpaperRoute != nil },
            set: { presented in
                if !presented { wallpaperRoute = nil }
            }
        )
    }

    private func loadPreview() {
        guard FileManager.default.fileExists(atPath: AppPaths.wallpaper.path) else {
            preview = nil
            return
        }
        let url = AppPaths.wallpaper
        DispatchQueue.global(qos: .userInitiated).async {
            let image = ThumbnailCache.downsample(url: url, maxPixel: 900)
            DispatchQueue.main.async {
                preview = image
            }
        }
    }

    private func applyWallpaper(_ image: UIImage) {
        if launcher.setWallpaper(image) {
            loadPreview()
            errorText = nil
        } else {
            errorText = "The wallpaper could not be saved."
        }
    }
}
