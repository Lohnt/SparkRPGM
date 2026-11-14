import Foundation
import UIKit

struct ImportJob: Identifiable, Equatable {
    let id: UUID
    let fileName: String
    var statusText: String
    var fraction: Double?
    var isFinished: Bool = false
    var errorText: String?

    var isFailed: Bool { errorText != nil }
}

/// Serialises archive imports and publishes their progress to the UI.
final class ImportCoordinator: ObservableObject {

    @Published private(set) var jobs: [ImportJob] = []
    @Published var isPresentingPicker = false
    @Published var isShowingProgress = false
    @Published var errorBanner: String?

    private let store: GameStore
    private let importer: ArchiveImporter
    private var queue: [URL] = []
    private var isProcessing = false
    private var cancellationTokens: [UUID: ImportCancellationToken] = [:]
    private var activeURLs = Set<String>()

    init(store: GameStore) {
        self.store = store
        self.importer = ArchiveImporter(metadata: store.metadata)
    }

    // MARK: - Public API

    func enqueue(urls: [URL]) {
        guard !urls.isEmpty else { return }
        var added = false
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !activeURLs.contains(path) else { continue }
            activeURLs.insert(path)
            queue.append(url)
            added = true
        }
        guard added else { return }
        isShowingProgress = true
        processNext()
    }

    func drainInbox() {
        let urls = ImportInbox.shared.drain()
        if !urls.isEmpty {
            enqueue(urls: urls)
        }
    }

    func cancel(jobID: UUID) {
        cancellationTokens[jobID]?.cancel()
        if let index = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[index].statusText = "Cancelling…"
        }
    }

    func dismissFinishedJobs() {
        let removed = jobs.filter { $0.isFinished || $0.isFailed }
        for job in removed {
            cancellationTokens.removeValue(forKey: job.id)
        }
        jobs.removeAll { $0.isFinished || $0.isFailed }
        if jobs.isEmpty {
            isShowingProgress = false
        }
    }

    func clearError() {
        errorBanner = nil
    }

    // MARK: - Processing

    private func processNext() {
        guard !isProcessing else { return }
        guard !queue.isEmpty else {
            isProcessing = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                if self.jobs.allSatisfy({ $0.isFinished || $0.isFailed }) {
                    self.isShowingProgress = self.jobs.contains(where: { $0.isFailed })
                }
            }
            return
        }

        isProcessing = true
        let url = queue.removeFirst()
        let jobID = UUID()
        let token = ImportCancellationToken()
        cancellationTokens[jobID] = token

        let job = ImportJob(
            id: jobID,
            fileName: url.lastPathComponent,
            statusText: "Preparing…",
            fraction: 0
        )
        jobs.append(job)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Hold the security scope for the entire extraction.
            let scope = SecurityScopedResource(url)
            defer { _ = scope }

            let result: Result<ImportResult, Error>
            do {
                let imported = try self?.importer.importItem(at: url, token: token) { fraction, status in
                    DispatchQueue.main.async {
                        self?.update(jobID: jobID) { job in
                            job.fraction = fraction
                            job.statusText = status
                        }
                    }
                }
                if let imported = imported {
                    result = .success(imported)
                } else {
                    result = .failure(ArchiveError.cancelled)
                }
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.activeURLs.remove(url.standardizedFileURL.path)
                self.cancellationTokens.removeValue(forKey: jobID)

                switch result {
                case .success(let imported):
                    self.update(jobID: jobID) { job in
                        job.fraction = 1
                        job.statusText = "Ready — \(imported.engine.displayName)"
                        job.isFinished = true
                    }
                    self.store.toast("Imported \(imported.title)")
                    self.store.scan()

                case .failure(let error):
                    let message = error.localizedDescription
                    self.update(jobID: jobID) { job in
                        job.fraction = nil
                        job.statusText = "Import failed"
                        job.errorText = message
                        job.isFinished = true
                    }
                    self.errorBanner = message
                }

                self.isProcessing = false
                self.processNext()
            }
        }
    }

    private func update(jobID: UUID, mutate: (inout ImportJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        var job = jobs[index]
        mutate(&job)
        jobs[index] = job
    }

    // MARK: - Presentation helpers

    func presentPicker() {
        isPresentingPicker = true
    }

    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        let finished = jobs.filter { $0.isFinished && !$0.isFailed }.count
        return Double(finished) / Double(jobs.count)
    }
}
