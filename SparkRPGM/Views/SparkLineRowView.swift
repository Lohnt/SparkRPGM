import SwiftUI

/// One row of the `Spark Lines` library style: a 4pt coloured accent bar,
/// title, engine badge, disk size and play time. No cover art is loaded, which
/// keeps scrolling cheap on older iPads.
struct SparkLineRowView: View {

    let game: Game
    let lineColor: Color
    let glassOpacity: Double

    var onOpen: () -> Void
    var onRename: () -> Void
    var onSetCover: () -> Void
    var onRemoveCover: () -> Void
    var onChangeLineColor: () -> Void
    var onBackup: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [lineColor, lineColor.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 4)
                .padding(.vertical, 11)
                .shadow(color: lineColor.opacity(0.55), radius: 4, x: 0, y: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 7) {
                    EngineBadge(engine: game.engine, compact: true)

                    Text(game.statsLine)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 0)
                }

                if let hint = game.lastPlayedHint {
                    Text(hint)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.38))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(lineColor.opacity(0.9))
        }
        .padding(.trailing, 14)
        .frame(minHeight: 68)
        .background(
            ZStack {
                BlurView(style: .systemUltraThinMaterialDark)
                Color.black.opacity(max(0.10, glassOpacity * 0.55))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
