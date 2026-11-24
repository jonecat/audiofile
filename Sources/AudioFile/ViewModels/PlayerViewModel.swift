import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

public enum NavigationSection: Hashable, Sendable {
    case artists
    case albums
    case songs
    case health
    case visualizer
    case opticalDisc
    case favorites
    case recentlyPlayed
    case playlist(String) // playlist ID
    case settings
}

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case library = "Library"
    case cdDrive = "CD Drive"
    case audio = "Audio"
    case visualizer = "Visualizer"
    case lyrics = "Lyrics"
    case about = "About"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .library: return "folder"
        case .cdDrive: return "opticaldisc"
        case .audio: return "speaker.wave.2"
        case .visualizer: return "waveform.path"
        case .lyrics: return "quote.bubble"
        case .about: return "info.circle"
        }
    }
}

public enum SearchCategoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case playlists = "Playlists"

    public var id: String { rawValue }
}

public enum AlbumSortMode: String, CaseIterable, Identifiable, Sendable {
    case artist = "Artist"
    case album = "Album"
    case year = "Date"

    public var id: String { rawValue }
}

@MainActor
public final class PlayerViewModel: ObservableObject {
    public static let shared = PlayerViewModel()

    @Published public var selectedSection: NavigationSection = .artists
    @Published public var searchQuery: String = ""
    @Published public var isSearchPresented: Bool = false
    @Published public var searchCategoryFilter: SearchCategoryFilter = .all
    @Published public var searchShowAllArtists: Bool = false
    @Published public var albumSortMode: AlbumSortMode = .artist

    public var sortedAlbums: [LibraryManager.AlbumInfo] {
        switch albumSortMode {
        case .artist:
            return library.allAlbums
        case .album:
            return library.allAlbumsByTitle
        case .year:
            return library.allAlbumsByYear
        }
    }

