import Foundation
import Combine

/// Accumulates foreground play time for one game and flushes it into
/// `MetadataStore` (which writes `Documents/.spark/metadata.json`).
///
/// The clock is started when the player becomes visible and paused whenever the
/// scene leaves `.active` or the player is dismissed, so background time is
/// never counted. A repeating timer flushes every 45s so a crash or a jet-lag
/// kill loses at most a minute.
final class PlaytimeTracker: ObservableObject {

    private let folder: String
    private let metadata: MetadataStore
    private let flushInterval: TimeInterval

    private var segmentStart: Date?
    private var timer: Timer?

    init(gameFolder: String, metadata: MetadataStore = .shared, flushInterval: TimeInterval = 45) {
        self.folder = gameFolder
        self.metadata = metadata
        self.flushInterval = flushInterval
    }

    /// Begins (or resumes) counting. No-op while already running.
    func start() {
        guard segmentStart == nil else { return }
        segmentStart = Date()
        scheduleTimer()
    }

    /// Stops counting and writes the pending seconds.
    func pause() {
        flush()
        segmentStart = nil
        timer?.invalidate()
        timer = nil
    }

    /// Writes everything counted since the last flush and keeps counting.
    func flush() {
        guard let start = segmentStart else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        segmentStart = now
        guard elapsed >= 0.5 else { return }

        metadata.update(folder) { value in
            value.playTimeSeconds = (value.playTimeSeconds ?? 0) + elapsed
            value.lastPlayedAt = now
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }
}
