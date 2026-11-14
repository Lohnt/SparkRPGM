import SwiftUI
import UIKit

// MARK: - Sections

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case wallpaper = "Wallpaper"
    case library = "Library"
    case appIcon = "App Icon"
    case storage = "Storage"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .wallpaper: return "photo"
        case .library: return "square.grid.2x2"
        case .appIcon: return "app.badge"
        case .storage: return "internaldrive"
        }
    }

    var keywords: [String] {
        switch self {
        case .appearance:
            return ["accent", "colour", "color", "hue", "intensity", "tint", "dim", "blur",
                    "cover", "button", "highlight", "vivid", "soft", "gray"]
        case .wallpaper:
            return ["wallpaper", "background", "photo", "image", "files", "remove", "picture"]
        case .library:
            return ["library", "style", "lines", "prism", "grid", "card", "size", "sort",
                    "engine", "line", "colour", "color", "name", "title"]
        case .appIcon:
            return ["icon", "icons", "alternate", "home screen", "app"]
        case .storage:
            return ["storage", "space", "disk", "size", "reset", "appearance", "backups", "saves"]
        }
    }

    func matches(_ query: String) -> Bool {
        if rawValue.localizedCaseInsensitiveContains(query) { return true }
        return keywords.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

private struct StorageRow: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let detail: String
}

// MARK: - Settings modal

struct LauncherCustomizationView: View {

    @EnvironmentObject private var launcher: LauncherSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var section: SettingsSection = .appearance
    @State private var search = ""
    @State private var preview: UIImage?
    @State private var isSavingWallpaper = false
    @State private var errorText: String?
    @State private var storageRows: [StorageRow] = []
    @State private var freeSpace: String?

    private var accent: Color { launcher.settings.accentColor }

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleSections: [SettingsSection] {
        guard !query.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { $0.matches(query) }
    }

    private var displayedSections: [SettingsSection] {
        query.isEmpty ? [section] : visibleSections
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 520

            VStack(spacing: 0) {
                titleBar

                hairline

                if isWide {
                    HStack(spacing: 0) {
                        rail
                            .frame(width: 208)
                        verticalHairline
                        contentPane
                    }
                } else {
                    compactRail
                    contentPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(hex: "#18181B"))
        .preferredColorScheme(.dark)
        .onAppear(perform: prepare)
        .onChange(of: launcher.wallpaperRevision) { _ in loadPreview() }
        .onChange(of: launcher.settings.wallpaperVersion) { _ in loadPreview() }
        .onChange(of: search) { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !section.matches(trimmed), let first = visibleSections.first {
                section = first
            }
        }
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

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: 10) {
            Text("Settings")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(SparkTheme.textPrimary)

            Spacer(minLength: 8)

            Button("Done") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(accent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Color(hex: "#121214"))
    }

    private var hairline: some View {
        Rectangle()
            .fill(SparkTheme.hairline)
            .frame(height: SparkTheme.hairlineWidth)
    }

    private var verticalHairline: some View {
        Rectangle()
            .fill(SparkTheme.hairline)
            .frame(width: SparkTheme.hairlineWidth)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 14)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(visibleSections) { item in
                        railButton(item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: "#121214"))
    }