    public var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var sidebarSelectionBinding: Binding<NavigationSection?> {
        Binding(
            get: { self.isSearching ? nil : self.selectedSection },
            set: { newSection in
                if let section = newSection {
                    self.selectedSection = section
                    if !self.searchQuery.isEmpty {
                        self.searchQuery = ""
                        self.searchCategoryFilter = .all
                        self.searchShowAllArtists = false
                        self.updateFilteredTracks()
                    }
                }
            }
        )
    }

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
            preloadUpcoming()
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
    @Published public var showTrackInfo: Bool = true {
        didSet {
            config.showTrackInfo = showTrackInfo
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
    @Published public var fullscreenArtworkEffect: FullscreenArtworkEffect = .audioAura {
        didSet {
            config.fullscreenArtworkEffect = fullscreenArtworkEffect
            config.save()
        }
    }
    @Published public var isFullscreenPresented: Bool = false
    @Published public var fullscreenStageMode: FullscreenStageMode = .artwork
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
    @Published public var isHoveringAddPlaylist: Bool = false
    @Published public var isHoveringImportPlaylist: Bool = false
    @Published public var showingSignalPathPopover: Bool = false
    @Published public var showingQueuePopover: Bool = false
    @Published public var showingEQPopover: Bool = false
    @Published public var newPlaylistName: String = ""
    @Published public var playlistPendingDeletion: Playlist?
    @Published public var selectedArtist: String?
    @Published public var selectedAlbum: String?
    @Published public var selectedAlbumDetail: LibraryManager.AlbumInfo?
    // Preserved Albums grid scroll state (non-@Published to avoid per-frame view updates while scrolling)
    public var albumsGridScrollOffsetY: CGFloat = 0
    public var albumsGridScrollSortMode: AlbumSortMode = .artist
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
    @Published public private(set) var songsTableSortRevision: Int = 0

    public var sortOrderBinding: Binding<[KeyPathComparator<Track>]> {
        Binding(
            get: { self.sortOrder },
            set: { newOrder in
                let cappedOrder = newOrder.count > 2 ? Array(newOrder.prefix(2)) : newOrder
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.sortOrder = cappedOrder
                    self.updateSortedTracks()
                    self.songsTableSortRevision &+= 1
                }
            }
        )
    }
    @Published public var showingCacheClearedAlert: Bool = false
    @Published public var showingResetLibraryConfirmation: Bool = false

    // Track Metadata Inspector & Editor state
    @Published public var inspectingTrack: Track?
    @Published public var inspectedTrackTagReport: FullTrackTagReport? = nil
    @Published public var isLoadingInspectedTags: Bool = false
    @Published public var metaTagFilterQuery: String = ""
    private var inspectTagsTask: Task<Void, Never>?
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
    @Published public private(set) var searchMatchingArtists: [String] = []
    @Published public private(set) var searchMatchingAlbums: [LibraryManager.AlbumInfo] = []
    @Published public private(set) var searchMatchingPlaylists: [Playlist] = []

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
    public let opticalDiscManager = OpticalDiscManager.shared
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
        self.showTrackInfo = config.showTrackInfo
        self.visualizerMode = config.visualizerMode
        self.visualizer.setMode(config.visualizerMode)
        self.fullscreenArtworkEffect = config.fullscreenArtworkEffect
        self.lyricsScale = config.lyricsScale
        self.audio.volume = config.volume
        self.audio.applyAudioConfig(config)
        self.artistsColumnWidth = CGFloat(config.artistsColumnWidth)
        self.albumsColumnWidth = CGFloat(config.albumsColumnWidth)

        VisualizerEngine.shared.setFPS(Double(config.visualizerFPS))

        setupSubscriptions()
        updateFilteredTracks()
        updateVisualizerTimerState()

        // Kick off incremental background library sync
        library.startSync(folders: config.libraryFolders, fullRescan: false)

        // Check GitHub Releases for a newer version on startup
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            AppUpdater.shared.checkForUpdates(userInitiated: false)
        }
    }

    private func setupSubscriptions() {
        // Forward audio track completion and gapless transitions
        audio.onTrackCompleted = { [weak self] in
            self?.handleTrackEnded()
        }
        audio.onGaplessTrackAdvanced = { [weak self] advancedTrack in
            self?.handleGaplessTrackAdvanced(to: advancedTrack)
        }
        audio.onPreviousTrackRequested = { [weak self] in
            self?.previousTrack()
        }

        // Library structural changes -> update filtered & sorted tracks
        library.libraryStructureDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFilteredTracks()
            }
            .store(in: &cancellables)

        // Single/batch metadata updates (play count, DR score) -> patch tracks in place without re-sorting
        library.trackMetadataDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] updatedTracks in
                self?.updateTracksInPlace(updatedTracks)
            }
            .store(in: &cancellables)

        // Search query updates -> immediate reset when cleared, debounced filter while typing
        $searchQuery
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] query in
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.searchCategoryFilter = .all
                    self?.searchShowAllArtists = false
                    self?.updateFilteredTracks(query: query)
                }
            }
            .store(in: &cancellables)

        $searchQuery
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] query in
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.searchShowAllArtists = false
                    self?.updateFilteredTracks(query: query)
                }
            }
            .store(in: &cancellables)

        // Visualizer timer lifecycle: run only when playing AND viewing Visualizer with panel visible (paused during full-screen presentation)
        Publishers.CombineLatest4(audio.$state, $selectedSection, $showVisualizer, $isFullscreenPresented)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, section, showVis, isFullscreen in
                self?.updateVisualizerTimerState(
                    state: state,
                    section: section,
                    showVisualizer: showVis,
                    isFullscreen: isFullscreen
                )
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
                    if t.isOpticalDiscTrack {
                        self.currentDynamicRange = .idle
                        self.dynamicRangeTask?.cancel()
                        self.dynamicRangeTask = nil
                    } else {
                        self.calculateDynamicRange(for: t)
                    }
                } else {
                    self.currentWaveform = nil
                    self.currentDynamicRange = .idle
                    self.dynamicRangeTask?.cancel()
                    self.dynamicRangeTask = nil
                }
            }
            .store(in: &cancellables)

        // Optical Disc detection & ejection handling
        opticalDiscManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        var previousOpticalDiscID: String? = nil
        opticalDiscManager.$detectedDisc
            .receive(on: RunLoop.main)
            .sink { [weak self] disc in
                guard let self = self else { return }
                if let d = disc {
                    if d.id != previousOpticalDiscID {
                        previousOpticalDiscID = d.id
                        let discName = d.title.isEmpty ? "Audio CD" : d.title
                        self.showToast(icon: "opticaldisc", message: "Audio CD Detected: \(discName)")
                    }
                } else if previousOpticalDiscID != nil {
                    previousOpticalDiscID = nil
                    if self.selectedSection == .opticalDisc {
                        self.selectedSection = .songs
                    }
                    if let cur = self.audio.currentTrack, cur.id.hasPrefix("optical_") {
                        self.audio.stop()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Dynamic Range Measurement

    public func calculateDynamicRange(for track: Track, forceRecalculate: Bool = false) {
        if track.isOpticalDiscTrack {
            dynamicRangeTask?.cancel()
            dynamicRangeTask = nil
            currentDynamicRange = .idle
            return
        }

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
        updateVisualizerTimerState()
    }

    public func updateVisualizerTimerState(
        state: PlaybackState? = nil,
        section: NavigationSection? = nil,
        showVisualizer: Bool? = nil,
        isFullscreen: Bool? = nil
    ) {
        let effectiveState = state ?? audio.state
        let effectiveSection = section ?? selectedSection
        let effectiveShow = showVisualizer ?? self.showVisualizer
        let effectiveFullscreen = isFullscreen ?? self.isFullscreenPresented

        if !effectiveFullscreen && effectiveState == .playing && effectiveSection == .visualizer && effectiveShow {
            visualizer.start(fps: config.visualizerFPS)
        } else {
            visualizer.stop(resetFrame: effectiveState == .stopped || !effectiveShow)
        }
    }

    // MARK: - Full-Screen Presentation

    public func presentFullscreen(_ mode: FullscreenStageMode = .artwork) {
        guard audio.currentTrack != nil else { return }
        fullscreenStageMode = mode
        isFullscreenPresented = true
        FullscreenArtworkWindowController.shared.present(vm: self)
    }

    public func dismissFullscreen() {
        isFullscreenPresented = false
        FullscreenArtworkWindowController.shared.dismiss()
    }

    public func toggleFullscreen(_ mode: FullscreenStageMode = .artwork) {
        if isFullscreenPresented {
            if fullscreenStageMode == mode {
                dismissFullscreen()
            } else {
                fullscreenStageMode = mode
            }
        } else {
            presentFullscreen(mode)
        }
    }

    public func cycleFullscreenArtworkEffect() {
        fullscreenArtworkEffect = fullscreenArtworkEffect.next
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
            audio.play(track: next)
            preloadUpcoming()
        } else if repeatMode == .all {
            currentQueueIndex = 0
            let first = queue[0]
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
            audio.play(track: prev)
            preloadUpcoming()
        } else if repeatMode == .all || isLibraryShuffleActive {
            currentQueueIndex = queue.count - 1
            let last = queue[currentQueueIndex]
            audio.play(track: last)
            preloadUpcoming()
        } else {
            audio.seek(to: 0)
        }
    }

    private func handleTrackEnded() {
        nextTrack()
    }

    private func handleGaplessTrackAdvanced(to advancedTrack: Track) {
        let nextIndex = currentQueueIndex + 1
        if nextIndex < queue.count, queue[nextIndex].id == advancedTrack.id {
            currentQueueIndex = nextIndex
        } else if repeatMode == .all, queue.first?.id == advancedTrack.id {
            currentQueueIndex = 0
        } else if let foundIndex = queue.firstIndex(where: { $0.id == advancedTrack.id }) {
            currentQueueIndex = foundIndex
        }

        selectedTrackId = advancedTrack.id
        if isLibraryShuffleActive && currentQueueIndex + 1 >= queue.count {
            appendReshuffledLibraryPass()
        }
        preloadUpcoming()
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
        if repeatMode == .one, let current = audio.currentTrack {
            audio.preloadNextTrack(current)
            return
        }
        if isLibraryShuffleActive && currentQueueIndex + 1 >= queue.count {
            appendReshuffledLibraryPass()
        }
        let upcomingIndex = currentQueueIndex + 1
        if upcomingIndex < queue.count {
            let next = queue[upcomingIndex]
            audio.preloadNextTrack(next)
        } else if repeatMode == .all, let first = queue.first {
            audio.preloadNextTrack(first)
        } else {
            audio.clearPreloadedNextTrack()
        }
    }

    // MARK: - Queue Management

    public var upcomingQueueItems: [(index: Int, track: Track)] {
        guard !queue.isEmpty else { return [] }
        let startIndex = max(0, currentQueueIndex + 1)
        guard startIndex < queue.count else { return [] }
        return (startIndex..<queue.count).map { ($0, queue[$0]) }
    }

    public func playTrackNext(_ track: Track) {
        playTracksNext([track])
    }

    public func playTracksNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty || audio.currentTrack == nil {
            playTrack(tracks[0], in: tracks)
            return
        }
        let insertIndex = (currentQueueIndex >= 0 && currentQueueIndex < queue.count)
            ? currentQueueIndex + 1
            : queue.count
        queue.insert(contentsOf: tracks, at: insertIndex)
        if !shuffle && !isLibraryShuffleActive {
            originalQueue = queue
        }
        preloadUpcoming()
        showToast(
            icon: "text.insert",
            message: tracks.count == 1 ? "Playing Next: \(tracks[0].displayTitle)" : "Playing \(tracks.count) Songs Next"
        )
    }

    public func addTrackToEndOfQueue(_ track: Track) {
        addTracksToEndOfQueue([track])
    }

    public func addTracksToEndOfQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty || audio.currentTrack == nil {
            playTrack(tracks[0], in: tracks)
            return
        }
        queue.append(contentsOf: tracks)
        if !shuffle && !isLibraryShuffleActive {
            originalQueue = queue
        }
        preloadUpcoming()
        showToast(
            icon: "text.append",
            message: tracks.count == 1 ? "Added to Queue: \(tracks[0].displayTitle)" : "Added \(tracks.count) Songs to Queue"
        )
    }

    public func removeQueueItem(at index: Int) {
        guard queue.indices.contains(index), index != currentQueueIndex else { return }
        queue.remove(at: index)
        if index < currentQueueIndex {
            currentQueueIndex -= 1
        }
        if !shuffle && !isLibraryShuffleActive {
            originalQueue = queue
        }
        preloadUpcoming()
    }

    public func clearUpcomingQueue() {
        guard currentQueueIndex >= 0, currentQueueIndex + 1 < queue.count else { return }
        queue.removeSubrange((currentQueueIndex + 1)..<queue.count)
        if !shuffle && !isLibraryShuffleActive {
            originalQueue = queue
        }
        preloadUpcoming()
    }

    public func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentQueueIndex = index
        let track = queue[index]
        selectedTrackId = track.id
        audio.play(track: track)
        preloadUpcoming()
    }

    // MARK: - Audiophile DAC, Signal Path, Parametric EQ, Crossfeed & ReplayGain

    public enum SignalPathTier {
        case idle
        case lossy
        case enhanced
        case bitPerfect
    }

    public var signalPathTier: SignalPathTier {
        guard let track = audio.currentTrack else { return .idle }
        guard track.isLossless else { return .lossy }
        let trackRate = track.sampleRate ?? audio.hardwareSampleRate
        let rateMatched = abs(trackRate - audio.hardwareSampleRate) < 1.0
        let dspBypassed = !config.eqEnabled
            && !config.crossfeedEnabled
            && (config.replayGainMode == .off || abs(audio.activeReplayGainDb) < 0.05)
        let unityVolume = !audio.isMuted && abs(audio.volume - 1.0) <= 0.005
        return (rateMatched && dspBypassed && unityVolume) ? .bitPerfect : .enhanced
    }

    public static let eqPresetNames: [String] = [
        "Flat",
        "Harman Target",
        "Bass Boost",
        "Vocal Presence",
        "Treble Air",
        "Late Night"
    ]

    public func refreshOutputDevices() {
        audio.refreshOutputDevices()
    }

    public func selectOutputDevice(uid: String?) {
        config.selectedOutputDeviceUID = uid
        config.save()
        audio.applyAudioConfig(config)
    }

    public func setAutoSampleRateSwitching(_ enabled: Bool) {
        config.autoSampleRateSwitching = enabled
        config.save()
        audio.applyAudioConfig(config)
        preloadUpcoming()
    }

    public func setExclusiveHogMode(_ enabled: Bool) {
        config.exclusiveHogMode = enabled
        config.save()
        audio.applyAudioConfig(config)
    }

    public func setReplayGainMode(_ mode: ReplayGainMode) {
        config.replayGainMode = mode
        config.save()
        audio.applyAudioConfig(config)
    }

    public func setReplayGainPreamp(_ db: Float) {
        config.replayGainPreampDb = db
        config.save()
        audio.applyAudioConfig(config)
    }

    public func setEQEnabled(_ enabled: Bool) {
        config.eqEnabled = enabled
        config.save()
        audio.applyAudioConfig(config)
    }

    public func setEQPreamp(_ db: Float) {
        config.eqPreampDb = db
        config.save()
        audio.applyAudioConfig(config)
    }

    public func updateEQBand(at index: Int, gainDb: Float) {
        guard config.eqBands.indices.contains(index) else { return }
        config.eqBands[index].gainDb = gainDb
        config.eqPresetName = "Custom"
        if !config.eqEnabled {
            config.eqEnabled = true
        }
        config.save()
        audio.applyAudioConfig(config)
    }

    public func applyEQPreset(_ presetName: String) {
        let gains: [Float]
        let preamp: Float
        switch presetName {
        case "Harman Target":
            gains = [3.5, 2.5, 0.5, -1.0, 0.0, 0.5, 1.5, 2.5, 1.0, -0.5]
            preamp = -3.5
        case "Bass Boost":
            gains = [5.5, 4.5, 2.5, 0.5, 0.0, 0.0, 0.0, 0.5, 1.0, 1.0]
            preamp = -5.5
        case "Vocal Presence":
            gains = [-1.5, -1.0, 0.0, 1.0, 2.0, 3.0, 3.5, 2.0, 0.5, 0.0]
            preamp = -3.5
        case "Treble Air":
            gains = [0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 1.5, 3.0, 4.0, 4.5]
            preamp = -4.5
        case "Late Night":
            gains = [3.0, 2.0, 0.5, 0.0, 1.5, 2.0, 1.5, 1.0, 2.5, 2.0]
            preamp = -3.0
        default: // "Flat"
            gains = Array(repeating: 0.0, count: 10)
            preamp = 0.0
        }

        var bands = AppConfig.defaultEQBands()
        for i in 0..<min(bands.count, gains.count) {
            bands[i].gainDb = gains[i]
        }
        config.eqBands = bands
        config.eqPreampDb = preamp
        config.eqPresetName = presetName
        if presetName == "Flat" {
            // Keep current eqEnabled unless already explicitly desired
        } else {
            config.eqEnabled = true
        }
        config.save()
        audio.applyAudioConfig(config)
    }

    public func importAutoEQFile() {
        let panel = NSOpenPanel()
        panel.title = "Import AutoEQ / EqualizerAPO Parametric EQ"
        panel.message = "Select a ParametricEQ .txt profile (EqualizerAPO / AutoEQ format)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let content = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            showToast(icon: "exclamationmark.triangle", message: "Could not read EQ profile")
            return
        }

        var preamp: Float = 0.0
        var parsedBands: [EQBandConfig] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.lowercased().hasPrefix("preamp:") {
                let tokens = line.dropFirst(7).split(whereSeparator: { $0.isWhitespace })
                if let firstNum = tokens.first, let val = Float(firstNum) {
                    preamp = max(-18.0, min(12.0, val))
                }
                continue
            }

            if line.lowercased().hasPrefix("filter ") {
                let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard parts.contains(where: { $0.uppercased() == "ON" }) else { continue }

                var filterType: EQFilterType = .parametric
                if parts.contains(where: { $0.uppercased() == "LS" || $0.uppercased() == "LSC" }) {
                    filterType = .lowShelf
                } else if parts.contains(where: { $0.uppercased() == "HS" || $0.uppercased() == "HSC" }) {
                    filterType = .highShelf
                } else if !parts.contains(where: { $0.uppercased() == "PK" || $0.uppercased() == "PEQ" }) {
                    continue
                }

                var freq: Double?
                var gain: Float?
                var qVal: Double = 1.41

                for idx in parts.indices {
                    let token = parts[idx].uppercased()
                    if token == "FC", idx + 1 < parts.count, let v = Double(parts[idx + 1]) {
                        freq = v
                    } else if token == "GAIN", idx + 1 < parts.count, let v = Float(parts[idx + 1]) {
                        gain = max(-18.0, min(18.0, v))
                    } else if token == "Q", idx + 1 < parts.count, let v = Double(parts[idx + 1]) {
                        qVal = max(0.1, min(10.0, v))
                    }
                }

                if let f = freq, let g = gain, parsedBands.count < 10 {
                    parsedBands.append(
                        EQBandConfig(
                            id: parsedBands.count,
                            frequency: f,
                            gainDb: g,
                            qFactor: qVal,
                            filterType: filterType
                        )
                    )
                }
            }
        }

        guard !parsedBands.isEmpty else {
            showToast(icon: "exclamationmark.triangle", message: "No compatible ParametricEQ filters found")
            return
        }

        // Pad up to 10 bands so UI sliders stay aligned when profiles have fewer than 10 filters
        let defaults = AppConfig.defaultEQBands()
        while parsedBands.count < 10 {
            let nextIdx = parsedBands.count
            var padBand = defaults[nextIdx]
            padBand.id = nextIdx
            padBand.gainDb = 0.0
            parsedBands.append(padBand)
        }

        let name = url.deletingPathExtension().lastPathComponent
        config.eqBands = parsedBands
        config.eqPreampDb = preamp
        config.eqPresetName = name
        config.eqEnabled = true
        config.save()
        audio.applyAudioConfig(config)
        showToast(icon: "slider.vertical.3", message: "Imported EQ: \(name)")
    }

    public func setCrossfeedEnabled(_ enabled: Bool) {
        config.crossfeedEnabled = enabled
        config.save()
        audio.applyAudioConfig(config)
    }

    public func setCrossfeedLevel(_ level: Float) {
        config.crossfeedLevel = max(0.0, min(1.0, level))
        config.save()
        audio.applyAudioConfig(config)
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

    public func toggleTrackInfo() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showTrackInfo.toggle()
        }
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
        playlists.favorites.compactMap { library.track(forId: $0) }
    }

    public func resetAndRescanLibrary() {
        audio.clearCurrentTrack()
        queue.removeAll()
        originalQueue.removeAll()
        selectedTrackIds.removeAll()
        currentWaveform = nil
        currentDynamicRange = .idle
        dynamicRangeTask?.cancel()
        dynamicRangeTask = nil

        playlists.clearAllData()
        health.clearAllOverridesAndIgnored()
        Task {
            await DynamicRangeEngine.shared.clearAllData()
        }
        library.clearAllData()
        library.startSync(folders: config.libraryFolders, fullRescan: true)

        showToast(icon: "arrow.clockwise", message: "Library reset. Rescanning \(config.libraryFolders.count) folder(s)…")
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
        inspectTagsTask?.cancel()
        inspectTagsTask = nil

        let current = library.tracks.first(where: { $0.id == track.id }) ?? track
        metaTitle = current.displayTitle
        metaArtist = current.artist == "Unknown Artist" ? "" : current.displayArtist
        metaAlbum = current.album == "Unknown Album" ? "" : current.displayAlbum
        metaAlbumArtist = current.albumArtist ?? current.displayAlbumArtist
        metaGenre = current.genre ?? ""
        metaTrackNumber = current.trackNumber.map { String($0) } ?? ""
        metaDiscNumber = current.discNumber.map { String($0) } ?? ""
        metaYear = current.formattedReleaseDate ?? ""
        metaSaveMode = health.fixMode
        metaTagFilterQuery = ""
        inspectedTrackTagReport = nil
        isSavingTrackMetadata = false
        inspectingTrack = current

        if current.id.hasPrefix("optical_") || current.format.uppercased() == "CDDA" {
            isLoadingInspectedTags = false
            inspectedTrackTagReport = FullTrackTagReport(sections: [])
            return
        }

        isLoadingInspectedTags = true
        inspectTagsTask = Task { @MainActor [weak self] in
            let report = await FullTagReader.readAllTags(for: current.path)
            guard let self = self,
                  !Task.isCancelled,
                  self.inspectingTrack?.id == current.id else {
                return
            }
            self.inspectedTrackTagReport = report
            self.isLoadingInspectedTags = false
        }
    }

    public func endInspectingMetadata() {
        inspectTagsTask?.cancel()
        inspectTagsTask = nil
        inspectingTrack = nil
        inspectedTrackTagReport = nil
        isLoadingInspectedTags = false
        metaTagFilterQuery = ""
    }

    public func saveInspectedTrackMetadata() {
        guard let track = inspectingTrack else { return }
        isSavingTrackMetadata = true

        let trimmedDate = metaYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedDate = ParsedReleaseDate.parse(trimmedDate)
        let override = TrackMetadataOverride(
            title: metaTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: metaArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: metaAlbum.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtist: metaAlbumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            trackNumber: Int(metaTrackNumber.trimmingCharacters(in: .whitespaces)),
            discNumber: Int(metaDiscNumber.trimmingCharacters(in: .whitespaces)),
            year: parsedDate?.year,
            releaseDate: parsedDate?.formattedString ?? (trimmedDate.isEmpty ? nil : trimmedDate),
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
            endInspectingMetadata()
        }
    }

    // MARK: - Search Filtering & Sorting

    public func clearSearch() {
        searchQuery = ""
        searchCategoryFilter = .all
        searchShowAllArtists = false
        updateFilteredTracks()
    }

    public func openArtistFromSearch(_ artist: String) {
        selectedArtist = artist
        selectedAlbum = nil
        selectedSection = .artists
        searchQuery = ""
        searchCategoryFilter = .all
        searchShowAllArtists = false
        updateFilteredTracks()
    }

    public func openAlbumFromSearch(_ album: LibraryManager.AlbumInfo) {
        selectedAlbumDetail = album
        selectedSection = .albums
        searchQuery = ""
        searchCategoryFilter = .all
        searchShowAllArtists = false
        updateFilteredTracks()
    }

    public func openPlaylistFromSearch(_ playlist: Playlist) {
        selectedSection = .playlist(playlist.id)
        searchQuery = ""
        searchCategoryFilter = .all
        searchShowAllArtists = false
        updateFilteredTracks()
    }

    public func updateFilteredAndSortedTracks() {
        updateFilteredTracks()
    }

    public func updateFilteredTracks(query: String? = nil) {
        let trimmed = (query ?? searchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [Track]
        if trimmed.isEmpty {
            filtered = library.tracks
            self.searchMatchingArtists = []
            self.searchMatchingAlbums = []
            self.searchMatchingPlaylists = []
        } else {
            let q = trimmed.lowercased()
            filtered = library.tracks.filter { $0.searchHaystack.contains(q) }
            self.searchMatchingArtists = library.uniqueArtists.filter {
                $0.localizedCaseInsensitiveContains(trimmed)
            }
            self.searchMatchingAlbums = library.allAlbums.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed) ||
                $0.artist.localizedCaseInsensitiveContains(trimmed)
            }
            self.searchMatchingPlaylists = playlists.playlists.filter { pl in
                pl.name.localizedCaseInsensitiveContains(trimmed) ||
                pl.trackIds.contains(where: { library.track(forId: $0)?.searchHaystack.contains(q) == true })
            }
        }
        self.filteredTracks = filtered
        updateSortedTracks()
    }

    public func updateSortedTracks() {
        guard !filteredTracks.isEmpty else {
            self.sortedTracks = []
            return
        }
        let order = sortOrder
        if order.isEmpty {
            self.sortedTracks = filteredTracks
            return
        }

        guard order.allSatisfy({ Self.isFastSortableKeyPath($0.keyPath) }) else {
            self.sortedTracks = filteredTracks.sorted(using: order)
            return
        }

        self.sortedTracks = filteredTracks.sorted { a, b in
            for comp in order {
                if let cmp = Self.compareTracks(a, b, using: comp), cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
            }
            if a.releaseDateSortKey != b.releaseDateSortKey {
                return a.releaseDateSortKey < b.releaseDateSortKey
            }
            if a.albumSortKey != b.albumSortKey {
                return a.albumSortKey < b.albumSortKey
            }
            let discA = a.discNumber ?? 1
            let discB = b.discNumber ?? 1
            if discA != discB {
                return discA < discB
            }
            let trackA = a.trackNumber ?? 0
            let trackB = b.trackNumber ?? 0
            if trackA != trackB {
                return trackA < trackB
            }
            if a.titleSortKey != b.titleSortKey {
                return a.titleSortKey < b.titleSortKey
            }
            return a.id < b.id
        }
    }

    public func updateTracksInPlace(_ updatedTracks: [Track]) {
        guard !updatedTracks.isEmpty else { return }
        let updatesById = Dictionary(uniqueKeysWithValues: updatedTracks.map { ($0.id, $0) })

        var filteredCopy = filteredTracks
        var filteredChanged = false
        for i in filteredCopy.indices {
            if let updated = updatesById[filteredCopy[i].id] {
                filteredCopy[i] = updated
                filteredChanged = true
            }
        }
        if filteredChanged {
            self.filteredTracks = filteredCopy
        }

        var sortedCopy = sortedTracks
        var sortedChanged = false
        for i in sortedCopy.indices {
            if let updated = updatesById[sortedCopy[i].id] {
                sortedCopy[i] = updated
                sortedChanged = true
            }
        }
        if sortedChanged {
            self.sortedTracks = sortedCopy
        }
    }

    private static func isFastSortableKeyPath(_ keyPath: AnyKeyPath) -> Bool {
        switch keyPath {
        case \Track.displayTitle,
             \Track.displayArtist,
             \Track.displayAlbum,
             \Track.duration,
             \Track.playCountSortKey,
             \Track.dynamicRangeSortKey,
             \Track.format:
            return true
        default:
            return false
        }
    }

    private static func compareTracks(
        _ a: Track,
        _ b: Track,
        using comparator: KeyPathComparator<Track>
    ) -> ComparisonResult? {
        let result: ComparisonResult
        switch comparator.keyPath {
        case \Track.displayTitle:
            if a.titleSortKey == b.titleSortKey { result = .orderedSame }
            else { result = a.titleSortKey < b.titleSortKey ? .orderedAscending : .orderedDescending }
        case \Track.displayArtist:
            if a.artistSortKey == b.artistSortKey { result = .orderedSame }
            else { result = a.artistSortKey < b.artistSortKey ? .orderedAscending : .orderedDescending }
        case \Track.displayAlbum:
            if a.albumSortKey == b.albumSortKey { result = .orderedSame }
            else { result = a.albumSortKey < b.albumSortKey ? .orderedAscending : .orderedDescending }
        case \Track.duration:
            if a.duration == b.duration { result = .orderedSame }
            else { result = a.duration < b.duration ? .orderedAscending : .orderedDescending }
        case \Track.playCountSortKey:
            let pa = a.playCountSortKey
            let pb = b.playCountSortKey
            if pa == pb { result = .orderedSame }
            else { result = pa < pb ? .orderedAscending : .orderedDescending }
        case \Track.dynamicRangeSortKey:
            let da = a.dynamicRangeSortKey
            let db = b.dynamicRangeSortKey
            if da == db { result = .orderedSame }
            else { result = da < db ? .orderedAscending : .orderedDescending }
        case \Track.format:
            if a.format == b.format { result = .orderedSame }
            else { result = a.format < b.format ? .orderedAscending : .orderedDescending }
        default:
            return nil
        }
        if result == .orderedSame { return .orderedSame }
        if comparator.order == .forward { return result }
        return result == .orderedAscending ? .orderedDescending : .orderedAscending
    }
}
