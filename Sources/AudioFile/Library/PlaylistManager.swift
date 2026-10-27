import Foundation
import Combine
import AppKit

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
}
