import SwiftUI

/// Non-blocking banner shown at the bottom of the library while an import runs.
struct ImportBanner: View {

    let job: ImportJob
    let activeCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            statusIcon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SparkTheme.textPrimary)

                    if activeCount > 1 {
                        Text("+\(activeCount - 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(SparkTheme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                }

                Text(job.errorText ?? job.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(job.isFailed ? Color(red: 0.95, green: 0.45, blue: 0.42) : SparkTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let fraction = job.fraction, !job.isFinished {
                    ProgressView(value: max(0, min(1, fraction)))
                        .progressViewStyle(LinearProgressViewStyle(tint: SparkTheme.textSecondary))
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .sparkPanel(cornerRadius: 11, fill: SparkTheme.panelRaised, borderOpacity: 0.10)
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
    }

    private var title: String {
        if job.isFailed { return "Import failed" }
        if job.isFinished { return "Import complete" }
        return "Importing"
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
                .scaleEffect(0.7)
        }
    }
}
