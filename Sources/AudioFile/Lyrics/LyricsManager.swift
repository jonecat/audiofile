import Foundation

public enum LyricsStatus: Equatable, Sendable {
    case idle
    case loading
    case found(SyncedLyrics)
    case instrumental
    case notFound
}

@MainActor
public final class LyricsManager: ObservableObject {
    public static let shared = LyricsManager()

    @Published public private(set) var status: LyricsStatus = .idle
    @Published public private(set) var currentWindow: LyricsWindow = LyricsWindow()

    public var syncedLyrics: SyncedLyrics? {
        if case .found(let synced) = status {
            return synced
        }
        return nil
    }

    private var currentTrackId: String?
    private var activeTask: Task<Void, Never>?

    public init() {}

    public func update(for track: Track?, elapsed: TimeInterval) {
        guard let track = track else {
            if status != .idle {
                status = .idle
                currentWindow = LyricsWindow()
                currentTrackId = nil
            }
            return
        }

        // Check if track changed
        if currentTrackId != track.id {
            currentTrackId = track.id
            requestLyrics(for: track)
        }

        // Update sliding window if lyrics found
        if case .found(let synced) = status {
            currentWindow = synced.window(at: elapsed)
        }
    }

    private func requestLyrics(for track: Track) {
        activeTask?.cancel()
        status = .loading
        currentWindow = LyricsWindow()

        activeTask = Task {
            let result = await LRCLIBClient.shared.fetchLyrics(for: track)
            guard !Task.isCancelled else { return }

            switch result {
            case .found(let content):
                if let synced = SyncedLyrics.parse(content: content, duration: track.duration) {
                    self.status = .found(synced)
                    self.currentWindow = synced.window(at: 0)
                } else {
                    self.status = .notFound
                }
            case .instrumental:
                self.status = .instrumental
            case .notFound:
                self.status = .notFound
            }
        }
    }

    public func reloadLyrics(for track: Track) {
        currentTrackId = nil
        requestLyrics(for: track)
    }
}
