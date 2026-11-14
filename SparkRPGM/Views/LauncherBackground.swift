import SwiftUI

/// Full-screen launcher backdrop.
///
/// Three layers, all optional:
/// 1. A matte charcoal canvas.
/// 2. The player's wallpaper, blurred and dimmed by the saved amount.
/// 3. When there is no wallpaper, the most recently played game's cover art
///    bled into the top of the screen and faded into the canvas.
struct LauncherBackground: View {

    @ObservedObject var launcher: LauncherSettingsStore
    var coverURL: URL?

    @State private var wallpaperImage: UIImage?
    @State private var coverImage: UIImage?
    @State private var loadedWallpaperRevision = -1
    @State private var loadedCoverURL: URL?

    private var settings: LauncherSettings { launcher.settings }

    var body: some View {
        ZStack(alignment: .top) {
            SparkTheme.canvas.ignoresSafeArea()

            if let wallpaperImage = wallpaperImage {
                Image(uiImage: wallpaperImage)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: CGFloat(max(0, settings.wallpaperBlur)))
                    .ignoresSafeArea()

                Color.black.opacity(settings.dimOpacity).ignoresSafeArea()
            } else if settings.ambientCoverEnabled, let coverImage = coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 460)
                    .frame(maxWidth: .infinity)
                    .blur(radius: 54)
                    .opacity(settings.ambientCoverIntensity)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black.opacity(0.55), location: 0.45),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipped()
                    .ignoresSafeArea(edges: .top)

                LinearGradient(
                    colors: [Color.clear, SparkTheme.canvas.opacity(0.35), SparkTheme.canvas],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
        .onAppear {
            reloadWallpaperIfNeeded()
            loadCoverIfNeeded()
        }
        .onChange(of: launcher.wallpaperRevision) { _ in reloadWallpaperIfNeeded() }
        .onChange(of: settings.wallpaperVersion) { _ in reloadWallpaperIfNeeded() }
        .onChange(of: coverURL?.absoluteString) { _ in loadCoverIfNeeded() }
    }

    private func reloadWallpaperIfNeeded() {
        guard loadedWallpaperRevision != launcher.wallpaperRevision else { return }
        loadedWallpaperRevision = launcher.wallpaperRevision
        wallpaperImage = nil

        guard FileManager.default.fileExists(atPath: AppPaths.wallpaper.path) else { return }

        let url = AppPaths.wallpaper
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = autoreleasepool {
                ThumbnailCache.downsample(url: url, maxPixel: 1800)
            }
            DispatchQueue.main.async {
                wallpaperImage = loaded
            }
        }
    }

    private func loadCoverIfNeeded() {
        guard settings.ambientCoverEnabled, let url = coverURL else {
            coverImage = nil
            loadedCoverURL = nil
            return
        }
        guard loadedCoverURL != url else { return }
        loadedCoverURL = url
        coverImage = nil

        ThumbnailCache.shared.image(for: url, maxPixel: 900) { image in
            coverImage = image
        }
    }
}
