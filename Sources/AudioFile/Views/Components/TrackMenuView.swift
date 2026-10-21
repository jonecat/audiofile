import SwiftUI
import AppKit

public struct TrackMenuItems: View {
    @ObservedObject var vm: PlayerViewModel
    public let track: Track
    public let trackList: [Track]
    public var removeAction: (() -> Void)? = nil

    public init(
        vm: PlayerViewModel,
        track: Track,
        trackList: [Track],
        removeAction: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.track = track
        self.trackList = trackList
        self.removeAction = removeAction
    }

    public var body: some View {
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
                        vm.playlists.addTrack(to: pl.id, trackId: track.id)
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
        Menu {
            TrackMenuItems(
                vm: vm,
                track: track,
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
