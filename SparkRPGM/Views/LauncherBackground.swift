import SwiftUI

/// Full-screen wallpaper with an adjustable dim overlay.
/// The source image is downsampled once and cached; the blur radius comes from
/// the theme settings.
struct LauncherBackground: View {

    let settings: LauncherSettings

    @State private var image: UIImage?
    @State private var loadedVersion: Int = -1

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.09),
                    Color(red: 0.09, green: 0.07, blue: 0.16),
                    Color.black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: CGFloat(max(0, settings.wallpaperBlur)))
                    .ignoresSafeArea()
            }

            // Always keep the text readable, even with no wallpaper.
            Color.black.opacity(settings.dimOpacity).ignoresSafeArea()

            // Subtle accent glow so the header feels alive.
            RadialGradient(
                colors: [settings.accentColor.opacity(0.22), Color.clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 520
            )
            .ignoresSafeArea()
            .blendMode(.screen)
            .opacity(image == nil ? 1 : 0.55)
        }
        .onAppear(perform: reloadIfNeeded)
        .onChange(of: settings.wallpaperVersion) { _ in reloadIfNeeded() }
    }

    private func reloadIfNeeded() {
        guard loadedVersion != settings.wallpaperVersion else { return }
        loadedVersion = settings.wallpaperVersion
        image = nil

        guard FileManager.default.fileExists(atPath: AppPaths.wallpaper.path) else { return }

        let url = AppPaths.wallpaper
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ThumbnailCache.downsample(url: url, maxPixel: 1600)
            DispatchQueue.main.async {
                image = loaded
            }
        }
    }
}
