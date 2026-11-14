import SwiftUI

struct EngineBadge: View {

    let engine: GameEngine
    var compact: Bool = false

    var body: some View {
        Text(engine.rawValue)
            .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .default))
            .foregroundColor(SparkTheme.textSecondary)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
    }
}

struct CoverImageView: View {

    let game: Game
    var maxPixel: CGFloat = 900

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .onAppear(perform: load)
        .onChange(of: game.coverURL) { _ in
            image = nil
            load()
        }
    }

    private var fallback: some View {
        ZStack {
            SparkSurfaceBackground(cornerRadius: 0, fill: SparkTheme.panelRaised)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.clear,
                    Color.black.opacity(0.35),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 46, height: 46)
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        .frame(width: 46, height: 46)
                    Text(monogram)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundColor(SparkTheme.textSecondary)
                }

                Text(game.engine.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundColor(SparkTheme.textTertiary)
            }
        }
    }

    private var monogram: String {
        let cleaned = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let character = cleaned.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(character).uppercased()
    }

    private func load() {
        guard let url = game.coverURL else { return }
        if let cached = ThumbnailCache.shared.cachedImage(for: url, maxPixel: maxPixel) {
            image = cached
            return
        }
        ThumbnailCache.shared.image(for: url, maxPixel: maxPixel) { loaded in
            guard let loaded = loaded else { return }
            image = loaded
        }
    }
}

struct GameCardView: View {

    let game: Game
    let cardSize: CardSize
    let lineColor: Color

    var onOpen: () -> Void
    var onRename: () -> Void
    var onSetCover: () -> Void
    var onRemoveCover: () -> Void
    var onChangeLineColor: () -> Void
    var onBackup: () -> Void
    var onDelete: () -> Void

    private var cornerRadius: CGFloat {
        cardSize == .compact ? 10 : 12
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImageView(game: game, maxPixel: cardSize == .large ? 1200 : 800)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.30),
                    Color.black.opacity(0.88),
                ],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.system(size: cardSize == .compact ? 12 : 14, weight: .semibold))
                    .foregroundColor(SparkTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                HStack(spacing: 6) {
                    EngineBadge(engine: game.engine, compact: cardSize == .compact)
                    if cardSize != .compact {
                        Text(game.statsLine)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(.white.opacity(0.62))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                }

                if cardSize == .compact {
                    Text(game.statsLine)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }

                if let hint = game.lastPlayedHint {
                    Text(hint)
                        .font(.system(size: cardSize == .compact ? 8.5 : 9.5, weight: .regular))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(cardSize == .compact ? 9 : 12)
        }
        .aspectRatio(cardSize.coverAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .sparkBorder(cornerRadius: cornerRadius)
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(lineColor)
                .frame(width: 26, height: 3)
                .padding(.leading, cardSize == .compact ? 10 : 12)
                .padding(.top, cardSize == .compact ? 10 : 12)
        }
        .shadow(color: Color.black.opacity(0.30), radius: 10, x: 0, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(action: onOpen) {
                Label("Play", systemImage: "play.fill")
            }
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Button(action: onSetCover) {
                Label("Set Custom Cover", systemImage: "photo")
            }
            if game.hasCustomCover {
                Button(action: onRemoveCover) {
                    Label("Remove Custom Cover", systemImage: "photo.badge.arrow.down")
                }
            }
            Button(action: onChangeLineColor) {
                Label("Change Line Color", systemImage: "paintpalette")
            }
            Button(action: onBackup) {
                Label("Backup Saves", systemImage: "externaldrive.badge.timemachine")
            }
            Divider()
            Button(action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
