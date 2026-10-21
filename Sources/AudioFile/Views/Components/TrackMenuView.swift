import SwiftUI
import AppKit

public struct TrackMenuItems: View {
    @ObservedObject var vm: PlayerViewModel
    public let tracks: [Track]
    public let trackList: [Track]
    public var removeAction: (() -> Void)? = nil

    public var track: Track? {
        tracks.first
    }

    public init(
        vm: PlayerViewModel,
        track: Track,
        trackList: [Track],
        removeAction: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.tracks = [track]
        self.trackList = trackList
        self.removeAction = removeAction
    }

    public init(
        vm: PlayerViewModel,
        tracks: [Track],
        trackList: [Track],
        removeAction: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.tracks = tracks
        self.trackList = trackList
        self.removeAction = removeAction
    }

    @ViewBuilder
    public var body: some View {
        if tracks.count == 1, let single = tracks.first {
            singleTrackBody(single)
        } else if tracks.count > 1 {
            multiTrackBody
        }
    }

    @ViewBuilder
    private func singleTrackBody(_ track: Track) -> some View {
        Button("Play") {
            vm.playTrack(track, in: trackList)
        }

        Button("Play Next") {
            if let cur = vm.audio.currentTrack,
               let idx = vm.queue.firstIndex(where: { $0.id == cur.id }) {
                vm.queue.insert(track, at: idx + 1)
            } else {
                vm.queue.append(track)
            }
        }

        Divider()

        Button(vm.playlists.isFavorite(trackId: track.id) ? "Remove Favorite" : "Favorite") {
            vm.toggleFavorite(track: track)
        }

        Menu("Add to Playlist") {
            if vm.playlists.playlists.isEmpty {
                Text("No Playlists")
            } else {
                ForEach(vm.playlists.playlists) { pl in
                    Button(pl.name) {
                        vm.addTrackToPlaylist(track: track, playlistId: pl.id)
                    }
                }
            }
        }

        if let removeAction {
            Divider()
            Button("Remove from Playlist", role: .destructive) {
                removeAction()
            }
        }

        Divider()

        Button("View / Edit Metadata…") {
            vm.beginInspectingMetadata(for: track)
        }

        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([track.path])
        }
    }

    @ViewBuilder
    private var multiTrackBody: some View {
        let count = tracks.count
        let trackIds = tracks.map(\.id)
        let allFavorites = trackIds.allSatisfy { vm.playlists.isFavorite(trackId: $0) }

        Button("Play (\(count) Songs)") {
            if let first = tracks.first {
                vm.playTrack(first, in: trackList)
            }
        }

        Button("Play Next (\(count) Songs)") {
            if let cur = vm.audio.currentTrack,
               let idx = vm.queue.firstIndex(where: { $0.id == cur.id }) {
                vm.queue.insert(contentsOf: tracks, at: idx + 1)
            } else {
                vm.queue.append(contentsOf: tracks)
            }
        }

        Divider()

        Button(allFavorites ? "Remove from Favorites (\(count))" : "Add to Favorites (\(count))") {
            vm.toggleFavorite(trackIds: trackIds)
        }

        Menu("Add to Playlist (\(count) Songs)") {
            if vm.playlists.playlists.isEmpty {
                Text("No Playlists")
            } else {
                ForEach(vm.playlists.playlists) { pl in
                    Button(pl.name) {
                        vm.addTracksToPlaylist(trackIds: trackIds, playlistId: pl.id)
                    }
                }
            }
        }

        if let removeAction {
            Divider()
            Button("Remove from Playlist (\(count))", role: .destructive) {
                removeAction()
            }
        }

        Divider()

        Button("Show in Finder (\(count) Files)") {
            NSWorkspace.shared.activateFileViewerSelecting(tracks.map(\.path))
        }
    }
}

public struct TrackKebabMenuButton: View {
    @ObservedObject var vm: PlayerViewModel
    public let track: Track
    public let trackList: [Track]
    public var isHighlighted: Bool = false
    public var removeAction: (() -> Void)? = nil

    public init(
        vm: PlayerViewModel,
        track: Track,
        trackList: [Track],
        isHighlighted: Bool = false,
        removeAction: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.track = track
        self.trackList = trackList
        self.isHighlighted = isHighlighted
        self.removeAction = removeAction
    }

    public var body: some View {
        let tracksForMenu: [Track] = {
            if vm.selectedTrackIds.contains(track.id) && vm.selectedTrackIds.count > 1 {
                return trackList.filter { vm.selectedTrackIds.contains($0.id) }
            }
            return [track]
        }()

        Menu {
            TrackMenuItems(
                vm: vm,
                tracks: tracksForMenu,
                trackList: trackList,
                removeAction: removeAction
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Track Options")
    }
}
