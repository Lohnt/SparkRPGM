import Foundation
import UIKit

struct ImportJob: Identifiable, Equatable {
    let id: UUID
    let fileName: String
    var statusText: String
    var fraction: Double?
    var phase: ImportPhase = .scanning
    var completedFiles: Int = 0
    var totalFiles: Int = 0
    var isFinished: Bool = false
    var errorText: String?

    var isFailed: Bool { errorText != nil }

    /// 0...1 value used by the determinate bar. Falls back to the entry counter
    /// when the extractor cannot compute a byte fraction.
    var progressValue: Double {
        if let fraction = fraction {
            return max(0, min(1, fraction))
        }
        if totalFiles > 0 {
            return max(0, min(1, Double(completedFiles) / Double(totalFiles)))
        }
        return 0
    }

    /// `840 / 2,150 files`, or nil while the entry count is unknown.
    var counterText: String? {
        guard totalFiles > 0 else { return nil }
        return "\(completedFiles.formatted()) / \(totalFiles.formatted()) files"
    }
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
    private var lastDeliveryTimes: [UUID: CFAbsoluteTime] = [:]

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
            statusText: "Selected \(fileName)",
            fraction: 0,
            phase: .scanning
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
                let imported = try self.importer.importItem(at: readableURL, token: token) { update in
                    self.deliver(update, jobID: jobID)
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
                        job.phase = .finishing
                        job.statusText = "Imported \(imported.title)"
                        job.isFinished = true
                    }
                    self.store.toast("Imported \(imported.title)")
                    // Refresh immediately. GameStore coalesces a scan that was
                    // already running into a follow-up pass.
                    self.store.scan()

                case .failure(let error):
                    let cancelled: Bool
                    if let archiveError = error as? ArchiveError, case .cancelled = archiveError {
                        cancelled = true
                    } else {
                        cancelled = false
                    }
                    let message = cancelled ? "Import cancelled." : error.localizedDescription
                    self.update(jobID: jobID) { job in
                        job.fraction = nil
                        job.statusText = cancelled ? "Import cancelled" : "Import failed"
                        job.errorText = message
                        job.isFinished = true
                    }
                    if !cancelled {
                        self.failureMessage = message
                    }
                }

                self.isProcessing = false
                self.processNext()
            }
        }
    }

    /// Hops to the main actor for progress updates, throttled to at most ~10 Hz
    /// (plus guaranteed delivery for completion/terminal stages) so SwiftUI does
    /// not re-render thousands of times during extraction.
    private func deliver(_ update: ArchiveExtractor.Progress, jobID: UUID) {
        let isFinal = update.phase == .imported || update.fraction == 1.0 || (update.completedFiles != nil && update.completedFiles == update.totalFiles)
        let now = CFAbsoluteTimeGetCurrent()
        let last = lastDeliveryTimes[jobID] ?? 0
        if !isFinal && (now - last < 0.1) {
            return
        }
        lastDeliveryTimes[jobID] = now

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.update(jobID: jobID) { job in
                // A progress callback can land after the completion hop; never
                // let it overwrite the final "Imported" state.
                guard !job.isFinished else { return }
                job.fraction = update.fraction
                job.statusText = update.status
                job.phase = update.phase
                job.completedFiles = update.completedFiles
                job.totalFiles = update.totalFiles
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
            self.lastDeliveryTimes.removeAll()
        }
    }
}
