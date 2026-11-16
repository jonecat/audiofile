import SwiftUI

public struct SongsView: View {
    @ObservedObject var vm: PlayerViewModel

    public var body: some View {
        Table(vm.sortedTracks, selection: $vm.selectedTrackIds, sortOrder: vm.sortOrderBinding) {
            TableColumn("") { track in
                let isPlaying = (vm.audio.currentTrack?.id == track.id)
                let isSelected = vm.selectedTrackIds.contains(track.id)

                HStack(spacing: 6) {
                    if isPlaying && vm.audio.state == .playing {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                            .font(.system(size: 11))
                    }

                    Button {
                        if vm.selectedTrackIds.contains(track.id) && vm.selectedTrackIds.count > 1 {
                            vm.toggleFavorite(trackIds: Array(vm.selectedTrackIds))
                        } else {
                            vm.toggleFavorite(track: track)
                        }
                    } label: {
                        Image(systemName: vm.playlists.isFavorite(trackId: track.id) ? "star.fill" : "star")
                            .foregroundStyle(
                                isSelected
                                    ? Color.white
                                    : (vm.playlists.isFavorite(trackId: track.id) ? Color.accentColor : Color.secondary.opacity(0.4))
                            )
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help(vm.playlists.isFavorite(trackId: track.id) ? "Remove from Favorites" : "Add to Favorites")
                }
                .frame(width: 38)
            }
            .width(42)

            TableColumn("Title", value: \.displayTitle) { track in
                let isPlaying = (vm.audio.currentTrack?.id == track.id)
                let isSelected = vm.selectedTrackIds.contains(track.id)

                HStack(spacing: 10) {
                    ArtworkView(track: track, cornerRadius: 4, shadowRadius: 0, maxPixelSize: 64)
                        .frame(width: 28, height: 28)

                    Text(track.displayTitle)
                        .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : (isPlaying ? Color.accentColor : Color.primary))
                        .lineLimit(1)
                }
            }
            .width(min: 180, ideal: 260)

            TableColumn("Artist", value: \.displayArtist) { track in
                Text(track.displayArtist)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Album", value: \.displayAlbum) { track in
                Text(track.displayAlbum)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Duration", value: \.duration) { track in
                Text(track.formattedDuration)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(64)

            TableColumn("Plays", value: \.playCountSortKey) { track in
                let isSelected = vm.selectedTrackIds.contains(track.id)
                let count = track.playCount ?? 0
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : (count > 0 ? Color.secondary : Color.secondary.opacity(0.35)))
                    Text("\(count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : (count > 0 ? Color.secondary : Color.secondary.opacity(0.35)))
                }
            }
            .width(min: 44, ideal: 52)

            TableColumn("DR", value: \.dynamicRangeSortKey) { track in
                let isSelected = vm.selectedTrackIds.contains(track.id)
                if let score = track.dynamicRange {
                    DynamicRangeBadgeView(score: score, compact: true, isHighlighted: isSelected)
                } else {
                    Text("—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(isSelected ? Color.white.opacity(0.5) : Color.secondary.opacity(0.5))
                }
            }
            .width(52)

            TableColumn("Format", value: \.format) { track in
                let isSelected = vm.selectedTrackIds.contains(track.id)
                FormatBadgeView(format: track.format, isLossless: track.isLossless, isHighlighted: isSelected)
            }
            .width(60)

            TableColumn("Quality") { track in
                if !track.qualityColumnText.isEmpty {
                    Text(track.qualityColumnText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .width(140)

            TableColumn("") { track in
                let isSelected = vm.selectedTrackIds.contains(track.id)
                TrackKebabMenuButton(
                    vm: vm,
                    track: track,
                    isHighlighted: isSelected,
                    trackListProvider: { vm.sortedTracks }
                )
            }
            .width(32)
        }
        .id(vm.songsTableSortRevision)
        .contextMenu(forSelectionType: String.self) { selection in
            let selectedTracks = selection.compactMap { vm.library.track(forId: $0) }
            if !selectedTracks.isEmpty {
                TrackMenuItems(vm: vm, tracks: selectedTracks, trackListProvider: { vm.sortedTracks })
            }
        } primaryAction: { selection in
            if let trackId = selection.first,
               let track = vm.library.track(forId: trackId) {
                vm.playTrack(track, in: vm.sortedTracks)
            }
        }
    }
}
