import SwiftUI

/// One row of the `Spark Lines` library style.
///
/// Flat neutral surface, a 4pt accent bar and a single muted metadata line:
/// `MZ · 4.2 GB · 3h 20m · Played today`. No cover art is loaded, which keeps
/// scrolling cheap on older iPads.
struct SparkLineRowView: View {

    let game: Game
    let lineColor: Color

    var onOpen: () -> Void
    var onRename: () -> Void
    var onSetCover: () -> Void
    var onRemoveCover: () -> Void
    var onChangeLineColor: () -> Void
    var onBackup: () -> Void
    var onDelete: () -> Void

    private var metadataLine: String {
        var parts = [game.engine.rawValue, game.statsLine]
        if let hint = game.lastPlayedHint {
            parts.append(hint)
        }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(lineColor)
                .frame(width: 4)
                .padding(.vertical, 13)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SparkTheme.textPrimary)
                    .lineLimit(1)

                Text(metadataLine)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(SparkTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(SparkTheme.textTertiary)
        }
        .padding(.trailing, 15)
        .frame(minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SparkTheme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
