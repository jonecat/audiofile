import SwiftUI

public struct ArtistsView: View {
    @ObservedObject var vm: PlayerViewModel

    public var body: some View {
        HStack(spacing: 0) {
            // Column 1: Artists
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Artists", systemImage: "music.mic")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(artists.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                List(artists, id: \.self, selection: $vm.selectedArtist) { artist in
                    let trackCount = vm.library.tracks(for: artist).count
                    HStack(spacing: 10) {
                        Text(artist)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                        Text("\(trackCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(artist)
                }
                .listStyle(.plain)
                .onChange(of: vm.selectedArtist) { _, _ in
                    vm.selectedAlbum = nil
                    vm.selectedTrackIds.removeAll()
                }
            }
            .padding(.horizontal, 8)
            .frame(width: vm.artistsColumnWidth)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            ColumnDividerView(
                onDragChange: { translation, isEnded in
                    vm.handleArtistsDrag(translation: translation, isEnded: isEnded)
                },
                onDoubleClick: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        vm.resetArtistsColumnWidth()
                    }
                }
            )

            // Column 2: Albums
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Albums", systemImage: "square.stack")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    if vm.selectedAlbum != nil {
                        Button {
                            vm.selectedAlbum = nil
                        } label: {
                            Text("All")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Show songs from all albums by this artist")
                    }
                    if let artist = vm.selectedArtist {
                        Text("\(albums(for: artist).count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                if let artist = vm.selectedArtist {
                    let albumList = albums(for: artist)
                    List(albumList, id: \.self, selection: $vm.selectedAlbum) { album in
                        let songs = vm.library.tracks(for: artist, album: album)
                        HStack(spacing: 10) {
                            ArtworkView(track: songs.first, cornerRadius: 5, shadowRadius: 0)
                                .frame(width: 32, height: 32)

                            Text(album)
                                .font(.system(size: 13))
                                .lineLimit(1)

                            Spacer()
                            Text("\(songs.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(album)
                    }
                    .listStyle(.plain)
                    .onChange(of: vm.selectedAlbum) { _, _ in
                        vm.syncQueueWithDisplayedTracks(displayedSongs(for: artist))
                    }
                } else {
                    ContentUnavailableView(
                        "No Artist Selected",
                        systemImage: "music.mic",
                        description: Text("Select an artist to view their albums")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: vm.albumsColumnWidth)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            ColumnDividerView(
                onDragChange: { translation, isEnded in
                    vm.handleAlbumsDrag(translation: translation, isEnded: isEnded)
                },
                onDoubleClick: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        vm.resetAlbumsColumnWidth()
                    }
                }
            )

            // Column 3: Songs
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Songs", systemImage: "music.note")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    if let selectedAlbum = vm.selectedAlbum {
                        Text("• \(selectedAlbum)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let artist = vm.selectedArtist {
                        Text("\(displayedSongs(for: artist).count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                if let artist = vm.selectedArtist {
                    let songList = displayedSongs(for: artist)
                    List(songList, selection: $vm.selectedTrackIds) { track in
                        let isPlaying = (vm.audio.currentTrack?.id == track.id)
                        let isSelected = vm.selectedTrackIds.contains(track.id)

                        HStack(spacing: 12) {
                            // Track number or playing indicator
                            if isPlaying && vm.audio.state == .playing {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                                    .frame(width: 24, alignment: .center)
                            } else if let num = track.trackNumber {
                                Text("\(num)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                    .frame(width: 24, alignment: .trailing)
                            } else {
                                Text("-")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                    .frame(width: 24, alignment: .trailing)
                            }

                            // Song Artwork
                            ArtworkView(track: track, cornerRadius: 5, shadowRadius: 0)
                                .frame(width: 32, height: 32)

                            // Title (and Album subtitle when viewing all albums for this artist)
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

                                if vm.selectedAlbum == nil {
                                    Text(track.displayAlbum)
                                        .font(.system(size: 11))
                                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            // Format Badge
                            FormatBadgeView(format: track.format, isLossless: track.isLossless, isHighlighted: isSelected)

                            // Duration
                            Text(track.formattedDuration)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                .frame(width: 44, alignment: .trailing)

                            // Kebab Menu
                            TrackKebabMenuButton(vm: vm, track: track, trackList: songList, isHighlighted: isSelected)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(track.id)
                    }
                    .listStyle(.plain)
                    .contextMenu(forSelectionType: String.self) { selection in
                        let selectedTracks = songList.filter { selection.contains($0.id) }
                        if !selectedTracks.isEmpty {
                            TrackMenuItems(vm: vm, tracks: selectedTracks, trackList: songList)
                        }
                    } primaryAction: { selection in
                        if let trackId = selection.first,
                           let track = songList.first(where: { $0.id == trackId }) {
                            vm.playTrack(track, in: songList)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Artist Selected",
                        systemImage: "music.note",
                        description: Text("Select an artist to view their songs")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if vm.selectedArtist == nil, let first = artists.first {
                vm.selectedArtist = first
                vm.selectedAlbum = nil
            }
        }
    }

    private var artists: [String] {
        if vm.searchQuery.isEmpty {
            return vm.library.uniqueArtists
        }
        return vm.library.uniqueArtists.filter { $0.localizedCaseInsensitiveContains(vm.searchQuery) }
    }

    private func albums(for artist: String) -> [String] {
        vm.library.albums(for: artist)
    }

    private func displayedSongs(for artist: String) -> [Track] {
        vm.library.tracks(for: artist, album: vm.selectedAlbum)
    }
}
