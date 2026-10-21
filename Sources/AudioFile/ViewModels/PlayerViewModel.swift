import Foundation
import SwiftUI
import Combine

public enum NavigationSection: Hashable, Sendable {
    case artists
    case albums
    case songs
    case health
    case visualizer
    case favorites
    case recentlyPlayed
    case playlist(String) // playlist ID
    case settings
}

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case library = "Library"
    case audio = "Audio"
    case visualizer = "Visualizer"
    case lyrics = "Lyrics"
    case about = "About"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .library: return "folder"
        case .audio: return "speaker.wave.2"
        case .visualizer: return "waveform.path"
        case .lyrics: return "quote.bubble"
        case .about: return "info.circle"
        }
    }
}

@MainActor
public final class PlayerViewModel: ObservableObject {
    public static let shared = PlayerViewModel()

    @Published public var selectedSection: NavigationSection = .artists
    @Published public var searchQuery: String = ""
    @Published public var isSearchPresented: Bool = false

    @Published public var queue: [Track] = []
    @Published public var currentQueueIndex: Int = -1
    @Published public var isLibraryShuffleActive: Bool = false
    @Published public var shuffle: Bool = false {
        didSet {
            config.shuffle = shuffle
            config.save()
            updateShuffleQueue()
        }
    }
    @Published public var repeatMode: RepeatMode = .off {
        didSet {
            config.repeatMode = repeatMode
            config.save()
        }
    }

    @Published public var showLyrics: Bool = true {
        didSet {
            config.showLyrics = showLyrics
            config.save()
        }
    }
    @Published public var showVisualizer: Bool = true {
        didSet {
            config.showVisualizer = showVisualizer
            config.save()
        }
    }
    @Published public var lyricsScale: Double = 1.0 {
        didSet {
            config.lyricsScale = lyricsScale
            config.save()
        }
    }

    // Navigation and UI state
    @Published public var showingSettings: Bool = false
    @Published public var selectedSettingsTab: SettingsTab = .library
    @Published public var showingAbout: Bool = false
    @Published public var showingNewPlaylistDialog: Bool = false
    @Published public var newPlaylistName: String = ""
    @Published public var playlistPendingDeletion: Playlist?
    @Published public var selectedArtist: String?
    @Published public var selectedAlbum: String?
    @Published public var selectedAlbumDetail: LibraryManager.AlbumInfo?
    @Published public var selectedTrackIds: Set<String> = []

    public var selectedTrackId: String? {
        get { selectedTrackIds.first }
        set {
            if let val = newValue {
                selectedTrackIds = [val]
            } else {
                selectedTrackIds.removeAll()
            }
        }
    }
    @Published public var sortOrder: [KeyPathComparator<Track>] = [
        .init(\.displayArtist, order: .forward)
    ]
    @Published public var showingCacheClearedAlert: Bool = false

    // Track Metadata Inspector & Editor state
    @Published public var inspectingTrack: Track?
    @Published public var inspectingArtworkTrack: Track?
    @Published public var metaTitle: String = ""
    @Published public var metaArtist: String = ""
    @Published public var metaAlbum: String = ""
    @Published public var metaAlbumArtist: String = ""
    @Published public var metaGenre: String = ""
    @Published public var metaTrackNumber: String = ""
    @Published public var metaDiscNumber: String = ""
    @Published public var metaYear: String = ""
    @Published public var metaSaveMode: HealthFixMode = .safeLibraryAndSidecar
    @Published public var isSavingTrackMetadata: Bool = false

    @Published public private(set) var filteredTracks: [Track] = []
    @Published public private(set) var sortedTracks: [Track] = []

    @Published public var currentWaveform: WaveformData?

    public let audio = AudioEngine.shared
    public let library = LibraryManager.shared
    public let health = LibraryHealthManager.shared
    public let playlists = PlaylistManager.shared
    public let lyrics = LyricsManager.shared
    public let visualizer = VisualizerState.shared
    public let updater = AppUpdater.shared
    public var config: AppConfig

    private var originalQueue: [Track] = []
    private var cancellables = Set<AnyCancellable>()

