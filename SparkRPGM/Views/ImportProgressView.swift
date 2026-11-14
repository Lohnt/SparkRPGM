import SwiftUI

/// Centred modal shown while an archive is importing.
///
/// Deliberately narrow (320pt) and quiet: title, archive name, phase, a
/// determinate bar with a live percentage, the extracted file counter and one
/// Cancel button.
struct ImportProgressCard: View {

    let job: ImportJob
    let activeCount: Int
    let accent: Color
    let onCancel: () -> Void

    private var isActive: Bool {
        !job.isFinished && !job.isFailed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                statusIcon

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SparkTheme.textPrimary)

                Spacer(minLength: 6)

                if isActive {
                    Text("\(Int((job.progressValue * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(SparkTheme.textSecondary)
                }
            }

            Text(job.fileName)
                .font(.system(size: 11))
                .foregroundColor(SparkTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            progressBar

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(phaseText)
                    .font(.system(size: 10.5))
                    .foregroundColor(SparkTheme.textTertiary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let counter = job.counterText, isActive {
                    Text(counter)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(SparkTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            if let error = job.errorText, !isActive {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if activeCount > 1 {
                    Text("+\(activeCount - 1) queued")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(SparkTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        )
                }

                Spacer(minLength: 0)

                if isActive {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(SparkTheme.textPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
                            )
                    }
                }
            }
            .padding(.top, 1)
        }
        .padding(18)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "#141418").opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 26, x: 0, y: 14)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))

                Capsule(style: .continuous)
                    .fill(isActive ? accent : Color.white.opacity(0.28))
                    .frame(width: max(0, geo.size.width * CGFloat(job.progressValue)))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.22), value: job.progressValue)
    }

    private var title: String {
        if job.isFailed { return "Import failed" }
        if job.isFinished { return "Import complete" }
        return "Importing Game"
    }

    private var phaseText: String {
        if job.isFailed { return job.statusText }
        if job.isFinished { return "Ready to play" }
        return job.phase.title
    }

    @ViewBuilder
    private var statusIcon: some View {
        if job.isFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.42))
        } else if job.isFinished {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(Color(red: 0.35, green: 0.78, blue: 0.58))
        } else {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: SparkTheme.textSecondary))
                .scaleEffect(0.65)
                .frame(width: 14, height: 14)
        }
    }
}