    private var compactRail: some View {
        VStack(spacing: 10) {
            searchField

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleSections) { item in
                        compactButton(item)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .background(Color(hex: "#121214"))
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(SparkTheme.textTertiary)

            TextField("Search settings...", text: $search)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 12))
                .foregroundColor(SparkTheme.textPrimary)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(SparkTheme.textTertiary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: "#1C1C21"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
        )
    }

    private func railButton(_ item: SettingsSection) -> some View {
        let isActive = section == item

        return Button {
            section = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 17)
                Text(item.rawValue)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(isActive ? Color.white : Color(hex: "#9A9AA0"))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func compactButton(_ item: SettingsSection) -> some View {
        let isActive = section == item

        return Button {
            section = item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(item.rawValue)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .foregroundColor(isActive ? Color.white : Color(hex: "#9A9AA0"))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isActive ? accent : Color(hex: "#1C1C21"))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var contentPane: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                if displayedSections.isEmpty {
                    noResults
                } else {
                    ForEach(displayedSections) { item in
                        pane(for: item)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(hex: "#18181B"))
    }

    private var noResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No settings match \"\(query)\"")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(SparkTheme.textPrimary)
            Text("Try accent, wallpaper, icon or storage.")
                .font(.system(size: 12))
                .foregroundColor(SparkTheme.textSecondary)
        }
        .padding(.top, 30)
    }

    // MARK: - Panes

    @ViewBuilder
    private func pane(for item: SettingsSection) -> some View {
        switch item {
        case .appearance: appearancePane
        case .wallpaper: wallpaperPane
        case .library: libraryPane
        case .appIcon: appIconPane
        case .storage: storagePane
        }
    }

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle("Appearance")

            group("ACCENT COLOR") {
                accentSwatchRow

                SparkSlider(
                    title: "Hue",
                    valueText: "\(Int((hue * 360).rounded()))°",
                    value: hueBinding,
                    range: 0...1
                ) {
                    LinearGradient(
                        colors: (0...12).map {
                            Color(hue: Double($0) / 12, saturation: 0.85, brightness: 1)
                        },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                SparkSlider(
                    title: "Intensity",
                    valueText: "\(Int((intensity * 100).rounded()))%",
                    value: intensityBinding,
                    range: 0...1,
                    bottomLabels: ["Gray", "Soft", "Vivid"]
                ) {
                    LinearGradient(
                        colors: [
                            Color.sparkAccent(hue: hue, saturation: 0.06, brightness: 0.78),
                            accent,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }

            group("BACKGROUND") {
                SparkSlider(
                    title: "Background Dim",
                    valueText: "\(Int((launcher.settings.dimOpacity * 100).rounded()))%",
                    value: binding(\.dimOpacity),
                    range: 0...0.75,
                    bottomLabels: ["Off", "Default", "Full"]
                ) {
                    LinearGradient(
                        colors: [Color(hex: "#2A2A30"), Color.black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                SparkSlider(
                    title: "Background Blur",
                    valueText: "\(Int(launcher.settings.wallpaperBlur.rounded())) pt",
                    value: binding(\.wallpaperBlur),
                    range: 0...30,
                    bottomLabels: ["Off", "Default", "Full"]
                ) {
                    LinearGradient(
                        colors: [Color(hex: "#26262B"), Color(hex: "#8E8E93")],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                SparkSlider(
                    title: "Cover Tint Intensity",
                    valueText: "\(Int((launcher.settings.ambientCoverIntensity * 100).rounded()))%",
                    value: binding(\.ambientCoverIntensity),
                    range: 0...1,
                    bottomLabels: ["Off", "Default", "Full"]
                ) {
                    LinearGradient(
                        colors: [Color(hex: "#1C1C21"), accent.opacity(0.7)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .opacity(launcher.settings.ambientCoverEnabled ? 1 : 0.4)
                .disabled(!launcher.settings.ambientCoverEnabled)
            }

            group("TOGGLES") {
                sparkToggle(
                    "Apply cover tint to background",
                    subtitle: "Blends the most recently played cover behind the header.",
                    isOn: binding(\.ambientCoverEnabled)
                )

                sparkToggle(
                    "Highlight primary buttons",
                    subtitle: "Fills import and close actions with the accent color.",
                    isOn: binding(\.highlightPrimaryButtons)
                )
            }
        }
    }

    private var wallpaperPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle("Wallpaper")

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
                Text("Saving...")
                    .font(.system(size: 11))
                    .foregroundColor(SparkTheme.textSecondary)
            }

            Text("Dim and blur live under Appearance, next to the accent controls.")
                .font(.system(size: 11))
                .foregroundColor(SparkTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle("Library")

            group("LAUNCHER NAME") {
                TextField("SparkRPGM", text: binding(\.headerTitle))
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 14))
                    .foregroundColor(SparkTheme.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
                    )
            }

            group("LAYOUT") {
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

            group("GAME LINE COLOR") {
                lineSwatchRow

                ColorPicker(
                    "Custom line color",
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
                .foregroundColor(SparkTheme.textSecondary)

                sparkToggle(
                    "Auto-color library lines by engine",
                    subtitle: "Uses one fixed color per engine instead of the launcher line color.",
                    isOn: binding(\.accentLineAutoByEngine)
                )
            }
        }
    }

    private var appIconPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle("App Icon")

            group("ICON") {
                AppIconPickerView()
            }
        }
    }

    private var storagePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle("Storage")

            group("ON MY IPAD / SPARKRPGM") {
                ForEach(storageRows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(SparkTheme.textSecondary)
                            .frame(width: 18)

                        Text(row.title)
                            .font(.system(size: 13))
                            .foregroundColor(SparkTheme.textPrimary)

                        Spacer(minLength: 8)

                        Text(row.detail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(SparkTheme.textTertiary)
                    }
                    .padding(.vertical, 3)
                }

                if let freeSpace = freeSpace {
                    Divider().background(SparkTheme.hairline)
                    HStack {
                        Text("Free space")
                            .font(.system(size: 13))
                            .foregroundColor(SparkTheme.textSecondary)
                        Spacer()
                        Text(freeSpace)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(SparkTheme.textTertiary)
                    }
                    .padding(.vertical, 3)
                }
            }

            Button {
                launcher.resetAppearance()
                loadPreview()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                    Text("Reset appearance")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundColor(SparkTheme.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SparkTheme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - Controls

    private var accentSwatchRow: some View {
        HStack(spacing: 6) {
            ForEach(LauncherSettings.accentSwatches, id: \.self) { hex in
                let isSelected = launcher.settings.accentHex.lowercased() == hex.lowercased()

                Button {
                    launcher.settings.accentHex = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().stroke(
                                Color.white.opacity(isSelected ? 0.95 : 0.10),
                                lineWidth: isSelected ? 2 : 1
                            )
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            ColorPicker(
                "Custom",
                selection: Binding(
                    get: { Color(hex: launcher.settings.accentHex) },
                    set: { launcher.settings.accentHex = $0.hexString }
                ),
                supportsOpacity: false
            )
            .labelsHidden()

            Text("Custom")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#9A9AA0"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var lineSwatchRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(LauncherSettings.linePresets.prefix(7)), id: \.self) { hex in
                let isSelected = !launcher.settings.accentLineAutoByEngine
                    && launcher.settings.accentLineHex.lowercased() == hex.lowercased()

                Button {
                    launcher.settings.accentLineHex = hex
                    launcher.settings.accentLineAutoByEngine = false
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().stroke(
                                Color.white.opacity(isSelected ? 0.95 : 0.10),
                                lineWidth: isSelected ? 2 : 1
                            )
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            Spacer(minLength: 0)
        }
        .opacity(launcher.settings.accentLineAutoByEngine ? 0.4 : 1)
    }

    private func sparkToggle(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SparkTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E8E93"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: accent))
    }

    private var wallpaperPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SparkTheme.panelRaised)

            if let preview = preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: CGFloat(max(0, launcher.settings.wallpaperBlur)) * 0.5)
                    .clipped()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(SparkTheme.textTertiary)
                    Text("No wallpaper")
                        .font(.system(size: 11))
                        .foregroundColor(SparkTheme.textTertiary)
                }
            }

            Color.black.opacity(min(launcher.settings.dimOpacity, 0.28))

            HStack {
                Text(launcher.settings.headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SparkTheme.textPrimary)
                Spacer()
            }
            .padding(14)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
        )
    }

    // MARK: - Building blocks

    private func paneTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(SparkTheme.textPrimary)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .sparkSectionLabel()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SparkTheme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
        )
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

    // MARK: - Helpers

    private func binding<T>(_ keyPath: WritableKeyPath<LauncherSettings, T>) -> Binding<T> {
        Binding(
            get: { launcher.settings[keyPath: keyPath] },
            set: { launcher.settings[keyPath: keyPath] = $0 }
        )
    }

    private var hue: Double {
        Color(hex: launcher.settings.accentHex).sparkHSB.hue
    }

    private var intensity: Double {
        Color(hex: launcher.settings.accentHex).sparkHSB.saturation
    }

    private var hueBinding: Binding<Double> {
        Binding(
            get: { self.hue },
            set: { newValue in
                let hsb = Color(hex: launcher.settings.accentHex).sparkHSB
                launcher.settings.accentHex = Color.sparkAccent(
                    hue: newValue,
                    saturation: max(0.35, hsb.saturation),
                    brightness: max(0.60, hsb.brightness)
                ).hexString
            }
        )
    }

    private var intensityBinding: Binding<Double> {
        Binding(
            get: { self.intensity },
            set: { newValue in
                let hsb = Color(hex: launcher.settings.accentHex).sparkHSB
                launcher.settings.accentHex = Color.sparkAccent(
                    hue: hsb.hue,
                    saturation: 0.10 + 0.90 * newValue,
                    brightness: 0.72 + 0.28 * newValue
                ).hexString
            }
        )
    }

    private func prepare() {
        loadPreview()
        loadStorage()
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

    private func loadStorage() {
        DispatchQueue.global(qos: .utility).async {
            let folders: [(String, String, URL)] = [
                ("Games", "square.stack.3d.up", AppPaths.games),
                ("Saves", "memorychip", AppPaths.saves),
                ("Backups", "externaldrive", AppPaths.backups),
                ("Theme", "photo", AppPaths.theme),
            ]

            let rows = folders.map { folder -> StorageRow in
                let bytes = AppPaths.size(of: folder.2)
                return StorageRow(
                    title: folder.0,
                    symbol: folder.1,
                    detail: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                )
            }

            let free = DiskSpace.formattedAvailable(at: AppPaths.documents)
            DispatchQueue.main.async {
                storageRows = rows
                freeSpace = free
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

// MARK: - Slider

/// Minimal track slider: optional gradient track, tick marks and bottom labels,
/// with the value rendered at the top right.
private struct SparkSlider<Track: View>: View {

    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var bottomLabels: [String] = []
    @ViewBuilder var track: () -> Track

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(SparkTheme.textSecondary)
                Spacer(minLength: 0)
                Text(valueText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(SparkTheme.textTertiary)
            }

            GeometryReader { geo in
                let usable = max(1, geo.size.width - 14)

                ZStack(alignment: .leading) {
                    track()
                        .frame(height: 8)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )

                    if !bottomLabels.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(Array(bottomLabels.indices), id: \.self) { index in
                                Rectangle()
                                    .fill(Color.white.opacity(0.22))
                                    .frame(width: 1, height: 4)
                                if index < bottomLabels.count - 1 {
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(.horizontal, 1)
                    }

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 4, height: 22)
                        .overlay(
                            Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                        )
                        .offset(x: 7 + usable * fraction - 2)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { gesture in
                        let x = min(max(gesture.location.x - 7, 0), usable)
                        let t = Double(x / usable)
                        value = range.lowerBound + (range.upperBound - range.lowerBound) * t
                    }
                )
            }
            .frame(height: 24)

            if !bottomLabels.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(bottomLabels.enumerated()), id: \.offset) { index, label in
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(SparkTheme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: alignment(for: index))
                    }
                }
            }
        }
    }

    private func alignment(for index: Int) -> Alignment {
        guard bottomLabels.count > 1 else { return .center }
        if index == 0 { return .leading }
        if index == bottomLabels.count - 1 { return .trailing }
        return .center
    }
}

private struct WallpaperAlert: Identifiable {
    let id = UUID()
    let message: String
}
