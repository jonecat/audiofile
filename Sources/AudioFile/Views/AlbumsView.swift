import SwiftUI
import Combine

@MainActor
private final class AlbumsGridScrollState: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    var scrollPosition: ScrollPosition
    var isTrackingScroll: Bool

    var binding: Binding<ScrollPosition> {
        Binding(
            get: { self.scrollPosition },
            set: { self.scrollPosition = $0 }
        )
    }

    init(vm: PlayerViewModel) {
        let hasSavedOffset = (vm.albumsGridScrollSortMode == vm.albumSortMode && vm.albumsGridScrollOffsetY > 0)
        self.scrollPosition = hasSavedOffset
            ? ScrollPosition(y: vm.albumsGridScrollOffsetY)
            : ScrollPosition(edge: .top)
        self.isTrackingScroll = !hasSavedOffset
    }

    func scrollTo(y: CGFloat) {
        objectWillChange.send()
        scrollPosition.scrollTo(y: y)
    }

    func scrollToTop() {
        objectWillChange.send()
        scrollPosition.scrollTo(edge: .top)
    }
}

public struct AlbumsView: View {
    @ObservedObject var vm: PlayerViewModel
    @StateObject private var scrollState: AlbumsGridScrollState

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]

    public init(vm: PlayerViewModel) {
        self.vm = vm
        _scrollState = StateObject(wrappedValue: AlbumsGridScrollState(vm: vm))
    }

    public var body: some View {
        let showingDetail = (vm.selectedAlbumDetail != nil)

        ZStack {
            allAlbumsGrid(showingDetail: showingDetail)
                .opacity(showingDetail ? 0 : 1)
                .allowsHitTesting(!showingDetail)
                .disabled(showingDetail)
                .accessibilityHidden(showingDetail)

            if let album = vm.selectedAlbumDetail {
                AlbumDetailView(vm: vm, album: album)
            }
        }
    }

    private func allAlbumsGrid(showingDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Header & Sort Control
            HStack(spacing: 12) {
                Label("Albums", systemImage: "square.stack")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Text("\(vm.sortedAlbums.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))

                Spacer()

                HStack(spacing: 8) {
                    Text("Sort by:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(AlbumSortMode.allCases) { mode in
                                let isSelected = (vm.albumSortMode == mode)

                                Button {
                                    vm.albumSortMode = mode
                                } label: {
                                    Text(mode.rawValue)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 4)
                                        .contentShape(.capsule)
                                        .glassEffect(
                                            isSelected
                                                ? .regular.tint(Color.accentColor).interactive()
                                                : .regular.interactive(),
                                            in: .capsule
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Sort albums by \(mode.rawValue.lowercased())")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(vm.sortedAlbums) { album in
                        VStack(alignment: .leading, spacing: 8) {
                            ArtworkView(track: album.sampleTrack, cornerRadius: 8, shadowRadius: 4, maxPixelSize: 320)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                )

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
                                    if let dateStr = album.formattedReleaseDate {
                                        Text(dateStr)
                                        Text("•")
                                    }
                                    Text("\(album.trackCount) songs")
                                }
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.8))
                                .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.selectedAlbumDetail = album
                        }
                        .help("View \(album.title) tracks")
                        .contextMenu {
                            Button("Play Album") {
                                let tracks = vm.library.tracks(for: album.artist, album: album.title)
                                if let first = tracks.first {
                                    vm.playTrack(first, in: tracks)
                                }
                            }
                            Button("View Album") {
                                vm.selectedAlbumDetail = album
                            }
                            if !album.artist.isEmpty && UUID(uuidString: album.artist) == nil {
                                Button("Go to Artist") {
                                    vm.openArtistFromSearch(album.artist)
                                }
                            }
                        }
                    }
                }
                .id(vm.albumSortMode)
                .padding(24)
            }
            .scrollPosition(scrollState.binding)
            .scrollDisabled(showingDetail)
            .scrollIndicators(showingDetail ? .never : .automatic)
            .defaultScrollAnchor(.top)
            .onScrollPhaseChange { _, newPhase in
                if newPhase.isScrolling && !showingDetail {
                    scrollState.isTrackingScroll = true
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                max(0, geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, newY in
                guard !showingDetail, scrollState.isTrackingScroll else { return }
                vm.albumsGridScrollOffsetY = newY
                vm.albumsGridScrollSortMode = vm.albumSortMode
            }
            .task(id: showingDetail) {
                guard !showingDetail, !scrollState.isTrackingScroll else { return }
                let targetY = vm.albumsGridScrollOffsetY
                if vm.albumsGridScrollSortMode == vm.albumSortMode, targetY > 0 {
                    await Task.yield()
                    guard !Task.isCancelled, vm.selectedAlbumDetail == nil, !scrollState.isTrackingScroll else { return }
                    scrollState.scrollTo(y: targetY)
                    await Task.yield()
                }
                guard !Task.isCancelled else { return }
                scrollState.isTrackingScroll = true
            }
            .onChange(of: vm.albumSortMode) { _, newMode in
                vm.albumsGridScrollOffsetY = 0
                vm.albumsGridScrollSortMode = newMode
                scrollState.isTrackingScroll = true
                scrollState.scrollToTop()
            }
        }
    }
}

