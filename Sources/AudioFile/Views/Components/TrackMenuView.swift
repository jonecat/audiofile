import SwiftUI
import AppKit

public struct TrackMenuItems: View {
    public let vm: PlayerViewModel
    private let explicitTracks: [Track]?
    private let singleTrack: Track?
    private let useSelectionIfHighlighted: Bool
    public let trackListProvider: () -> [Track]
    public var removeAction: (() -> Void)? = nil

    public var track: Track? {
        explicitTracks?.first ?? singleTrack
    }

    public init(
        vm: PlayerViewModel,
        track: Track,
        trackList: [Track],
        removeAction: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.explicitTracks = [track]
        self.singleTrack = track
        self.useSelectionIfHighlighted = false
        self.trackListProvider = { trackList }
        self.removeAction = removeAction
    }

    public init(
        vm: PlayerViewModel,
        tracks: [Track],
        trackList: [Track],
        removeAction: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.explicitTracks = tracks
        self.singleTrack = tracks.first
        self.useSelectionIfHighlighted = false
        self.trackListProvider = { trackList }
        self.removeAction = removeAction
    }

    public init(
        vm: PlayerViewModel,
        tracks: [Track],
        trackListProvider: @escaping () -> [Track],
        removeAction: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.explicitTracks = tracks
        self.singleTrack = tracks.first
        self.useSelectionIfHighlighted = false
        self.trackListProvider = trackListProvider
        self.removeAction = removeAction
    }

    public init(
        vm: PlayerViewModel,
        track: Track,
        useSelectionIfHighlighted: Bool,
        trackListProvider: @escaping () -> [Track],
        removeAction: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.explicitTracks = nil
        self.singleTrack = track
        self.useSelectionIfHighlighted = useSelectionIfHighlighted
        self.trackListProvider = trackListProvider
        self.removeAction = removeAction
    }

    @ViewBuilder
    public var body: some View {
        if let tracks = explicitTracks {
            if tracks.count == 1, let single = tracks.first {
                singleTrackBody(single)
            } else if tracks.count > 1 {
                multiTrackBody(
                    trackIds: tracks.map(\.id),
                    resolveTracks: { tracks }
                )
            }
        } else if let single = singleTrack {
            if useSelectionIfHighlighted,
               vm.selectedTrackIds.count > 1,
               vm.selectedTrackIds.contains(single.id) {
                let selectedIds = vm.selectedTrackIds
                let orderedIds = Array(selectedIds)
                multiTrackBody(
                    trackIds: orderedIds,
                    resolveTracks: {
                        let list = trackListProvider()
                        let matched = list.filter { selectedIds.contains($0.id) }
                        return matched.isEmpty ? [single] : matched
                    }
                )
            } else {
                singleTrackBody(single)
            }
        }
    }

    @ViewBuilder
    private func singleTrackBody(_ track: Track) -> some View {
        Button("Play") {
            vm.playTrack(track, in: trackListProvider())
        }

        Button("Play Next") {
            vm.playTrackNext(track)
        }

        Button("Add to Queue") {
            vm.addTrackToEndOfQueue(track)
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

        Button("Measure Dynamic Range") {
            Task {
                _ = await DynamicRangeEngine.shared.dynamicRange(for: track, forceRecalculate: true)
            }
        }

        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([track.path])
        }
    }

    @ViewBuilder
    private func multiTrackBody(
        trackIds: [String],
        resolveTracks: @escaping () -> [Track]
    ) -> some View {
        let count = trackIds.count
        let allFavorites = trackIds.allSatisfy { vm.playlists.isFavorite(trackId: $0) }

        Button("Play (\(count) Songs)") {
            let list = trackListProvider()
            let resolved = resolveTracks()
            if let first = resolved.first {
                vm.playTrack(first, in: list)
            }
        }

        Button("Play Next (\(count) Songs)") {
            vm.playTracksNext(resolveTracks())
        }

        Button("Add to Queue (\(count) Songs)") {
            vm.addTracksToEndOfQueue(resolveTracks())
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

        Button("Measure Dynamic Range (\(count) Songs)") {
            let resolved = resolveTracks()
            Task {
                for t in resolved {
                    _ = await DynamicRangeEngine.shared.dynamicRange(for: t, forceRecalculate: true)
                }
            }
        }

        Button("Show in Finder (\(count) Files)") {
            let resolved = resolveTracks()
            NSWorkspace.shared.activateFileViewerSelecting(resolved.map(\.path))
        }
    }
}

public struct TrackKebabMenuButton: View {
    public let vm: PlayerViewModel
    public let track: Track
    public let trackListProvider: () -> [Track]
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
        self.trackListProvider = { trackList }
        self.isHighlighted = isHighlighted
        self.removeAction = removeAction
    }

    public init(
        vm: PlayerViewModel,
        track: Track,
        isHighlighted: Bool = false,
        removeAction: (() -> Void)? = nil,
        trackListProvider: @escaping () -> [Track]
    ) {
        self.vm = vm
        self.track = track
        self.trackListProvider = trackListProvider
        self.isHighlighted = isHighlighted
        self.removeAction = removeAction
    }

    public var body: some View {
        Menu {
            TrackMenuItems(
                vm: vm,
                track: track,
                useSelectionIfHighlighted: isHighlighted,
                trackListProvider: trackListProvider,
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
