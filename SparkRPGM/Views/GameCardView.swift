import SwiftUI

struct EngineBadge: View {

    let engine: GameEngine
    var compact: Bool = false

    var body: some View {
        Text(engine.rawValue)
            .font(.system(size: compact ? 9 : 10, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 4)
            .background(
                Capsule()
                    .fill(engine.badgeColor.opacity(0.92))
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
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
            LinearGradient(
                colors: [game.engine.badgeColor.opacity(0.55), Color.black.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.white.opacity(0.55))
                Text(game.engine.rawValue)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }

    private func load() {
        guard let url = game.coverURL else { return }
        if let cached = ThumbnailCache.shared.cachedImage(for: url, maxPixel: maxPixel) {
            image = cached
            return
        }
        ThumbnailCache.shared.image(for: url, maxPixel: maxPixel) { loaded in
            guard let loaded = loaded else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                image = loaded
            }
        }
    }
}

struct GameCardView: View {

    let game: Game
    let cardSize: CardSize
    let glassOpacity: Double
    let accent: Color
    let lineColor: Color

    var onOpen: () -> Void
    var onRename: () -> Void
    var onSetCover: () -> Void
    var onRemoveCover: () -> Void
    var onChangeLineColor: () -> Void
    var onBackup: () -> Void
    var onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImageView(game: game, maxPixel: cardSize == .large ? 1200 : 800)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.35), Color.black.opacity(0.92)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(game.title)
                    .font(.system(size: cardSize == .compact ? 12 : 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                HStack(spacing: 6) {
                    EngineBadge(engine: game.engine, compact: cardSize == .compact)
                    if cardSize != .compact {
                        Text(game.statsLine)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                }

                if cardSize == .compact {
                    Text(game.statsLine)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .padding(cardSize == .compact ? 9 : 12)
        }
        .aspectRatio(cardSize.coverAspect, contentMode: .fit)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: cardSize == .compact ? 14 : 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardSize == .compact ? 14 : 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [lineColor.opacity(0.55), accent.opacity(0.18), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .topLeading) {
            Capsule()
                .fill(lineColor)
                .frame(width: 26, height: 3)
                .padding(.leading, cardSize == .compact ? 10 : 12)
                .padding(.top, cardSize == .compact ? 10 : 12)
                .shadow(color: lineColor.opacity(0.8), radius: 4, x: 0, y: 0)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
