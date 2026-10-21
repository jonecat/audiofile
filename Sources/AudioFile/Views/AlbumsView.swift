import SwiftUI

public struct AlbumsView: View {
    @ObservedObject var vm: PlayerViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(filteredAlbums) { album in
                    VStack(alignment: .leading, spacing: 8) {
                        ArtworkView(track: album.sampleTrack, cornerRadius: 8, shadowRadius: 4)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .onTapGesture {
                                vm.selectedAlbumDetail = album
                            }
                            .help("View \(album.title) tracks")

                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)

                            if !album.artist.isEmpty && UUID(uuidString: album.artist) == nil {
                                Text(album.artist)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            HStack(spacing: 4) {
                                if let y = album.year {
                                    Text(String(y))
                                    Text("•")
                                }
                                Text("\(album.trackCount) songs")
                            }
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                        }
                    }
                    .contextMenu {
                        Button("Play Album") {
                            let tracks = vm.library.tracks(for: album.artist, album: album.title)
                            if let first = tracks.first {
                                vm.playTrack(first, in: tracks)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .sheet(item: $vm.selectedAlbumDetail) { album in
            VStack(spacing: 0) {
                // Header with Album Art & Details
                HStack(spacing: 20) {
                    ArtworkView(track: album.sampleTrack, cornerRadius: 10, shadowRadius: 6)
                        .frame(width: 120, height: 120)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title)
                            .font(.title2.weight(.bold))

                        if !album.artist.isEmpty && UUID(uuidString: album.artist) == nil {
                            Text(album.artist)
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 8) {
                            if let y = album.year {
                                Text(String(y))
                                Text("•")
                            }
                            Text("\(album.trackCount) tracks")
                            Text("•")
                            FormatBadgeView(format: album.sampleTrack.format, isLossless: album.sampleTrack.isLossless)
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                        Button {
                            let tracks = vm.library.tracks(for: album.artist, album: album.title)
                            if let first = tracks.first {
                                vm.playTrack(first, in: tracks)
                            }
                        } label: {
                            Label("Play Album", systemImage: "play.fill")
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.regular)
                        .help("Play all tracks in \(album.title)")
                    }

                    Spacer()

                    Button {
                        vm.selectedAlbumDetail = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Close Album Details")
                }
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // Tracklist
                let trackList = vm.library.tracks(for: album.artist, album: album.title)
                List(trackList, selection: $vm.selectedTrackIds) { track in
                    let isPlaying = (vm.audio.currentTrack?.id == track.id)
                    let isSelected = vm.selectedTrackIds.contains(track.id)

                    HStack(spacing: 12) {
                        if let num = track.trackNumber {
                            Text("\(num)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                .frame(width: 24, alignment: .trailing)
                        } else {
                            Text("-")
                                .font(.system(size: 12))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                .frame(width: 24, alignment: .trailing)
                        }

                        HStack(spacing: 6) {
                            Text(track.displayTitle)
                                .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.white : (isPlaying ? Color.accentColor : Color.primary))

                            if vm.playlists.isFavorite(trackId: track.id) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.accentColor)
                            }
                        }

                        Spacer()

                        Text(track.formattedDuration)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)

                        TrackKebabMenuButton(vm: vm, track: track, trackList: trackList, isHighlighted: isSelected)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(track.id)
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: String.self) { selection in
                    let selectedTracks = trackList.filter { selection.contains($0.id) }
                    if !selectedTracks.isEmpty {
                        TrackMenuItems(vm: vm, tracks: selectedTracks, trackList: trackList)
                    }
                } primaryAction: { selection in
                    if let trackId = selection.first,
                       let track = trackList.first(where: { $0.id == trackId }) {
                        vm.playTrack(track, in: trackList)
                    }
                }
            }
            .frame(width: 540, height: 480)
            .sheet(item: $vm.inspectingTrack) { inspectedTrack in
                TrackMetadataSheetView(vm: vm, track: inspectedTrack)
            }
        }
    }

    private var filteredAlbums: [LibraryManager.AlbumInfo] {
        if vm.searchQuery.isEmpty {
            return vm.library.allAlbums
        }
        return vm.library.allAlbums.filter {
            $0.title.localizedCaseInsensitiveContains(vm.searchQuery) ||
            $0.artist.localizedCaseInsensitiveContains(vm.searchQuery)
        }
    }
}
