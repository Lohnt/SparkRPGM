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
            } else if (settings.ambientCoverEnabled || settings.liquidGlassEnabled), let coverImage = coverImage {
                let isGlass = settings.liquidGlassEnabled
                let glassIntensity = max(0.2, settings.liquidGlassIntensity)

                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        minWidth: 0,
                        maxWidth: .infinity,
                        minHeight: 0,
                        maxHeight: isGlass ? .infinity : 460
                    )
                    .clipped()
                    .blur(radius: isGlass ? 40 : 54)
                    .opacity(isGlass ? min(1.0, max(0.72, settings.ambientCoverIntensity * 1.4) * glassIntensity) : settings.ambientCoverIntensity)
                    .mask(
                        LinearGradient(
                            stops: isGlass ? [
                                .init(color: .black, location: 0.0),
                                .init(color: .black.opacity(0.85), location: 0.35),
                                .init(color: .black.opacity(0.50), location: 0.70),
                                .init(color: .black.opacity(0.25), location: 1.0),
                            ] : [
                                .init(color: .black, location: 0.0),
                                .init(color: .black.opacity(0.55), location: 0.45),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipped()
                    .ignoresSafeArea()

                if isGlass {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.12),
                            Color.black.opacity(0.28),
                            SparkTheme.canvas.opacity(0.60),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [Color.clear, SparkTheme.canvas.opacity(0.35), SparkTheme.canvas],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
            } else if settings.liquidGlassEnabled {
                // Subtle ambient glow when no cover art is present, ensuring
                // glass panels always have chromatic depth to refract.
                RadialGradient(
                    gradient: Gradient(colors: [
                        settings.accentColor.opacity(0.22 * settings.liquidGlassIntensity),
                        Color(hex: "#1A1A24").opacity(0.35),
                        Color.clear,
                    ]),
                    center: .topLeading,
                    startRadius: 40,
                    endRadius: 600
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
        .onChange(of: settings.liquidGlassEnabled) { _ in loadCoverIfNeeded() }
        .onChange(of: coverURL) { _ in loadCoverIfNeeded() }
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
        guard settings.ambientCoverEnabled || settings.liquidGlassEnabled, let url = coverURL else {
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
