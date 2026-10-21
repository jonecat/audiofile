import Foundation
import Combine

@MainActor
public final class LibraryManager: ObservableObject {
    public static let shared = LibraryManager()

    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var uniqueArtists: [String] = []
    @Published public private(set) var allAlbums: [AlbumInfo] = []
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var syncStatusText: String = ""

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
            let artistA = a.displayArtist
            let artistB = b.displayArtist
            if artistA != artistB {
                return Self.compareArtists(artistA, artistB)
            }
            let albumCmp = a.displayAlbum.localizedCaseInsensitiveCompare(b.displayAlbum)
            if albumCmp != .orderedSame {
                return albumCmp == .orderedAscending
            }
            if (a.discNumber ?? 1) != (b.discNumber ?? 1) {
                return (a.discNumber ?? 1) < (b.discNumber ?? 1)
            }
            if (a.trackNumber ?? 0) != (b.trackNumber ?? 0) {
                return (a.trackNumber ?? 0) < (b.trackNumber ?? 0)
            }
            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
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
            self.tracks = loaded
            sortTracks()
            if modified {
                saveLibrary()
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
            saveLibrary()
        }
    }

    public func saveLibrary() {
        let url = Self.libraryURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(tracks) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func startSync(folders: [URL], fullRescan: Bool = false) {
        guard !isSyncing else { return }
        isSyncing = true
        syncStatusText = "Scanning folders..."

        Task.detached(priority: .utility) {
            var existingMap: [String: Track] = [:]
            if !fullRescan {
                for track in await self.tracks {
                    existingMap[track.path.standardizedFileURL.path] = track
                }
            }

            var discoveredTracks: [Track] = []
            var checkedCount = 0

            for folder in folders {
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }

                let enumerator = FileManager.default.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                while let fileURL = enumerator?.nextObject() as? URL {
                    guard MetadataReader.isAudioFile(fileURL) else { continue }
                    checkedCount += 1

                    let filePath = fileURL.standardizedFileURL.path
                    let fileValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let curSize = fileValues?.fileSize.map { UInt64($0) }
                    let curDate = fileValues?.contentModificationDate

                    if !fullRescan, let existing = existingMap[filePath],
                       existing.fileSize == curSize,
                       existing.modifiedDate == curDate,
                       existing.trackNumber != nil,
                       (existing.sampleRate ?? 44100) >= 8000,
                       existing.duration > 0 && existing.duration < 86_400 {
                        // Unmodified file with complete track metadata, preserve cached track metadata!
                        discoveredTracks.append(existing)
                    } else {
                        // New or modified file: read metadata
                        if let track = await MetadataReader.readTrack(at: fileURL) {
                            discoveredTracks.append(track)
                        }
                    }

                    if checkedCount % 25 == 0 {
                        let count = discoveredTracks.count
                        await MainActor.run {
                            self.syncStatusText = "Found \(count) tracks..."
                        }
                    }
                }
            }

            await MainActor.run {
                self.tracks = discoveredTracks
                self.sortTracks()
                self.saveLibrary()
                self.isSyncing = false
                self.syncStatusText = ""
            }
        }
    }


    public func albums(for artist: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for track in tracks where track.displayArtist == artist || track.displayAlbumArtist == artist {
            let album = track.displayAlbum
            if !seen.contains(album) {
                seen.insert(album)
                result.append(album)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func tracks(for artist: String, album: String? = nil) -> [Track] {
        let filtered = tracks.filter { track in
            let matchArtist = (track.displayArtist == artist || track.displayAlbumArtist == artist)
            if let alb = album {
                return matchArtist && track.displayAlbum == alb
            }
            return matchArtist
        }
        return filtered.sorted { a, b in
            let albumCmp = a.displayAlbum.localizedCaseInsensitiveCompare(b.displayAlbum)
            if albumCmp != .orderedSame {
                return albumCmp == .orderedAscending
            }
            if (a.discNumber ?? 1) != (b.discNumber ?? 1) {
                return (a.discNumber ?? 1) < (b.discNumber ?? 1)
            }
            if (a.trackNumber ?? 0) != (b.trackNumber ?? 0) {
                return (a.trackNumber ?? 0) < (b.trackNumber ?? 0)
            }
            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        }
    }

    public struct AlbumInfo: Identifiable, Hashable, Sendable {
        public var id: String { "\(artist)_\(title)" }
        public let title: String
        public let artist: String
        public let year: Int?
        public let trackCount: Int
        public let sampleTrack: Track
    }

    public func rebuildIndexes() {
        var seenArtists = Set<String>()
        var artistsList: [String] = []
        var albumDict: [String: [Track]] = [:]

        for track in tracks {
            let artist = track.displayArtist
            if !seenArtists.contains(artist) && UUID(uuidString: artist) == nil {
                seenArtists.insert(artist)
                artistsList.append(artist)
            }
            let key = "\(track.displayAlbum)___\(track.displayAlbumArtist)"
            albumDict[key, default: []].append(track)
        }

        self.uniqueArtists = artistsList.sorted { Self.compareArtists($0, $1) }

        var albumList: [AlbumInfo] = []
        for (_, trackList) in albumDict {
            guard let first = trackList.first else { continue }
            let title = first.displayAlbum
            let rawArtist = first.displayAlbumArtist
            let artist = (UUID(uuidString: rawArtist) != nil) ? first.displayArtist : rawArtist
            let year = trackList.compactMap(\.year).first
            albumList.append(AlbumInfo(
                title: title,
                artist: artist,
                year: year,
                trackCount: trackList.count,
                sampleTrack: first
            ))
        }

        self.allAlbums = albumList.sorted { (a: AlbumInfo, b: AlbumInfo) -> Bool in
            let cmp = Self.compareArtists(a.artist, b.artist)
            if a.artist != b.artist {
                return cmp
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}
