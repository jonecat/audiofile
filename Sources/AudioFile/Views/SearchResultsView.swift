import SwiftUI

public struct SearchResultsView: View {
    @ObservedObject var vm: PlayerViewModel

    public init(vm: PlayerViewModel) {
        self.vm = vm
    }

    private var trimmedQuery: String {
        vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasAnyResults: Bool {
        !vm.searchMatchingArtists.isEmpty ||
        !vm.searchMatchingAlbums.isEmpty ||
        !vm.sortedTracks.isEmpty ||
        !vm.searchMatchingPlaylists.isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchHeaderBar

            Divider()

            if !hasAnyResults {
                ContentUnavailableView.search(text: trimmedQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.searchCategoryFilter == .songs {
                if vm.sortedTracks.isEmpty {
                    emptyCategoryView(category: "Songs")
                } else {
                    SongsView(vm: vm)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if shouldShowArtists {
                            artistsSection
                        }

                        if shouldShowAlbums {
                            albumsSection
                        }

                        if shouldShowPlaylists {
                            playlistsSection
                        }

                        if vm.searchCategoryFilter == .all && !vm.sortedTracks.isEmpty {
                            songsSection
                        }

                        if isSelectedCategoryEmpty {
                            emptyCategoryView(category: vm.searchCategoryFilter.rawValue)
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    private var shouldShowArtists: Bool {
        (vm.searchCategoryFilter == .all || vm.searchCategoryFilter == .artists) && !vm.searchMatchingArtists.isEmpty
    }

    private var shouldShowAlbums: Bool {
        (vm.searchCategoryFilter == .all || vm.searchCategoryFilter == .albums) && !vm.searchMatchingAlbums.isEmpty
    }

    private var shouldShowPlaylists: Bool {
        (vm.searchCategoryFilter == .all || vm.searchCategoryFilter == .playlists) && !vm.searchMatchingPlaylists.isEmpty
    }

    private var isSelectedCategoryEmpty: Bool {
        switch vm.searchCategoryFilter {
        case .all:
            return false
        case .artists:
            return vm.searchMatchingArtists.isEmpty
        case .albums:
            return vm.searchMatchingAlbums.isEmpty
        case .songs:
            return vm.sortedTracks.isEmpty
        case .playlists:
            return vm.searchMatchingPlaylists.isEmpty
        }
    }

    // MARK: - Header & Category Filter Bar

    private var searchHeaderBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("Search Results for \"\(trimmedQuery)\"")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)

                Spacer()

                Button {
                    vm.clearSearch()
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Clear search and return to library")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(SearchCategoryFilter.allCases) { filter in
                            let isSelected = (vm.searchCategoryFilter == filter)
                            let countText = categoryCountLabel(for: filter)

                            Button {
                                vm.searchCategoryFilter = filter
                            } label: {
                                HStack(spacing: 5) {
                                    Text(filter.rawValue)
                                    if let countText {
                                        Text(countText)
                                            .font(.system(size: 11, design: .monospaced))
                                            .opacity(isSelected ? 0.9 : 0.7)
                                    }
                                }
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .contentShape(.capsule)
                                .glassEffect(
                                    isSelected
                                        ? .regular.tint(Color.accentColor).interactive()
                                        : .regular.interactive(),
                                    in: .capsule
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func categoryCountLabel(for filter: SearchCategoryFilter) -> String? {
        switch filter {
        case .all:
            let total = vm.searchMatchingArtists.count
                + vm.searchMatchingAlbums.count
                + vm.sortedTracks.count
                + vm.searchMatchingPlaylists.count
            return "(\(total))"
        case .artists:
            return "(\(vm.searchMatchingArtists.count))"
        case .albums:
            return "(\(vm.searchMatchingAlbums.count))"
        case .songs:
            return "(\(vm.sortedTracks.count))"
        case .playlists:
            return "(\(vm.searchMatchingPlaylists.count))"
        }
    }

    private func emptyCategoryView(category: String) -> some View {
        ContentUnavailableView(
            "No Matching \(category)",
            systemImage: "magnifyingglass",
            description: Text("No \(category.lowercased()) match \"\(trimmedQuery)\".")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Artists Section

    private var artistsSection: some View {
        let allArtists = vm.searchMatchingArtists
        let visibleArtists: [String] = {
            if vm.searchCategoryFilter == .all && !vm.searchShowAllArtists && allArtists.count > 12 {
                return Array(allArtists.prefix(12))
            }
            return allArtists
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionHeader(title: "Artists", systemImage: "music.mic", count: allArtists.count)

                Spacer()

                if vm.searchCategoryFilter == .all && allArtists.count > 12 {
                    Button {
                        vm.searchShowAllArtists.toggle()
                    } label: {
                        Text(vm.searchShowAllArtists ? "Show Less" : "See All (\(allArtists.count))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)], spacing: 14) {
                ForEach(visibleArtists, id: \.self) { artist in
                    let artistTracks = vm.library.tracks(for: artist)
                    let albumCount = vm.library.albums(for: artist).count
                    let songCount = vm.library.trackCount(for: artist)

                    Button {
                        vm.openArtistFromSearch(artist)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(track: artistTracks.first, cornerRadius: 8, shadowRadius: 2, maxPixelSize: 64)
                                .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(artist)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)

                                Text("\(albumCount) \(albumCount == 1 ? "album" : "albums") • \(songCount) \(songCount == 1 ? "song" : "songs")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("View Artist") {
                            vm.openArtistFromSearch(artist)
                        }
                        Button("Play Artist") {
                            if let first = artistTracks.first {
                                vm.playTrack(first, in: artistTracks)
                            }
                        }
                        .disabled(artistTracks.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Albums Section

    private var albumsSection: some View {
        let albums = vm.searchMatchingAlbums

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Albums", systemImage: "square.stack", count: albums.count)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)], spacing: 20) {
                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: 8) {
                        ArtworkView(track: album.sampleTrack, cornerRadius: 8, shadowRadius: 4, maxPixelSize: 320)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .onTapGesture {
                                vm.openAlbumFromSearch(album)
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
                        Button("View Album") {
                            vm.openAlbumFromSearch(album)
                        }
                        if !album.artist.isEmpty && UUID(uuidString: album.artist) == nil {
                            Button("Go to Artist") {
                                vm.openArtistFromSearch(album.artist)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Playlists Section

    private var playlistsSection: some View {
        let matchingPlaylists = vm.searchMatchingPlaylists

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Playlists", systemImage: "music.note.list", count: matchingPlaylists.count)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14)], spacing: 14) {
                ForEach(matchingPlaylists) { playlist in
                    let firstTrack = playlist.trackIds.first.flatMap { vm.library.track(forId: $0) }

                    HStack(spacing: 12) {
                        Group {
                            if let sample = firstTrack {
                                ArtworkView(track: sample, cornerRadius: 8, shadowRadius: 2, maxPixelSize: 64)
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(LinearGradient(
                                            colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ))
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(playlist.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)

                            Text("\(playlist.trackIds.count) \(playlist.trackIds.count == 1 ? "track" : "tracks")")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if !playlist.trackIds.isEmpty {
                            Button {
                                playPlaylist(playlist)
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Play \(playlist.name)")
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture {
                        vm.openPlaylistFromSearch(playlist)
                    }
                    .contextMenu {
                        Button("Open Playlist") {
                            vm.openPlaylistFromSearch(playlist)
                        }
                        Button("Play Playlist") {
                            playPlaylist(playlist)
                        }
                        .disabled(playlist.trackIds.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Songs Section

    private var songsSection: some View {
        let tracks = vm.sortedTracks

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionHeader(title: "Songs", systemImage: "music.note", count: tracks.count)

                Spacer()

                Button {
                    vm.searchCategoryFilter = .songs
                } label: {
                    Label("Sort in Table View", systemImage: "tablecells")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Open matching songs in full sortable table")
            }

            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    let isPlaying = (vm.audio.currentTrack?.id == track.id)
                    let isFav = vm.playlists.isFavorite(trackId: track.id)
                    let playCount = track.playCount ?? 0

                    HStack(spacing: 12) {
                        Button {
                            vm.toggleFavorite(track: track)
                        } label: {
                            Image(systemName: isFav ? "star.fill" : "star")
                                .font(.system(size: 11))
                                .foregroundStyle(isFav ? Color.accentColor : Color.secondary.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .help(isFav ? "Remove from Favorites" : "Add to Favorites")

                        ArtworkView(track: track, cornerRadius: 4, shadowRadius: 0, maxPixelSize: 64)
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if isPlaying && vm.audio.state == .playing {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.accentColor)
                                }

                                Text(track.displayTitle)
                                    .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                                    .lineLimit(1)
                            }

                            Text("\(track.displayArtist) • \(track.displayAlbum)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 7))
                            Text("\(playCount)")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(playCount > 0 ? Color.secondary : Color.secondary.opacity(0.35))
                        .frame(minWidth: 32, alignment: .trailing)

                        if let score = track.dynamicRange {
                            DynamicRangeBadgeView(score: score, compact: true)
                        }

                        FormatBadgeView(format: track.format, isLossless: track.isLossless)

                        if !track.qualityColumnText.isEmpty {
                            Text(track.qualityColumnText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(minWidth: 110, alignment: .trailing)
                        }

                        Text(track.formattedDuration)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 46, alignment: .trailing)

                        TrackKebabMenuButton(
                            vm: vm,
                            track: track,
                            isHighlighted: false,
                            trackListProvider: { vm.sortedTracks }
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isPlaying ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        vm.playTrack(track, in: vm.sortedTracks)
                    }
                    .contextMenu {
                        TrackMenuItems(vm: vm, track: track, trackList: vm.sortedTracks)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }

    private func playPlaylist(_ playlist: Playlist) {
        let resolved = playlist.trackIds.compactMap { vm.library.track(forId: $0) }
        if let first = resolved.first {
            vm.playTrack(first, in: resolved)
        }
    }
}