public struct AlbumDetailView: View {
    @ObservedObject var vm: PlayerViewModel
    public let album: LibraryManager.AlbumInfo

    public init(vm: PlayerViewModel, album: LibraryManager.AlbumInfo) {
        self.vm = vm
        self.album = album
    }

    public var body: some View {
        let trackList = vm.library.tracks(for: album.artist, album: album.title)

        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let isTallPortrait = (h > w * 1.1 && h >= 680)

            VStack(spacing: 0) {
                // Top-left Back to Albums button bar
                HStack {
                    Button {
                        vm.selectedAlbumDetail = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                            Text("Back to Albums")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(.capsule)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Back to Albums (Esc)")

                    Spacer()
                }
                .padding(.horizontal, w < 700 ? 20 : (isTallPortrait ? 24 : 28))
                .padding(.top, 16)
                .padding(.bottom, 10)

                if isTallPortrait {
                    // Tall 9:16 portrait layout: full-width hero cover & info above full-width tracklist
                    let fullContentWidth = max(220, w - 48)
                    let artSize = min(fullContentWidth, max(220, h - 440))
                    let tracklistWidth = fullContentWidth

                    VStack(spacing: 18) {
                        VStack(spacing: 14) {
                            ArtworkView(track: album.sampleTrack, cornerRadius: 18, shadowRadius: 20, maxPixelSize: nil)
                                .frame(width: artSize, height: artSize)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                                )

                            albumMetadataBlock(
                                trackList: trackList,
                                titleSize: artSize > 440 ? 28 : 24,
                                artistSize: artSize > 440 ? 18 : 16,
                                centered: true
                            )

                            albumActionButtons(trackList: trackList)
                        }

                        albumTracklistSection(
                            trackList: trackList,
                            showQualityText: tracklistWidth >= 540,
                            showPlaysAndDR: tracklistWidth >= 420,
                            showFormatBadge: tracklistWidth >= 360
                        )
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                } else if w < 700 {
                    // Compact stacked layout for narrow windows
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center, spacing: 18) {
                            ArtworkView(track: album.sampleTrack, cornerRadius: 12, shadowRadius: 12, maxPixelSize: 320)
                                .frame(width: 120, height: 120)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 10) {
                                albumMetadataBlock(
                                    trackList: trackList,
                                    titleSize: 20,
                                    artistSize: 14
                                )
                                albumActionButtons(trackList: trackList)
                            }
                        }

                        albumTracklistSection(
                            trackList: trackList,
                            showQualityText: w >= 580,
                            showPlaysAndDR: w >= 480,
                            showFormatBadge: w >= 380
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                } else {
                    // Wide 2-column hero layout
                    let artSize = min(max(200, w * 0.34), max(200, h - 220), 460)
                    let tracklistWidth = w - artSize - 88

                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 16) {
                            ArtworkView(track: album.sampleTrack, cornerRadius: 16, shadowRadius: 18, maxPixelSize: nil)
                                .frame(width: artSize, height: artSize)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                                )

                            albumMetadataBlock(
                                trackList: trackList,
                                titleSize: artSize > 340 ? 26 : 22,
                                artistSize: artSize > 340 ? 17 : 15
                            )
                            .frame(width: artSize, alignment: .leading)

                            albumActionButtons(trackList: trackList)

                            Spacer(minLength: 0)
                        }
                        .frame(width: artSize, alignment: .topLeading)

                        albumTracklistSection(
                            trackList: trackList,
                            showQualityText: tracklistWidth >= 460,
                            showPlaysAndDR: tracklistWidth >= 360,
                            showFormatBadge: tracklistWidth >= 380
                        )
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ArtworkView(track: album.sampleTrack, cornerRadius: 0, shadowRadius: 0, maxPixelSize: 320)
                .blur(radius: 70)
                .opacity(0.22)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func albumMetadataBlock(trackList: [Track], titleSize: CGFloat, artistSize: CGFloat, centered: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            Text(album.title)
                .font(.system(size: titleSize, weight: .bold))
                .multilineTextAlignment(centered ? .center : .leading)
                .lineLimit(2)

            if !album.artist.isEmpty && UUID(uuidString: album.artist) == nil {
                Button {
                    vm.openArtistFromSearch(album.artist)
                } label: {
                    Text(album.artist)
                        .font(.system(size: artistSize, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("View all albums by \(album.artist)")
            }

            HStack(spacing: 8) {
                if let dateStr = album.formattedReleaseDate {
                    Text(dateStr)
                    Text("•")
                }
                Text("\(trackList.count) \(trackList.count == 1 ? "song" : "songs")")
                if let durationStr = formattedTotalDuration(trackList) {
                    Text("•")
                    Text(durationStr)
                }
                Text("•")
                FormatBadgeView(format: album.sampleTrack.format, isLossless: album.sampleTrack.isLossless)
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func albumActionButtons(trackList: [Track]) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if let first = trackList.first {
                        vm.playTrack(first, in: trackList)
                    }
                } label: {
                    Label("Play Album", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.glassProminent)
                .disabled(trackList.isEmpty)
                .help("Play all tracks in \(album.title)")

                Button {
                    var shuffled = trackList
                    shuffled.shuffle()
                    if let first = shuffled.first {
                        vm.playTrack(first, in: shuffled)
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.glass)
                .disabled(trackList.isEmpty)
                .help("Shuffle tracks in \(album.title)")
            }
        }
    }

    @ViewBuilder
    private func albumTracklistSection(
        trackList: [Track],
        showQualityText: Bool,
        showPlaysAndDR: Bool,
        showFormatBadge: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Tracks", systemImage: "music.note")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Text("\(trackList.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)

            List(trackList, selection: $vm.selectedTrackIds) { track in
                let isPlaying = (vm.audio.currentTrack?.id == track.id)
                let isSelected = vm.selectedTrackIds.contains(track.id)

                HStack(spacing: 12) {
                    if isPlaying && vm.audio.state == .playing {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                            .frame(width: 24, alignment: .center)
                    } else if let num = track.trackNumber {
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

                    Button {
                        vm.toggleFavorite(track: track)
                    } label: {
                        Image(systemName: vm.playlists.isFavorite(trackId: track.id) ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(
                                isSelected
                                    ? Color.white.opacity(0.95)
                                    : (vm.playlists.isFavorite(trackId: track.id) ? Color.accentColor : Color.secondary.opacity(0.35))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(vm.playlists.isFavorite(trackId: track.id) ? "Remove from Favorites" : "Add to Favorites")

                    Text(track.displayTitle)
                        .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : (isPlaying ? Color.accentColor : Color.primary))
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    if showPlaysAndDR {
                        let plays = track.playCount ?? 0
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 7))
                            Text("\(plays)")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : (plays > 0 ? Color.secondary : Color.secondary.opacity(0.35)))
                        .frame(minWidth: 28, alignment: .trailing)

                        if let score = track.dynamicRange {
                            DynamicRangeBadgeView(score: score, compact: true, isHighlighted: isSelected)
                        }
                    }

                    if showFormatBadge {
                        FormatBadgeView(format: track.format, isLossless: track.isLossless, isHighlighted: isSelected)
                    }

                    if showQualityText && !track.qualityColumnText.isEmpty {
                        Text(track.qualityColumnText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                            .lineLimit(1)
                    }

                    Text(track.formattedDuration)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .frame(width: 44, alignment: .trailing)

                    TrackKebabMenuButton(
                        vm: vm,
                        track: track,
                        isHighlighted: isSelected,
                        trackListProvider: { trackList }
                    )
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .tag(track.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .defaultScrollAnchor(.top)
            .id("album_detail_\(album.id)")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .glassEffect(.clear, in: .rect(cornerRadius: 16))
    }

    private func formattedTotalDuration(_ tracks: [Track]) -> String? {
        let totalSeconds = Int(tracks.reduce(0.0) { $0 + max(0, $1.duration) }.rounded())
        guard totalSeconds > 0 else { return nil }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(max(1, minutes)) min"
    }
}
