import SwiftUI
import UniformTypeIdentifiers

public struct PlaylistsView: View {
    @ObservedObject var vm: PlayerViewModel
    public let section: NavigationSection

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(headerGradient)
                        .frame(width: 54, height: 54)
                    Image(systemName: headerIcon)
                        .font(.title2)
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.bold))

                    Text("\(currentTracks.count) tracks")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if !currentTracks.isEmpty {
                            Button {
                                if let first = currentTracks.first {
                                    vm.playTrack(first, in: currentTracks)
                                }
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .buttonStyle(.glassProminent)
                            .help("Play \(title)")

                            Button {
                                var shuffled = currentTracks
                                shuffled.shuffle()
                                if let first = shuffled.first {
                                    vm.playTrack(first, in: shuffled)
                                }
                            } label: {
                                Image(systemName: "shuffle")
                            }
                            .buttonStyle(.glass)
                            .help("Shuffle Playlist")
                        }

                        if case .playlist(let playlistId) = section,
                           let playlist = vm.playlists.playlists.first(where: { $0.id == playlistId }) {
                            Button(role: .destructive) {
                                vm.playlistPendingDeletion = playlist
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.glass)
                            .help("Delete Playlist")
                        }
                    }
                }
            }
            .padding(16)
            .glassEffect(.clear, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Tracks Table / List
            if currentTracks.isEmpty {
                ContentUnavailableView(
                    "Playlist is Empty",
                    systemImage: "music.note.list",
                    description: Text("Add songs to this playlist from Songs, Artists, or Albums")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let customPlaylistId: String? = {
                    if case .playlist(let id) = section { return id }
                    return nil
                }()

                List(selection: $vm.selectedTrackIds) {
                    ForEach(Array(currentTracks.enumerated()), id: \.element.id) { index, track in
                        let isPlaying = (vm.audio.currentTrack?.id == track.id)
                        let isSelected = vm.selectedTrackIds.contains(track.id)
                        let isDragged = (vm.playlists.draggedTrack?.id == track.id)
                        let isDropTarget = (vm.playlists.dropTargetTrackId == track.id && !isDragged)

                        HStack(spacing: 12) {
                            if customPlaylistId != nil {
                                DragHandleView(helpText: "Drag to reorder track in playlist")
                                    .onDrag({
                                        vm.playlists.draggedTrack = track
                                        return NSItemProvider(object: track.id as NSString)
                                    }) {
                                        HStack(spacing: 10) {
                                            Image(systemName: "music.note")
                                                .foregroundColor(.accentColor)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(track.displayTitle)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)
                                                Text(track.displayArtist)
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(nsColor: .windowBackgroundColor))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                                                )
                                                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                                        )
                                    }
                            }

                            Text("\(index + 1)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                .frame(width: 24, alignment: .trailing)

                            ArtworkView(track: track, cornerRadius: 4, shadowRadius: 0)
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(track.displayTitle)
                                        .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Color.white : (isPlaying ? Color.accentColor : Color.primary))
                                        .lineLimit(1)

                                    if vm.playlists.isFavorite(trackId: track.id) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.accentColor)
                                    }
                                }

                                Text(track.displayArtist + " • " + track.displayAlbum)
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            // Play Count Metric
                            let plays = track.playCount ?? 0
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 7))
                                Text("\(plays)")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : (plays > 0 ? Color.secondary : Color.secondary.opacity(0.35)))
                            .help("\(plays) \(plays == 1 ? "play" : "plays")")
                            .frame(minWidth: 28, alignment: .trailing)

                            if let score = track.dynamicRange {
                                DynamicRangeBadgeView(score: score, compact: true, isHighlighted: isSelected)
                            }

                            FormatBadgeView(format: track.format, isLossless: track.isLossless, isHighlighted: isSelected)

                            Text(track.formattedDuration)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)

                            TrackKebabMenuButton(
                                vm: vm,
                                track: track,
                                trackList: currentTracks,
                                isHighlighted: isSelected,
                                removeAction: removeClosure(at: index)
                            )
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(isDragged ? 0.35 : 1.0)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isDropTarget ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                        .tag(track.id)
                        .onDrop(of: [.text], delegate: TrackReorderDropDelegate(
                            targetTrack: track,
                            playlistId: customPlaylistId,
                            playlists: vm.playlists
                        ))
                    }
                    .onMove { indices, newOffset in
                        if let id = customPlaylistId {
                            vm.playlists.moveTracks(in: id, from: indices, to: newOffset)
                        }
                    }
                }
                .listStyle(.plain)
                .defaultScrollAnchor(.top)
                .id("playlist_\(section)")
                .onHover { _ in
                    vm.playlists.cleanupDragIfMouseUp()
                }
                .contextMenu(forSelectionType: String.self) { selection in
                    let selectedTracks = currentTracks.filter { selection.contains($0.id) }
                    if !selectedTracks.isEmpty {
                        let multiRemoveAction: (() -> Void)? = {
                            if case .playlist(let plId) = section {
                                return {
                                    vm.playlists.removeTracks(from: plId, trackIds: Array(selection))
                                    vm.selectedTrackIds.removeAll()
                                }
                            }
                            return nil
                        }()
                        TrackMenuItems(
                            vm: vm,
                            tracks: selectedTracks,
                            trackList: currentTracks,
                            removeAction: multiRemoveAction
                        )
                    }
                } primaryAction: { selection in
                    if let trackId = selection.first,
                       let track = currentTracks.first(where: { $0.id == trackId }) {
                        vm.playTrack(track, in: currentTracks)
                    }
                }
            }
        }
    }

    private var title: String {
        switch section {
        case .favorites:
            return "Favorites"
        case .recentlyPlayed:
            return "Recently Played"
        case .playlist(let id):
            return vm.playlists.playlists.first(where: { $0.id == id })?.name ?? "Playlist"
        default:
            return "Playlist"
        }
    }

    private var headerIcon: String {
        switch section {
        case .favorites: return "star.fill"
        case .recentlyPlayed: return "clock.fill"
        case .playlist: return "music.note.list"
        default: return "music.note"
        }
    }

    private var headerGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var currentTracks: [Track] {
        let trackMap = Dictionary(uniqueKeysWithValues: vm.library.tracks.map { ($0.id, $0) })
        switch section {
        case .favorites:
            return vm.favoriteTracks
        case .recentlyPlayed:
            return vm.playlists.recentlyPlayed.compactMap { trackMap[$0] }
        case .playlist(let id):
            guard let playlist = vm.playlists.playlists.first(where: { $0.id == id }) else { return [] }
            return playlist.trackIds.compactMap { trackMap[$0] }
        default:
            return []
        }
    }

    private func removeClosure(at index: Int) -> (() -> Void)? {
        guard case .playlist(let playlistId) = section else { return nil }
        return {
            vm.playlists.removeTrack(from: playlistId, at: index)
        }
    }
}

struct TrackReorderDropDelegate: DropDelegate {
    let targetTrack: Track
    let playlistId: String?
    let playlists: PlaylistManager

    func dropEntered(info: DropInfo) {
        playlists.cleanupDragIfMouseUp()
        guard let playlistId = playlistId,
              let dragged = playlists.draggedTrack,
              dragged.id != targetTrack.id else { return }

        playlists.dropTargetTrackId = targetTrack.id

        guard let plIdx = playlists.playlists.firstIndex(where: { $0.id == playlistId }),
              let from = playlists.playlists[plIdx].trackIds.firstIndex(of: dragged.id),
              let to = playlists.playlists[plIdx].trackIds.firstIndex(of: targetTrack.id)
        else { return }

        if from != to {
            withAnimation(.easeInOut(duration: 0.2)) {
                playlists.moveTracks(in: playlistId, from: IndexSet(integer: from), to: (to > from ? to + 1 : to))
            }
        }
    }

    func dropExited(info: DropInfo) {
        if playlists.dropTargetTrackId == targetTrack.id {
            playlists.dropTargetTrackId = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        playlists.clearDragState()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard playlistId != nil else { return nil }
        return DropProposal(operation: .move)
    }
}
