import Foundation
import Combine

@MainActor
public final class LibraryManager: ObservableObject {
    public static let shared = LibraryManager()

    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var uniqueArtists: [String] = []
    @Published public private(set) var allAlbums: [AlbumInfo] = []
    @Published public private(set) var allAlbumsByTitle: [AlbumInfo] = []
    @Published public private(set) var allAlbumsByYear: [AlbumInfo] = []
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var isFullRescan: Bool = false
    @Published public private(set) var syncStatusText: String = ""
    @Published public private(set) var syncCompletedMessage: String?

    public let libraryStructureDidChange = PassthroughSubject<Void, Never>()
    public let trackMetadataDidUpdate = PassthroughSubject<[Track], Never>()

    public private(set) var tracksById: [String: Track] = [:]
    private var albumsByArtistMap: [String: [String]] = [:]
    private var albumYearByArtistAndAlbumMap: [String: Int] = [:]
    private var albumReleaseDateByArtistAndAlbumMap: [String: ParsedReleaseDate] = [:]
    private var tracksByArtistMap: [String: [Track]] = [:]
    private var tracksByArtistAndAlbumMap: [String: [Track]] = [:]
    private var trackCountByArtistMap: [String: Int] = [:]

    private var saveDebounceTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "com.audiofile.library.save", qos: .utility)

    private static var libraryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AudioFile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("library.json")
    }

    public init() {
        loadLibrary()
    }

    public static func stripLeadingThe(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 4 && trimmed.prefix(4).lowercased() == "the " {
            return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    public static func compareArtists(_ a: String, _ b: String) -> Bool {
        let keyA = stripLeadingThe(a).lowercased()
        let keyB = stripLeadingThe(b).lowercased()
        if keyA != keyB {
            return keyA < keyB
        }
        return a.lowercased() < b.lowercased()
    }

    public func sortTracks() {
        tracks.sort { (a: Track, b: Track) -> Bool in
            if a.artistSortKey != b.artistSortKey {
                return a.artistSortKey < b.artistSortKey
            }
            if a.displayArtist != b.displayArtist {
                return a.displayArtist.localizedCaseInsensitiveCompare(b.displayArtist) == .orderedAscending
            }
            if a.releaseDateSortKey != b.releaseDateSortKey {
                return a.releaseDateSortKey < b.releaseDateSortKey
            }
            if a.albumSortKey != b.albumSortKey {
                return a.albumSortKey < b.albumSortKey
            }
            if (a.discNumber ?? 1) != (b.discNumber ?? 1) {
                return (a.discNumber ?? 1) < (b.discNumber ?? 1)
            }
            if (a.trackNumber ?? 0) != (b.trackNumber ?? 0) {
                return (a.trackNumber ?? 0) < (b.trackNumber ?? 0)
            }
            return a.titleSortKey < b.titleSortKey
        }
        rebuildIndexes()
    }

    public func loadLibrary() {
        let url = Self.libraryURL
        if let data = try? Data(contentsOf: url),
           var loaded = try? JSONDecoder().decode([Track].self, from: data) {
            var modified = false
            for i in 0..<loaded.count {
                if let aa = loaded[i].albumArtist, UUID(uuidString: aa) != nil {
                    loaded[i].albumArtist = nil
                    modified = true
                }
                if UUID(uuidString: loaded[i].artist) != nil {
                    let parent = loaded[i].path.deletingLastPathComponent().deletingLastPathComponent()
                    let fallback = parent.lastPathComponent
                    loaded[i].artist = (fallback.isEmpty || fallback == "/") ? "Unknown Artist" : fallback
                    modified = true
                }
                if loaded[i].trackNumber == nil {
                    let parsed = MetadataReader.extractTrackAndDiscFromFilename(loaded[i].path)
                    if let t = parsed.track {
                        loaded[i].trackNumber = t
                        modified = true
                    }
                    if loaded[i].discNumber == nil, let d = parsed.disc {
                        loaded[i].discNumber = d
                        modified = true
                    }
                }
                if OpenSourceDecoders.requiresCustomDecoder(loaded[i].path) &&
                    ((loaded[i].sampleRate ?? 0) < 8000 || loaded[i].duration <= 0 || loaded[i].duration > 86_400) {
                    let meta = OpenSourceDecoders.readMetadata(for: loaded[i].path)
                    if let sr = meta.sampleRate, sr > 0 {
                        loaded[i].sampleRate = sr
                    }
                    if let bd = meta.bitDepth, bd > 0 {
                        loaded[i].bitDepth = bd
                    }
                    if meta.duration > 0 {
                        loaded[i].duration = meta.duration
                    }
                    if let br = meta.bitrate, br > 0 {
                        loaded[i].bitrate = br
                    }
                    modified = true
                }
            }
            var distinctCueOffsetsByPath: [String: Set<Double>] = [:]
            for item in loaded where item.isCueTrack {
                distinctCueOffsetsByPath[item.path.standardizedFileURL.path, default: []].insert(item.startTimeOffset ?? 0)
            }
            var cleanedLoaded: [Track] = []
            cleanedLoaded.reserveCapacity(loaded.count)
            var seenRestoredCuePaths: Set<String> = []
            for item in loaded {
                let stdPath = item.path.standardizedFileURL.path
                if item.isCueTrack && (distinctCueOffsetsByPath[stdPath]?.count ?? 0) <= 1 {
                    modified = true
                    guard seenRestoredCuePaths.insert(stdPath).inserted else {
                        continue
                    }
                    let canonicalId = Track.generateId(for: item.path)
                    cleanedLoaded.append(Track(
                        id: canonicalId,
                        path: item.path,
                        title: item.title,
                        artist: item.artist,
                        album: item.album,
                        albumArtist: item.albumArtist,
                        genre: item.genre,
                        year: item.year,
                        releaseDate: item.releaseDate,
                        trackNumber: item.trackNumber,
                        discNumber: item.discNumber,
                        duration: item.duration,
                        format: item.format,
                        sampleRate: item.sampleRate,
                        bitDepth: item.bitDepth,
                        bitrate: item.bitrate,
                        hasCoverArt: item.hasCoverArt,
                        fileSize: item.fileSize,
                        modifiedDate: nil,
                        dynamicRange: item.dynamicRange,
                        playCount: item.playCount,
                        startTimeOffset: nil,
                        endTimeOffset: nil,
                        replayGainTrackDb: item.replayGainTrackDb,
                        replayGainAlbumDb: item.replayGainAlbumDb,
                        replayGainPeak: item.replayGainPeak
                    ))
                } else {
                    cleanedLoaded.append(item)
                }
            }
            loaded = cleanedLoaded
            let savedOverrides = LibraryHealthManager.readOverridesFromDisk()
            let storedScores = DynamicRangeEngine.readStoredScores()
            for i in loaded.indices {
                if savedOverrides[loaded[i].id] != nil {
                    LibraryHealthManager.applyOverride(from: savedOverrides, to: &loaded[i])
                }
                if loaded[i].dynamicRange == nil, let s = storedScores[loaded[i].id] {
                    loaded[i].dynamicRange = s
                    modified = true
                }
            }
            self.tracks = loaded
            sortTracks()
            PlaylistManager.shared.pruneOrphans(validTrackIds: Set(loaded.map(\.id)))
            libraryStructureDidChange.send()
            if modified {
                saveLibrary(immediate: true)
            }
            return
        }

        // Fallback: check if omaflac library.json exists in ~/.config/omaflac/library.json
        let omaflacURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omaflac/library.json")
        if let data = try? Data(contentsOf: omaflacURL),
           let omaflacDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tracksArray = omaflacDict["tracks"] as? [[String: Any]] {
            // Can import omaflac tracks
            importOmaflacTracks(tracksArray)
        }
    }

    private func importOmaflacTracks(_ rawList: [[String: Any]]) {
        var imported: [Track] = []
        for dict in rawList {
            guard let pathStr = dict["path"] as? String else { continue }
            let url = URL(fileURLWithPath: pathStr)
            let id = dict["id"] as? String
            let title = dict["title"] as? String ?? ""
            let artist = dict["artist"] as? String ?? ""
            let album = dict["album"] as? String ?? ""
            let albumArtist = dict["album_artist"] as? String
            let genre = dict["genre"] as? String
            let year = dict["year"] as? Int
            let releaseDate = dict["release_date"] as? String
            let trackNumber = dict["track_number"] as? Int
            let discNumber = dict["disc_number"] as? Int
            let durationSecs = dict["duration_secs"] as? Double ?? 0
            let format = dict["format"] as? String ?? "FLAC"
            let sampleRate = dict["sample_rate"] as? Double
            let bitDepth = dict["bit_depth"] as? Int
            let bitrate = dict["bitrate_kbps"] as? Int
            let hasCover = dict["has_cover_art"] as? Bool ?? false
            let fileSize = dict["file_size"] as? UInt64
            let modifiedSecs = dict["modified_secs"] as? UInt64
            let modifiedDate = modifiedSecs.map { Date(timeIntervalSince1970: TimeInterval($0)) }

            imported.append(Track(
                id: id,
                path: url,
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                genre: genre,
                year: year,
                releaseDate: releaseDate,
                trackNumber: trackNumber,
                discNumber: discNumber,
                duration: durationSecs,
                format: format,
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                bitrate: bitrate,
                hasCoverArt: hasCover,
                fileSize: fileSize,
                modifiedDate: modifiedDate
            ))
        }
        if !imported.isEmpty {
            self.tracks = imported
            sortTracks()
            libraryStructureDidChange.send()
            saveLibrary(immediate: true)
        }
    }

    public func saveLibrary(immediate: Bool = false) {
        saveDebounceTask?.cancel()
        let url = Self.libraryURL

        if immediate {
            saveDebounceTask = nil
            let snapshot = tracks
            saveQueue.async {
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(snapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
            return
        }

        saveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self = self else { return }
            let snapshot = self.tracks
            self.saveQueue.async {
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(snapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    public func startSync(folders: [URL], fullRescan: Bool = false) {
        guard !isSyncing else { return }
        isSyncing = true
        isFullRescan = fullRescan
        syncCompletedMessage = nil
        syncStatusText = fullRescan ? "Rescanning all metadata…" : "Scanning folders…"

        if fullRescan {
            LibraryHealthManager.shared.clearAllOverridesAndIgnored()
            MetadataReader.clearArtworkCache()
        }

        let startInstant = ContinuousClock.now

        Task.detached(priority: .utility) {
            let savedOverrides = fullRescan ? [:] : LibraryHealthManager.readOverridesFromDisk()
            let overriddenIds = Set(savedOverrides.keys)
            let storedDRScores = DynamicRangeEngine.readStoredScores()
            var existingMap: [String: Track] = [:]
            var existingByIdMap: [String: Track] = [:]
            var existingPlayCountByPath: [String: Int] = [:]
            if !fullRescan {
                for track in await self.tracks {
                    let stdPath = track.path.standardizedFileURL.path
                    if let pc = track.playCount, pc > (existingPlayCountByPath[stdPath] ?? 0) {
                        existingPlayCountByPath[stdPath] = pc
                    }
                    existingByIdMap[track.id] = track
                    if !track.isCueTrack {
                        existingMap[stdPath] = track
                    }
                }
            }

            var cueURLs: [URL] = []
            var audioURLs: [URL] = []

            for folder in folders {
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }

                let enumerator = FileManager.default.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                while let fileURL = enumerator?.nextObject() as? URL {
                    if fileURL.pathExtension.lowercased() == "cue" {
                        cueURLs.append(fileURL)
                    } else if MetadataReader.isAudioFile(fileURL) {
                        audioURLs.append(fileURL)
                    }
                }
            }

            var discoveredTracks: [Track] = []
            var cueBackingPaths: Set<String> = []
            var checkedCount = 0

            for cueURL in cueURLs {
                let parsed = await CueSheetParser.parse(
                    cueURL: cueURL,
                    existingById: existingByIdMap,
                    overriddenTrackIds: overriddenIds
                )
                if !parsed.tracks.isEmpty {
                    discoveredTracks.append(contentsOf: parsed.tracks)
                    cueBackingPaths.formUnion(parsed.backingFilePaths)
                    checkedCount += parsed.tracks.count
                }
            }

            for fileURL in audioURLs {
                let filePath = fileURL.standardizedFileURL.path
                guard !cueBackingPaths.contains(filePath) else { continue }
                checkedCount += 1

                let fileValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let curSize = fileValues?.fileSize.map { UInt64($0) }
                let curDate = fileValues?.contentModificationDate
                let folderHasArt = MetadataReader.hasFolderArtwork(in: fileURL.deletingLastPathComponent())

                if !fullRescan, var existing = existingMap[filePath],
                   existing.fileSize == curSize,
                   existing.modifiedDate == curDate,
                   existing.trackNumber != nil,
                   (existing.sampleRate ?? 44100) >= 8000,
                   existing.duration > 0 && existing.duration < 86_400,
                   savedOverrides[existing.id] == nil,
                   (!existing.hasCoverArt || folderHasArt) {
                    // Unmodified file with complete track metadata, preserve cached track metadata!
                    if existing.dynamicRange == nil, let cachedDR = storedDRScores[existing.id] {
                        existing.dynamicRange = cachedDR
                    }
                    discoveredTracks.append(existing)
                } else {
                    // New or modified file: read metadata
                    if var track = await MetadataReader.readTrack(at: fileURL) {
                        track.dynamicRange = existingMap[filePath]?.dynamicRange ?? storedDRScores[track.id]
                        let priorPlays = max(existingMap[filePath]?.playCount ?? 0, existingPlayCountByPath[filePath] ?? 0)
                        if priorPlays > 0 {
                            track.playCount = priorPlays
                        }
                        discoveredTracks.append(track)
                    }
                }

                if checkedCount % 25 == 0 {
                    let count = discoveredTracks.count
                    await MainActor.run {
                        self.syncStatusText = fullRescan
                            ? "Rescanned \(count) tracks…"
                            : "Checked \(count) tracks…"
                    }
                }
            }

            // Ensure visual feedback animation stays visible for at least 600ms even on fast SSDs
            let elapsed = ContinuousClock.now - startInstant
            if elapsed < .milliseconds(600) {
                try? await Task.sleep(for: .milliseconds(600) - elapsed)
            }

            await MainActor.run {
                if !fullRescan {
                    for i in discoveredTracks.indices {
                        LibraryHealthManager.applyOverride(from: savedOverrides, to: &discoveredTracks[i])
                    }
                }
                self.tracks = discoveredTracks
                self.sortTracks()
                PlaylistManager.shared.pruneOrphans(validTrackIds: Set(discoveredTracks.map(\.id)))
                self.libraryStructureDidChange.send()
                self.saveLibrary(immediate: true)
                self.isSyncing = false
                self.isFullRescan = false
                self.syncStatusText = ""
                let msg = fullRescan
                    ? "Full rescan complete (\(discoveredTracks.count) tracks)"
                    : "Synced \(discoveredTracks.count) tracks"
                self.syncCompletedMessage = msg

                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if self.syncCompletedMessage == msg {
                        self.syncCompletedMessage = nil
                    }
                }
            }
        }
    }

    public func applyHealthOverrides(using overrides: [String: TrackMetadataOverride]) {
        var updated = tracks
        for i in updated.indices {
            LibraryHealthManager.applyOverride(from: overrides, to: &updated[i])
        }
        self.tracks = updated
        sortTracks()
        libraryStructureDidChange.send()
        saveLibrary(immediate: true)
    }

    public func updateTrackDynamicRange(id: String, score: Int, saveImmediately: Bool = true) {
        if let idx = tracks.firstIndex(where: { $0.id == id }) {
            tracks[idx].dynamicRange = score
            let updated = tracks[idx]
            syncIndexedTrack(updated)
            trackMetadataDidUpdate.send([updated])
            if saveImmediately {
                saveLibrary()
            }
        }
    }

    public func updateTracksDynamicRange(scores: [String: Int]) {
        var updatedTracks: [Track] = []
        for (id, score) in scores {
            if let idx = tracks.firstIndex(where: { $0.id == id }) {
                tracks[idx].dynamicRange = score
                let updated = tracks[idx]
                syncIndexedTrack(updated)
                updatedTracks.append(updated)
            }
        }
        if !updatedTracks.isEmpty {
            trackMetadataDidUpdate.send(updatedTracks)
            saveLibrary()
        }
    }

    public func incrementPlayCount(for trackId: String) {
        if let idx = tracks.firstIndex(where: { $0.id == trackId }) {
            let current = tracks[idx].playCount ?? 0
            tracks[idx].playCount = current + 1
            let updated = tracks[idx]
            syncIndexedTrack(updated)
            trackMetadataDidUpdate.send([updated])
            saveLibrary()
        }
    }

    private func syncIndexedTrack(_ updated: Track) {
        tracksById[updated.id] = updated

        let artist = updated.displayArtist
        if var list = tracksByArtistMap[artist],
           let i = list.firstIndex(where: { $0.id == updated.id }) {
            list[i] = updated
            tracksByArtistMap[artist] = list
        }
        let albumArtist = updated.displayAlbumArtist
        if albumArtist != artist,
           var list = tracksByArtistMap[albumArtist],
           let i = list.firstIndex(where: { $0.id == updated.id }) {
            list[i] = updated
            tracksByArtistMap[albumArtist] = list
        }

        let album = updated.displayAlbum
        let key1 = "\(artist)\0\(album)"
        if var list = tracksByArtistAndAlbumMap[key1],
           let i = list.firstIndex(where: { $0.id == updated.id }) {
            list[i] = updated
            tracksByArtistAndAlbumMap[key1] = list
        }
        if albumArtist != artist {
            let key2 = "\(albumArtist)\0\(album)"
            if var list = tracksByArtistAndAlbumMap[key2],
               let i = list.firstIndex(where: { $0.id == updated.id }) {
                list[i] = updated
                tracksByArtistAndAlbumMap[key2] = list
            }
        }
    }

    public func clearAllData() {
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        tracks.removeAll()
        rebuildIndexes()
        MetadataReader.clearArtworkCache()
        libraryStructureDidChange.send()
        let url = Self.libraryURL
        try? FileManager.default.removeItem(at: url)
    }

    public func removeTrack(id: String) {
        tracks.removeAll { $0.id == id }
        sortTracks()
        libraryStructureDidChange.send()
        saveLibrary(immediate: true)
    }

    public func track(forId id: String) -> Track? {
        tracksById[id]
    }

    public func trackCount(for artist: String) -> Int {
        trackCountByArtistMap[artist] ?? 0
    }

    public func albums(for artist: String) -> [String] {
        albumsByArtistMap[artist] ?? []
    }

    public func albumYear(for artist: String, album: String) -> Int? {
        albumYearByArtistAndAlbumMap["\(artist)\0\(album)"]
    }

    public func albumReleaseDate(for artist: String, album: String) -> String? {
        albumReleaseDateByArtistAndAlbumMap["\(artist)\0\(album)"]?.formattedString
            ?? albumYearByArtistAndAlbumMap["\(artist)\0\(album)"].map { String($0) }
    }

    public func tracks(for artist: String, album: String? = nil) -> [Track] {
        if let alb = album {
            return tracksByArtistAndAlbumMap["\(artist)\0\(alb)"] ?? []
        }
        return tracksByArtistMap[artist] ?? []
    }

    public struct AlbumInfo: Identifiable, Hashable, Sendable {
        public var id: String { "\(artist)_\(title)" }
        public let title: String
        public let artist: String
        public let year: Int?
        public let releaseDate: String?
        public let parsedReleaseDate: ParsedReleaseDate?
        public let trackCount: Int
        public let sampleTrack: Track

        public var formattedReleaseDate: String? {
            parsedReleaseDate?.formattedString ?? year.map { String($0) }
        }
    }

    public func rebuildIndexes() {
        var byId: [String: Track] = [:]
        byId.reserveCapacity(tracks.count)

        var seenArtists = Set<String>()
        var artistsList: [String] = []
        var albumDict: [String: [Track]] = [:]

        var artistAlbumsSet: [String: Set<String>] = [:]
        var artistAlbumTracks: [String: [Track]] = [:]

        for track in tracks {
            byId[track.id] = track

            let artist = track.displayArtist
            if !seenArtists.contains(artist) && UUID(uuidString: artist) == nil {
                seenArtists.insert(artist)
                artistsList.append(artist)
            }

            let album = track.displayAlbum
            let albumArtist = track.displayAlbumArtist
            let key = "\(album)___\(albumArtist)"
            albumDict[key, default: []].append(track)

            artistAlbumsSet[artist, default: []].insert(album)
            artistAlbumTracks["\(artist)\0\(album)", default: []].append(track)

            if albumArtist != artist {
                artistAlbumsSet[albumArtist, default: []].insert(album)
                artistAlbumTracks["\(albumArtist)\0\(album)", default: []].append(track)
            }
        }

        self.tracksById = byId
        self.uniqueArtists = artistsList.sorted { Self.compareArtists($0, $1) }

        let albumTrackSort: (Track, Track) -> Bool = { a, b in
            if (a.discNumber ?? 1) != (b.discNumber ?? 1) {
                return (a.discNumber ?? 1) < (b.discNumber ?? 1)
            }
            if (a.trackNumber ?? 0) != (b.trackNumber ?? 0) {
                return (a.trackNumber ?? 0) < (b.trackNumber ?? 0)
            }
            return a.titleSortKey < b.titleSortKey
        }

        var albumYearByArtistAndAlbum: [String: Int] = [:]
        albumYearByArtistAndAlbum.reserveCapacity(artistAlbumTracks.count)
        var albumReleaseDateByArtistAndAlbum: [String: ParsedReleaseDate] = [:]
        albumReleaseDateByArtistAndAlbum.reserveCapacity(artistAlbumTracks.count)
        for (key, list) in artistAlbumTracks {
            let sorted = list.sorted(by: albumTrackSort)
            artistAlbumTracks[key] = sorted
            if let bestDate = ParsedReleaseDate.best(from: sorted.compactMap(\.parsedReleaseDate)) {
                albumReleaseDateByArtistAndAlbum[key] = bestDate
                albumYearByArtistAndAlbum[key] = bestDate.year
            }
        }
        self.tracksByArtistAndAlbumMap = artistAlbumTracks
        self.albumYearByArtistAndAlbumMap = albumYearByArtistAndAlbum
        self.albumReleaseDateByArtistAndAlbumMap = albumReleaseDateByArtistAndAlbum

        var sortedAlbumsByArtist: [String: [String]] = [:]
        sortedAlbumsByArtist.reserveCapacity(artistAlbumsSet.count)
        for (artist, albumSet) in artistAlbumsSet {
            sortedAlbumsByArtist[artist] = albumSet.sorted { albumA, albumB in
                let dateCmp = ParsedReleaseDate.compare(
                    albumReleaseDateByArtistAndAlbum["\(artist)\0\(albumA)"],
                    albumReleaseDateByArtistAndAlbum["\(artist)\0\(albumB)"]
                )
                if dateCmp != .orderedSame {
                    return dateCmp == .orderedAscending
                }
                let titleCmp = albumA.localizedCaseInsensitiveCompare(albumB)
                if titleCmp != .orderedSame {
                    return titleCmp == .orderedAscending
                }
                return albumA < albumB
            }
        }
        self.albumsByArtistMap = sortedAlbumsByArtist

        var counts: [String: Int] = [:]
        counts.reserveCapacity(sortedAlbumsByArtist.count)
        var orderedArtistTracks: [String: [Track]] = [:]
        orderedArtistTracks.reserveCapacity(sortedAlbumsByArtist.count)
        for (artist, orderedAlbums) in sortedAlbumsByArtist {
            var combined: [Track] = []
            for album in orderedAlbums {
                if let albumTracks = artistAlbumTracks["\(artist)\0\(album)"] {
                    combined.append(contentsOf: albumTracks)
                }
            }
            counts[artist] = combined.count
            orderedArtistTracks[artist] = combined
        }
        self.trackCountByArtistMap = counts
        self.tracksByArtistMap = orderedArtistTracks

        var albumList: [AlbumInfo] = []
        albumList.reserveCapacity(albumDict.count)
        for (_, trackList) in albumDict {
            guard let first = trackList.first else { continue }
            let title = first.displayAlbum
            let rawArtist = first.displayAlbumArtist
            let artist = (UUID(uuidString: rawArtist) != nil) ? first.displayArtist : rawArtist
            let bestDate = ParsedReleaseDate.best(from: trackList.compactMap(\.parsedReleaseDate))
            albumList.append(AlbumInfo(
                title: title,
                artist: artist,
                year: bestDate?.year,
                releaseDate: bestDate?.formattedString,
                parsedReleaseDate: bestDate,
                trackCount: trackList.count,
                sampleTrack: first
            ))
        }

        self.allAlbums = albumList.sorted { (a: AlbumInfo, b: AlbumInfo) -> Bool in
            if a.artist != b.artist {
                return Self.compareArtists(a.artist, b.artist)
            }
            let dateCmp = ParsedReleaseDate.compare(a.parsedReleaseDate, b.parsedReleaseDate)
            if dateCmp != .orderedSame {
                return dateCmp == .orderedAscending
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        self.allAlbumsByTitle = albumList.sorted { (a: AlbumInfo, b: AlbumInfo) -> Bool in
            let titleCmp = a.title.localizedCaseInsensitiveCompare(b.title)
            if titleCmp != .orderedSame {
                return titleCmp == .orderedAscending
            }
            return Self.compareArtists(a.artist, b.artist)
        }

        self.allAlbumsByYear = albumList.sorted { (a: AlbumInfo, b: AlbumInfo) -> Bool in
            let dateCmp = ParsedReleaseDate.compare(a.parsedReleaseDate, b.parsedReleaseDate)
            if dateCmp != .orderedSame {
                return dateCmp == .orderedAscending
            }
            if a.artist != b.artist {
                return Self.compareArtists(a.artist, b.artist)
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}
