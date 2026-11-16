import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
public final class PlaylistManager: ObservableObject {
    public static let shared = PlaylistManager()

    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var favorites: Set<String> = []
    @Published public private(set) var recentlyPlayed: [String] = []
    @Published public var draggedPlaylist: Playlist?
    @Published public var draggedTrack: Track?
    @Published public var dropTargetPlaylistId: String?
    @Published public var dropTargetTrackId: String?

    public func clearDragState() {
        draggedPlaylist = nil
        draggedTrack = nil
        dropTargetPlaylistId = nil
        dropTargetTrackId = nil
    }

    public func cleanupDragIfMouseUp() {
        if NSEvent.pressedMouseButtons == 0 {
            if draggedPlaylist != nil || draggedTrack != nil || dropTargetPlaylistId != nil || dropTargetTrackId != nil {
                clearDragState()
            }
        }
    }

    private static var playlistsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AudioFile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("playlists.json")
    }

    public init() {
        load()
    }

    public func load() {
        let url = Self.playlistsURL
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(PlaylistsData.self, from: data) {
            self.playlists = decoded.playlists
            self.favorites = Set(decoded.favorites)
            self.recentlyPlayed = decoded.recentlyPlayed
            return
        }

        // Fallback: check omaflac playlists.json in ~/.config/omaflac/playlists.json
        let omaflacURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omaflac/playlists.json")
        if let data = try? Data(contentsOf: omaflacURL),
           let decoded = try? JSONDecoder().decode(PlaylistsData.self, from: data) {
            self.playlists = decoded.playlists
            self.favorites = Set(decoded.favorites)
            self.recentlyPlayed = decoded.recentlyPlayed
            save()
        }
    }

    public func save() {
        let url = Self.playlistsURL
        let dataModel = PlaylistsData(
            playlists: playlists,
            favorites: Array(favorites),
            recentlyPlayed: recentlyPlayed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(dataModel) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func isFavorite(trackId: String) -> Bool {
        favorites.contains(trackId)
    }

    public func toggleFavorite(trackId: String) {
        if favorites.contains(trackId) {
            favorites.remove(trackId)
        } else {
            favorites.insert(trackId)
        }
        save()
    }

    public func addFavorites(trackIds: [String]) {
        var changed = false
        for id in trackIds {
            if !favorites.contains(id) {
                favorites.insert(id)
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    public func removeFavorites(trackIds: [String]) {
        var changed = false
        for id in trackIds {
            if favorites.contains(id) {
                favorites.remove(id)
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    public func recordPlayed(trackId: String) {
        recentlyPlayed.removeAll { $0 == trackId }
        recentlyPlayed.insert(trackId, at: 0)
        if recentlyPlayed.count > 100 {
            recentlyPlayed = Array(recentlyPlayed.prefix(100))
        }
        save()
        LibraryManager.shared.incrementPlayCount(for: trackId)
    }

    public func clearAllData() {
        playlists.removeAll()
        favorites.removeAll()
        recentlyPlayed.removeAll()
        save()
    }

    public func createPlaylist(name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "New Playlist" : trimmed
        let pl = Playlist(name: finalName)
        playlists.append(pl)
        save()
        return pl
    }

    public func deletePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    public func movePlaylists(from source: IndexSet, to destination: Int) {
        playlists.move(fromOffsets: source, toOffset: destination)
        save()
    }

    public func moveTracks(in playlistId: String, from source: IndexSet, to destination: Int) {
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            playlists[idx].trackIds.move(fromOffsets: source, toOffset: destination)
            save()
        }
    }

    public func renamePlaylist(id: String, newName: String) {
        if let idx = playlists.firstIndex(where: { $0.id == id }) {
            playlists[idx].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            save()
        }
    }

    public func addTrack(to playlistId: String, trackId: String) {
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            if !playlists[idx].trackIds.contains(trackId) {
                playlists[idx].trackIds.append(trackId)
                save()
            }
        }
    }

    public func addTracks(to playlistId: String, trackIds: [String]) {
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            var changed = false
            for trackId in trackIds {
                if !playlists[idx].trackIds.contains(trackId) {
                    playlists[idx].trackIds.append(trackId)
                    changed = true
                }
            }
            if changed {
                save()
            }
        }
    }

    public func removeTracks(from playlistId: String, trackIds: [String]) {
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let idSet = Set(trackIds)
            let prevCount = playlists[idx].trackIds.count
            playlists[idx].trackIds.removeAll { idSet.contains($0) }
            if playlists[idx].trackIds.count != prevCount {
                save()
            }
        }
    }

    public func removeTrack(from playlistId: String, at index: Int) {
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            if index < playlists[idx].trackIds.count {
                playlists[idx].trackIds.remove(at: index)
                save()
            }
        }
    }

    public func pruneOrphans(validTrackIds: Set<String>) {
        let beforeFavs = favorites.count
        favorites = favorites.filter { validTrackIds.contains($0) }
        let beforeRecent = recentlyPlayed.count
        recentlyPlayed = recentlyPlayed.filter { validTrackIds.contains($0) }
        if favorites.count != beforeFavs || recentlyPlayed.count != beforeRecent {
            save()
        }
    }

    // MARK: - M3U / M3U8 Import & Export

    public func exportM3U8(playlist: Playlist, to destinationURL: URL, library: LibraryManager) throws {
        var lines: [String] = ["#EXTM3U", "#PLAYLIST:\(playlist.name)"]
        for trackId in playlist.trackIds {
            guard let track = library.tracksById[trackId] else { continue }
            let durationSec = max(0, Int(track.duration.rounded()))
            lines.append("#EXTINF:\(durationSec),\(track.displayArtist) - \(track.displayTitle)")
            lines.append(track.path.path)
        }
        let output = lines.joined(separator: "\n") + "\n"
        try output.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    @discardableResult
    public func importM3U(from sourceURL: URL, library: LibraryManager) -> Playlist? {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        var text: String?
        for encoding in [String.Encoding.utf8, .isoLatin1, .windowsCP1252] {
            if let decoded = String(data: data, encoding: encoding) {
                text = decoded
                break
            }
        }
        guard var rawText = text else { return nil }
        if rawText.hasPrefix("\u{FEFF}") {
            rawText.removeFirst()
        }

        let baseDir = sourceURL.deletingLastPathComponent()
        var parsedName = sourceURL.deletingPathExtension().lastPathComponent
        var rawEntries: [String] = []

        for line in rawText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.uppercased().hasPrefix("#PLAYLIST:") {
                let candidate = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    parsedName = candidate
                }
                continue
            }
            if trimmed.hasPrefix("#") { continue }
            rawEntries.append(trimmed)
        }

        // Index library paths (exact, lowercased, and filename fallback)
        var byExactPath: [String: Track] = [:]
        var byLowerPath: [String: Track] = [:]
        var byFilename: [String: [Track]] = [:]

        for track in library.tracks {
            let stdPath = track.path.standardizedFileURL.path
            if byExactPath[stdPath] == nil {
                byExactPath[stdPath] = track
            }
            let lower = stdPath.lowercased()
            if byLowerPath[lower] == nil {
                byLowerPath[lower] = track
            }
            byFilename[track.path.lastPathComponent.lowercased(), default: []].append(track)
        }

        var matchedTrackIds: [String] = []
        var seenIds = Set<String>()

        for entry in rawEntries {
            let resolvedURL: URL
            if entry.lowercased().hasPrefix("file://"), let fileURL = URL(string: entry) {
                resolvedURL = fileURL.standardizedFileURL
            } else {
                let normalized = entry.replacingOccurrences(of: "\\", with: "/")
                if normalized.hasPrefix("/") {
                    resolvedURL = URL(fileURLWithPath: normalized).standardizedFileURL
                } else {
                    resolvedURL = baseDir.appendingPathComponent(normalized).standardizedFileURL
                }
            }

            let candidatePath = resolvedURL.path
            let matchedTrack = byExactPath[candidatePath]
                ?? byLowerPath[candidatePath.lowercased()]
                ?? byFilename[resolvedURL.lastPathComponent.lowercased()]?.first

            if let track = matchedTrack, seenIds.insert(track.id).inserted {
                matchedTrackIds.append(track.id)
            }
        }

        let created = createPlaylist(name: parsedName)
        if !matchedTrackIds.isEmpty {
            addTracks(to: created.id, trackIds: matchedTrackIds)
        }
        return playlists.first(where: { $0.id == created.id }) ?? created
    }

    @discardableResult
    public func promptImportM3U(library: LibraryManager) -> Playlist? {
        let panel = NSOpenPanel()
        panel.title = "Import Playlist"
        panel.message = "Choose an .m3u or .m3u8 playlist file to import into AudioFile"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let m3uTypes = ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        if !m3uTypes.isEmpty {
            panel.allowedContentTypes = m3uTypes
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return importM3U(from: url, library: library)
    }

    public func promptExportM3U(playlist: Playlist, library: LibraryManager) {
        let panel = NSSavePanel()
        panel.title = "Export Playlist"
        let safeName = playlist.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(safeName.isEmpty ? "Playlist" : safeName).m3u8"
        if let m3u8Type = UTType(filenameExtension: "m3u8") {
            panel.allowedContentTypes = [m3u8Type]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exportM3U8(playlist: playlist, to: url, library: library)
    }
}
