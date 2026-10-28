import SwiftUI

public struct SongsView: View {
    @ObservedObject var vm: PlayerViewModel

    public var body: some View {
        Table(vm.sortedTracks, selection: $vm.selectedTrackIds, sortOrder: $vm.sortOrder) {
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
                    ArtworkView(track: track, cornerRadius: 4, shadowRadius: 0)
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
                if let depth = track.bitDepth, depth > 0, let rateStr = track.formattedSampleRate {
                    Text("\(depth)-bit • \(rateStr)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                } else if let br = track.bitrate {
                    if let rateStr = track.formattedSampleRate {
                        Text("\(br) kbps • \(rateStr)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(br) kbps")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } else if let rateStr = track.formattedSampleRate {
                    Text(rateStr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .width(140)

            TableColumn("") { track in
                let isSelected = vm.selectedTrackIds.contains(track.id)
                TrackKebabMenuButton(vm: vm, track: track, trackList: vm.sortedTracks, isHighlighted: isSelected)
            }
            .width(32)
        }
        .contextMenu(forSelectionType: String.self) { selection in
            let selectedTracks = vm.sortedTracks.filter { selection.contains($0.id) }
            if !selectedTracks.isEmpty {
                TrackMenuItems(vm: vm, tracks: selectedTracks, trackList: vm.sortedTracks)
            }
        } primaryAction: { selection in
            if let trackId = selection.first,
               let track = vm.library.tracks.first(where: { $0.id == trackId }) {
                vm.playTrack(track, in: vm.sortedTracks)
            }
        }
    }
}
