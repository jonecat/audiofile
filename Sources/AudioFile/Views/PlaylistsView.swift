import SwiftUI

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
                List(selection: $vm.selectedTrackId) {
                    ForEach(Array(currentTracks.enumerated()), id: \.element.id) { index, track in
                        let isPlaying = (vm.audio.currentTrack?.id == track.id)
                        let isSelected = (vm.selectedTrackId == track.id)

                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                .frame(width: 24, alignment: .trailing)

                            ArtworkView(track: track, cornerRadius: 4, shadowRadius: 0)
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.displayTitle)
                                    .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.white : (isPlaying ? Color.accentColor : Color.primary))
                                    .lineLimit(1)

                                Text(track.displayArtist + " • " + track.displayAlbum)
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(track.id)
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: String.self) { selection in
                    if let trackId = selection.first,
                       let index = currentTracks.firstIndex(where: { $0.id == trackId }) {
                        let track = currentTracks[index]
                        TrackMenuItems(
                            vm: vm,
                            track: track,
                            trackList: currentTracks,
                            removeAction: removeClosure(at: index)
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
            return vm.playlists.favorites.compactMap { trackMap[$0] }
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
