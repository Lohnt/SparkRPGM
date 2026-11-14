import SwiftUI

struct ImportProgressView: View {

    @ObservedObject var coordinator: ImportCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(headerText)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.top, 6)

                        Text("Extraction streams straight to Documents/games, so you can keep browsing while it runs.")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(coordinator.jobs) { job in
                            jobRow(job)
                        }

                        if coordinator.jobs.isEmpty {
                            Text("No imports running.")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.top, 30)
                        }

                        Button(action: {
                            coordinator.dismissFinishedJobs()
                            dismiss()
                        }) {
                            Text(coordinator.jobs.contains(where: { !$0.isFinished }) ? "Run in Background" : "Done")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color(red: 0.49, green: 0.36, blue: 1.0))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .padding(.top, 8)
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var headerText: String {
        let active = coordinator.jobs.filter { !$0.isFinished }.count
        if active > 0 { return "Importing \(active) item\(active == 1 ? "" : "s")…" }
        return "Imports finished"
    }

    private func jobRow(_ job: ImportJob) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName(for: job))
                    .foregroundColor(color(for: job))
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.fileName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    Text(job.errorText ?? job.statusText)
                        .font(.system(size: 11))
                        .foregroundColor(job.isFailed ? Color(red: 1, green: 0.46, blue: 0.46) : .white.opacity(0.55))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                if !job.isFinished {
                    Button {
                        coordinator.cancel(jobID: job.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
            }

            if let fraction = job.fraction, !job.isFinished {
                ProgressView(value: max(0, min(1, fraction)))
                    .progressViewStyle(LinearProgressViewStyle(tint: Color(red: 0.49, green: 0.36, blue: 1.0)))
            } else if !job.isFinished {
                ProgressView()
                    .progressViewStyle(LinearProgressViewStyle(tint: Color(red: 0.49, green: 0.36, blue: 1.0)))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func iconName(for job: ImportJob) -> String {
        if job.isFailed { return "exclamationmark.triangle.fill" }
        if job.isFinished { return "checkmark.circle.fill" }
        return "shippingbox.fill"
    }

    private func color(for job: ImportJob) -> Color {
        if job.isFailed { return Color(red: 1, green: 0.46, blue: 0.46) }
        if job.isFinished { return Color(red: 0.24, green: 0.82, blue: 0.55) }
        return Color(red: 0.60, green: 0.53, blue: 1.0)
    }
}
