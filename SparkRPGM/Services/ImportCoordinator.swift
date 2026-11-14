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
///
/// Each queued `PickedDocument` keeps its security scope alive until the job
/// finishes, so the archive can be streamed straight off the provider's storage
/// instead of being copied into `tmp` first.
final class ImportCoordinator: ObservableObject {

    @Published private(set) var jobs: [ImportJob] = []
    @Published private(set) var isShowingProgress = false

    /// Bound to the library's `.alert`. Errors are never silent.
    @Published var failureMessage: String?

    private let store: GameStore
    private let importer: ArchiveImporter

    private var queue: [PickedDocument] = []
    private var isProcessing = false
    private var cancellationTokens: [UUID: ImportCancellationToken] = [:]
    private var activeURLs = Set<String>()

    init(store: GameStore) {
        self.store = store
        self.importer = ArchiveImporter(metadata: store.metadata)
    }

    // MARK: - Public API

    func enqueue(urls: [URL]) {
        enqueue(documents: urls.map(PickedDocument.init(url:)))
    }

    func enqueue(documents: [PickedDocument]) {
        guard !documents.isEmpty else { return }

        var added = false
        for document in documents {
            let path = document.originalURL.standardizedFileURL.path
            guard !activeURLs.contains(path) else { continue }
            activeURLs.insert(path)
            queue.append(document)
            added = true
        }
        guard added else {
            let name = documents.first?.fileName ?? "That file"
            store.toast("\(name) is already importing")
            return
        }

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

    func clearFailure() {
        failureMessage = nil
    }

    func dismissFinishedJobs() {
        let finished = jobs.filter { $0.isFinished || $0.isFailed }
        for job in finished {
            cancellationTokens.removeValue(forKey: job.id)
        }
        jobs.removeAll { $0.isFinished || $0.isFailed }
        if jobs.isEmpty, queue.isEmpty, !isProcessing {
            isShowingProgress = false
        }
    }

    /// The job the banner should describe right now.
    var activeJob: ImportJob? {
        jobs.first(where: { !$0.isFinished }) ?? jobs.last
    }

    var activeCount: Int {
        jobs.filter { !$0.isFinished }.count
    }

    // MARK: - Processing

    private func processNext() {
        guard !isProcessing else { return }
        guard !queue.isEmpty else {
            isProcessing = false
            finishIfIdle()
            return
        }

        isProcessing = true
        let document = queue.removeFirst()
        let queuedPath = document.originalURL.standardizedFileURL.path
        let fileName = document.fileName
        let jobID = UUID()
        let token = ImportCancellationToken()
        cancellationTokens[jobID] = token

        let job = ImportJob(
            id: jobID,
            fileName: fileName,
            statusText: "Selected \(fileName)…",
            fraction: 0
        )
        jobs.append(job)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // `document` is captured for the duration of the extraction, so the
            // security scope claimed by the picker never drops mid-job.
            let result: Result<ImportResult, Error>
            do {
                // Resolves provider-hosted files into a readable local URL
                // before the extractor touches them.
                let readableURL = try document.prepare()
                let imported = try self.importer.importItem(at: readableURL, token: token) { fraction, status in
                    DispatchQueue.main.async {
                        self.update(jobID: jobID) { job in
                            job.fraction = fraction
                            job.statusText = status
                        }
                    }
                }
                result = .success(imported)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.activeURLs.remove(queuedPath)
                self.cancellationTokens.removeValue(forKey: jobID)

                switch result {
                case .success(let imported):
                    self.update(jobID: jobID) { job in
                        job.fraction = 1
                        job.statusText = "Imported \(imported.title)"
                        job.isFinished = true
                    }
                    self.store.toast("Imported \(imported.title)")
                    // Refresh immediately. GameStore coalesces a scan that was
                    // already running into a follow-up pass.
                    self.store.scan()

                case .failure(let error):
                    let message = error.localizedDescription
                    self.update(jobID: jobID) { job in
                        job.fraction = nil
                        job.statusText = "Import failed"
                        job.errorText = message
                        job.isFinished = true
                    }
                    self.failureMessage = message
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

    /// Leaves the banner visible for a moment after the last job, then clears
    /// the finished rows so the next import starts on a clean slate.
    private func finishIfIdle() {
        guard jobs.allSatisfy({ $0.isFinished || $0.isFailed }) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self = self else { return }
            guard !self.isProcessing, self.queue.isEmpty else { return }
            self.isShowingProgress = false
            self.jobs.removeAll { $0.isFinished }
        }
    }
}
