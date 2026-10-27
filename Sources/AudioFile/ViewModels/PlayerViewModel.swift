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
    @Published public var visualizerMode: VisualizerMode = .bars {
        didSet {
            config.visualizerMode = visualizerMode
            config.save()
            visualizer.setMode(visualizerMode)
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
    @Published public var currentDynamicRange: DynamicRangeState = .idle
    private var dynamicRangeTask: Task<Void, Never>?
    @Published public var currentToast: ToastMessage?
    private var toastDismissTask: Task<Void, Never>?

    // Resizable Columns state
    @Published public var artistsColumnWidth: CGFloat = 220
    @Published public var albumsColumnWidth: CGFloat = 250

    public let audio = AudioEngine.shared
    public let library = LibraryManager.shared
    public let health = LibraryHealthManager.shared
    public let playlists = PlaylistManager.shared
    public let lyrics = LyricsManager.shared
    public let visualizer = VisualizerState.shared
    public let updater = AppUpdater.shared
    @Published public var config: AppConfig

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
        self.visualizerMode = config.visualizerMode
        self.visualizer.setMode(config.visualizerMode)
        self.lyricsScale = config.lyricsScale
        self.audio.volume = config.volume
        self.artistsColumnWidth = CGFloat(config.artistsColumnWidth)
        self.albumsColumnWidth = CGFloat(config.albumsColumnWidth)

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

        // Waveform & Dynamic Range loading when track changes
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
                    self.calculateDynamicRange(for: t)
                } else {
                    self.currentWaveform = nil
                    self.currentDynamicRange = .idle
                    self.dynamicRangeTask?.cancel()
                    self.dynamicRangeTask = nil
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - On-Demand Dynamic Range Measurement

    public func calculateDynamicRange(for track: Track, forceRecalculate: Bool = false) {
        dynamicRangeTask?.cancel()

        dynamicRangeTask = Task {
            if !forceRecalculate {
                if let cached = await DynamicRangeEngine.shared.cachedResult(for: track) {
                    await MainActor.run {
                        self.currentDynamicRange = .ready(cached)
                    }
                    return
                }
            }

            await MainActor.run {
                self.currentDynamicRange = .calculating
            }

            let result = await DynamicRangeEngine.shared.dynamicRange(for: track, forceRecalculate: forceRecalculate)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                if let res = result {
                    self.currentDynamicRange = .ready(res)
                } else {
                    self.currentDynamicRange = .failed("Unsupported format or unreadable stream")
                }
            }
        }
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
        withAnimation(.easeInOut(duration: 0.2)) {
            showLyrics.toggle()
        }
    }

    public func toggleVisualizer() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showVisualizer.toggle()
        }
    }

    public func cycleVisualizerMode() {
        visualizerMode = visualizerMode.next
        showToast(icon: visualizerMode.systemImage, message: visualizerMode.rawValue)
    }

    public func setVisualizerMode(_ mode: VisualizerMode) {
        visualizerMode = mode
    }

    // MARK: - Toast Notifications

    public func showToast(icon: String, message: String, iconColor: Color? = nil) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            self.currentToast = ToastMessage(icon: icon, message: message, iconColor: iconColor)
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.currentToast = nil
                }
            }
        }
    }

    public func toggleFavorite(track: Track) {
        let isFav = playlists.isFavorite(trackId: track.id)
        playlists.toggleFavorite(trackId: track.id)
        if !isFav {
            showToast(icon: "star.fill", message: "Added \"\(track.displayTitle)\" to Favorites", iconColor: .accentColor)
        } else {
            showToast(icon: "star", message: "Removed \"\(track.displayTitle)\" from Favorites", iconColor: .secondary)
        }
    }

    public func toggleFavorite(trackId: String) {
        let isFav = playlists.isFavorite(trackId: trackId)
        playlists.toggleFavorite(trackId: trackId)
        let trackTitle = library.tracks.first(where: { $0.id == trackId })?.displayTitle ?? "Song"
        if !isFav {
            showToast(icon: "star.fill", message: "Added \"\(trackTitle)\" to Favorites", iconColor: .accentColor)
        } else {
            showToast(icon: "star", message: "Removed \"\(trackTitle)\" from Favorites", iconColor: .secondary)
        }
    }

    public func toggleFavorite(trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        let allFavs = trackIds.allSatisfy { playlists.isFavorite(trackId: $0) }
        if allFavs {
            playlists.removeFavorites(trackIds: trackIds)
            if trackIds.count == 1, let firstId = trackIds.first {
                let trackTitle = library.tracks.first(where: { $0.id == firstId })?.displayTitle ?? "Song"
                showToast(icon: "star", message: "Removed \"\(trackTitle)\" from Favorites", iconColor: .secondary)
            } else {
                showToast(icon: "star", message: "Removed \(trackIds.count) songs from Favorites", iconColor: .secondary)
            }
        } else {
            playlists.addFavorites(trackIds: trackIds)
            if trackIds.count == 1, let firstId = trackIds.first {
                let trackTitle = library.tracks.first(where: { $0.id == firstId })?.displayTitle ?? "Song"
                showToast(icon: "star.fill", message: "Added \"\(trackTitle)\" to Favorites", iconColor: .accentColor)
            } else {
                showToast(icon: "star.fill", message: "Added \(trackIds.count) songs to Favorites", iconColor: .accentColor)
            }
        }
    }

    public func addTrackToPlaylist(track: Track, playlistId: String) {
        playlists.addTrack(to: playlistId, trackId: track.id)
        let playlistName = playlists.playlists.first(where: { $0.id == playlistId })?.name ?? "Playlist"
        showToast(icon: "music.note.list", message: "Added \"\(track.displayTitle)\" to \(playlistName)", iconColor: .accentColor)
    }

    public func addTracksToPlaylist(trackIds: [String], playlistId: String) {
        guard !trackIds.isEmpty else { return }
        playlists.addTracks(to: playlistId, trackIds: trackIds)
        let playlistName = playlists.playlists.first(where: { $0.id == playlistId })?.name ?? "Playlist"
        if trackIds.count == 1, let firstId = trackIds.first {
            let trackTitle = library.tracks.first(where: { $0.id == firstId })?.displayTitle ?? "Song"
            showToast(icon: "music.note.list", message: "Added \"\(trackTitle)\" to \(playlistName)", iconColor: .accentColor)
        } else {
            showToast(icon: "music.note.list", message: "Added \(trackIds.count) songs to \(playlistName)", iconColor: .accentColor)
        }
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

    public var favoriteTracks: [Track] {
        let trackMap = Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0) })
        return playlists.favorites.compactMap { trackMap[$0] }
    }

    // MARK: - Resizable Columns

    private var dragStartArtistsWidth: CGFloat = 220
    private var isDraggingArtistsColumn: Bool = false

    public func handleArtistsDrag(translation: CGFloat, isEnded: Bool = false) {
        if !isDraggingArtistsColumn {
            isDraggingArtistsColumn = true
            dragStartArtistsWidth = artistsColumnWidth
        }
        let target = dragStartArtistsWidth + translation
        artistsColumnWidth = min(max(target, 140), 550)
        if isEnded {
            isDraggingArtistsColumn = false
            config.artistsColumnWidth = Double(artistsColumnWidth)
            config.save()
        }
    }

    public func resetArtistsColumnWidth() {
        artistsColumnWidth = 220
        config.artistsColumnWidth = 220
        config.save()
    }

    private var dragStartAlbumsWidth: CGFloat = 250
    private var isDraggingAlbumsColumn: Bool = false

    public func handleAlbumsDrag(translation: CGFloat, isEnded: Bool = false) {
        if !isDraggingAlbumsColumn {
            isDraggingAlbumsColumn = true
            dragStartAlbumsWidth = albumsColumnWidth
        }
        let target = dragStartAlbumsWidth + translation
        albumsColumnWidth = min(max(target, 160), 650)
        if isEnded {
            isDraggingAlbumsColumn = false
            config.albumsColumnWidth = Double(albumsColumnWidth)
            config.save()
        }
    }

    public func resetAlbumsColumnWidth() {
        albumsColumnWidth = 250
        config.albumsColumnWidth = 250
        config.save()
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
