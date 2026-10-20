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
                    HStack {
                        Text(artist)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                        Text("\(trackCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(artist)
                }
                .listStyle(.plain)
                .onChange(of: vm.selectedArtist) { _, newArtist in
                    if let artist = newArtist {
                        let artistAlbums = albums(for: artist)
                        if let currentAlbum = vm.selectedAlbum, artistAlbums.contains(currentAlbum) {
                            // Keep current selection
                        } else {
                            vm.selectedAlbum = artistAlbums.first
                        }
                    }
                }
            }
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 240, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            // Column 2: Albums
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Albums", systemImage: "square.stack")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Spacer()
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
                        HStack(spacing: 8) {
                            ArtworkView(track: songs.first, cornerRadius: 4, shadowRadius: 0)
                                .frame(width: 28, height: 28)

                            Text(album)
                                .font(.system(size: 13))
                                .lineLimit(1)

                            Spacer()
                            Text("\(songs.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(album)
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView(
                        "No Artist Selected",
                        systemImage: "music.mic",
                        description: Text("Select an artist to view their albums")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            // Column 3: Songs
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Songs", systemImage: "music.note")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    if let artist = vm.selectedArtist, let album = vm.selectedAlbum {
                        Text("\(songs(for: artist, album: album).count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                if let artist = vm.selectedArtist, let album = vm.selectedAlbum {
                    let songList = songs(for: artist, album: album)
                    List(songList, selection: $vm.selectedTrackId) { track in
                        let isPlaying = (vm.audio.currentTrack?.id == track.id)
                        let isSelected = (vm.selectedTrackId == track.id)

                        HStack(spacing: 10) {
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
                                Text("—")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                    .frame(width: 24, alignment: .trailing)
                            }

                            // Title
                            Text(track.displayTitle)
                                .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.white : (isPlaying ? Color.accentColor : Color.primary))
                                .lineLimit(1)

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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(track.id)
                    }
                    .listStyle(.plain)
                    .contextMenu(forSelectionType: String.self) { selection in
                        if let trackId = selection.first,
                           let track = songList.first(where: { $0.id == trackId }) {
                            TrackMenuItems(vm: vm, track: track, trackList: songList)
                        }
                    } primaryAction: { selection in
                        if let trackId = selection.first,
                           let track = songList.first(where: { $0.id == trackId }) {
                            vm.playTrack(track, in: songList)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Album Selected",
                        systemImage: "square.stack",
                        description: Text("Select an album to view its tracks")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if vm.selectedArtist == nil, let first = artists.first {
                vm.selectedArtist = first
                vm.selectedAlbum = albums(for: first).first
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

    private func songs(for artist: String, album: String) -> [Track] {
        vm.library.tracks(for: artist, album: album)
    }
}