    public init() {
        self.config = AppConfig.load()
        self.repeatMode = config.repeatMode
        self.shuffle = false
        self.config.shuffle = false
        self.config.save()
        self.showLyrics = config.showLyrics
        self.showVisualizer = config.showVisualizer
        self.lyricsScale = config.lyricsScale
        self.audio.volume = config.volume

        VisualizerEngine.shared.setFPS(Double(config.visualizerFPS))
        VisualizerState.shared.start(fps: config.visualizerFPS)

        setupSubscriptions()
        updateFilteredAndSortedTracks()

        // Kick off incremental background library sync
        library.startSync(folders: config.libraryFolders, fullRescan: false)

        // Check GitHub Releases for a newer version on startup
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            AppUpdater.shared.checkForUpdates(userInitiated: false)
        }
    }

    private func setupSubscriptions() {
        // Forward audio track completion to nextTrack()
        audio.onTrackCompleted = { [weak self] in
            self?.handleTrackEnded()
        }
        audio.onPreviousTrackRequested = { [weak self] in
            self?.previousTrack()
        }

        // Library track changes -> update filtered/sorted tracks
        library.$tracks
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFilteredAndSortedTracks()
            }
            .store(in: &cancellables)

        // Search query updates -> debounced filter
        $searchQuery
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFilteredAndSortedTracks()
            }
            .store(in: &cancellables)

        // Sort order updates -> re-sort
        $sortOrder
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFilteredAndSortedTracks()
            }
            .store(in: &cancellables)

        // Forward playlist & favorite changes to PlayerViewModel observers
        playlists.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Keep lyrics synced with current playback position
        audio.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] time in
                guard let self = self else { return }
                self.lyrics.update(for: self.audio.currentTrack, elapsed: time)
            }
            .store(in: &cancellables)

        // Waveform loading when track changes
        audio.$currentTrack
            .receive(on: RunLoop.main)
            .sink { [weak self] track in
                guard let self = self else { return }
                if let t = track {
                    self.playlists.recordPlayed(trackId: t.id)
                    Task {
                        let wf = await WaveformEngine.shared.waveform(for: t)
                        await MainActor.run {
                            self.currentWaveform = wf
                        }
                    }
                } else {
                    self.currentWaveform = nil
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Visualizer Loop

    public func setVisualizerFPS(_ fps: Int) {
        config.visualizerFPS = fps
        config.save()
        VisualizerEngine.shared.setFPS(Double(fps))
        VisualizerState.shared.start(fps: fps)
    }

    // MARK: - Queue & Playback

    public func toggleLibraryShuffle() {
        if isLibraryShuffleActive {
            stopLibraryShuffle()
        } else {
            startLibraryShuffle()
        }
    }

    public func startLibraryShuffle() {
        let allTracks = library.tracks
        guard !allTracks.isEmpty else { return }

        isLibraryShuffleActive = true
        shuffle = true
        if repeatMode == .off {
            repeatMode = .all
        }

        var shuffled = allTracks
        shuffled.shuffle()
        originalQueue = allTracks
        queue = shuffled
        currentQueueIndex = 0
        selectedTrackId = shuffled[0].id

        audio.play(track: shuffled[0])
        preloadUpcoming()
    }

    public func stopLibraryShuffle() {
        isLibraryShuffleActive = false
        shuffle = false
        repeatMode = .off
        audio.stop()
    }

    public func syncQueueWithDisplayedTracks(_ trackList: [Track]) {
        guard !shuffle && !isLibraryShuffleActive,
              let currentId = audio.currentTrack?.id,
              let idx = trackList.firstIndex(where: { $0.id == currentId }) else {
            return
        }
        originalQueue = trackList
        queue = trackList
        currentQueueIndex = idx
        preloadUpcoming()
    }

    public func playTrack(_ track: Track, in trackList: [Track] = []) {
        if isLibraryShuffleActive {
            isLibraryShuffleActive = false
            shuffle = false
            repeatMode = .off
        }
        selectedTrackId = track.id
        if trackList.isEmpty {
            originalQueue = [track]
            queue = [track]
            currentQueueIndex = 0
        } else {
            originalQueue = trackList
            if shuffle {
                var shuffled = trackList.filter { $0.id != track.id }
                shuffled.shuffle()
                queue = [track] + shuffled
                currentQueueIndex = 0
            } else {
                queue = trackList
                currentQueueIndex = queue.firstIndex(where: { $0.id == track.id }) ?? 0
            }
        }

        audio.play(track: track)
        preloadUpcoming()
    }

    public func nextTrack() {
        guard !queue.isEmpty else { return }

        if repeatMode == .one, !isLibraryShuffleActive, let current = audio.currentTrack {
            audio.play(track: current)
            return
        }

        if !shuffle && !isLibraryShuffleActive {
            if !originalQueue.isEmpty {
                queue = originalQueue
            }
            if let currentId = audio.currentTrack?.id,
               let actualIndex = queue.firstIndex(where: { $0.id == currentId }) {
                currentQueueIndex = actualIndex
            }
        }

        if isLibraryShuffleActive && currentQueueIndex + 1 >= queue.count {
            appendReshuffledLibraryPass()
        }

        let nextIndex = currentQueueIndex + 1
        if nextIndex < queue.count {
            currentQueueIndex = nextIndex
            let next = queue[nextIndex]
            selectedTrackId = next.id
            audio.play(track: next)
            preloadUpcoming()
        } else if repeatMode == .all {
            currentQueueIndex = 0
            let first = queue[0]
            selectedTrackId = first.id
            audio.play(track: first)
            preloadUpcoming()
        } else {
            isLibraryShuffleActive = false
            audio.stop()
        }
    }

    public func previousTrack() {
        guard !queue.isEmpty else { return }

        // If played more than 3 seconds, restart current track
        if audio.currentTime > 3.0 {
            audio.seek(to: 0)
            return
        }

        if !shuffle && !isLibraryShuffleActive {
            if !originalQueue.isEmpty {
                queue = originalQueue
            }
            if let currentId = audio.currentTrack?.id,
               let actualIndex = queue.firstIndex(where: { $0.id == currentId }) {
                currentQueueIndex = actualIndex
            }
        }

        let prevIndex = currentQueueIndex - 1
        if prevIndex >= 0 {
            currentQueueIndex = prevIndex
            let prev = queue[prevIndex]
            selectedTrackId = prev.id
            audio.play(track: prev)
            preloadUpcoming()
        } else if repeatMode == .all || isLibraryShuffleActive {
            currentQueueIndex = queue.count - 1
            let last = queue[currentQueueIndex]
            selectedTrackId = last.id
            audio.play(track: last)
            preloadUpcoming()
        } else {
            audio.seek(to: 0)
        }
    }

    private func handleTrackEnded() {
        nextTrack()
    }

    private func appendReshuffledLibraryPass() {
        let source = library.tracks.isEmpty ? originalQueue : library.tracks
        guard !source.isEmpty else { return }
        var nextPass = source
        nextPass.shuffle()
        if nextPass.count > 1, let lastId = queue.last?.id, nextPass.first?.id == lastId {
            nextPass.swapAt(0, 1)
        }
        queue.append(contentsOf: nextPass)
    }

    private func preloadUpcoming() {
        if isLibraryShuffleActive && currentQueueIndex + 1 >= queue.count {
            appendReshuffledLibraryPass()
        }
        let upcomingIndex = currentQueueIndex + 1
        if upcomingIndex < queue.count {
            let next = queue[upcomingIndex]
            audio.preloadNextTrack(next)
        } else if repeatMode == .all, let first = queue.first {
            audio.preloadNextTrack(first)
        }
    }

    private func updateShuffleQueue() {
        guard let current = audio.currentTrack else { return }
        if shuffle {
            var remaining = originalQueue.filter { $0.id != current.id }
            remaining.shuffle()
            queue = [current] + remaining
            currentQueueIndex = 0
        } else {
            queue = originalQueue
            currentQueueIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
    }

    public func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    public func toggleShuffle() {
        shuffle.toggle()
    }

    public func toggleLyrics() {
        showLyrics.toggle()
    }

    public func toggleVisualizer() {
        showVisualizer.toggle()
    }

    public func toggleFavorite(track: Track) {
        playlists.toggleFavorite(trackId: track.id)
    }

    public func toggleFavorite(trackId: String) {
        playlists.toggleFavorite(trackId: trackId)
    }

    public func toggleFavorite(trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        let allFavs = trackIds.allSatisfy { playlists.isFavorite(trackId: $0) }
        if allFavs {
            playlists.removeFavorites(trackIds: trackIds)
        } else {
            playlists.addFavorites(trackIds: trackIds)
        }
    }

    public func addTracksToPlaylist(trackIds: [String], playlistId: String) {
        playlists.addTracks(to: playlistId, trackIds: trackIds)
    }

    public func toggleFavoriteSelectedOrCurrentTrack() {
        if !selectedTrackIds.isEmpty {
            toggleFavorite(trackIds: Array(selectedTrackIds))
        } else if let track = audio.currentTrack {
            playlists.toggleFavorite(trackId: track.id)
        }
    }

    public var isCurrentTrackFavorite: Bool {
        guard let track = audio.currentTrack else { return false }
        return playlists.isFavorite(trackId: track.id)
    }

    // MARK: - Track Metadata Inspector & Editor

    public func beginInspectingMetadata(for track: Track) {
        let current = library.tracks.first(where: { $0.id == track.id }) ?? track
        metaTitle = current.displayTitle
        metaArtist = current.artist == "Unknown Artist" ? "" : current.displayArtist
        metaAlbum = current.album == "Unknown Album" ? "" : current.displayAlbum
        metaAlbumArtist = current.albumArtist ?? current.displayAlbumArtist
        metaGenre = current.genre ?? ""
        metaTrackNumber = current.trackNumber.map { String($0) } ?? ""
        metaDiscNumber = current.discNumber.map { String($0) } ?? ""
        metaYear = current.year.map { String($0) } ?? ""
        metaSaveMode = health.fixMode
        isSavingTrackMetadata = false
        inspectingTrack = current
    }

    public func saveInspectedTrackMetadata() {
        guard let track = inspectingTrack else { return }
        isSavingTrackMetadata = true

        let override = TrackMetadataOverride(
            title: metaTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: metaArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: metaAlbum.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtist: metaAlbumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            trackNumber: Int(metaTrackNumber.trimmingCharacters(in: .whitespaces)),
            discNumber: Int(metaDiscNumber.trimmingCharacters(in: .whitespaces)),
            year: Int(metaYear.trimmingCharacters(in: .whitespaces)),
            genre: metaGenre.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        Task { @MainActor in
            await health.saveSingleTrackMetadata(
                track: track,
                override: override,
                mode: metaSaveMode
            )
            if let updated = library.tracks.first(where: { $0.id == track.id }) {
                for i in queue.indices where queue[i].id == track.id {
                    queue[i] = updated
                }
                for i in originalQueue.indices where originalQueue[i].id == track.id {
                    originalQueue[i] = updated
                }
                if selectedAlbumDetail != nil {
                    selectedAlbumDetail = library.allAlbums.first(where: {
                        $0.title == updated.displayAlbum && $0.artist == updated.displayAlbumArtist
                    }) ?? selectedAlbumDetail
                }
                if let currentArtist = selectedArtist, !library.uniqueArtists.contains(currentArtist) {
                    selectedArtist = updated.displayArtist
                }
            }
            isSavingTrackMetadata = false
            inspectingTrack = nil
        }
    }

    // MARK: - Search Filtering & Sorting
 
    public func updateFilteredAndSortedTracks() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [Track]
        if trimmed.isEmpty {
            filtered = library.tracks
        } else {
            filtered = library.tracks.filter { $0.matches(query: trimmed) }
        }
        self.filteredTracks = filtered
        self.sortedTracks = filtered.sorted(using: sortOrder)
    }
}
