import SwiftUI

public struct OpticalDiscView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var opticalManager = OpticalDiscManager.shared
    @ObservedObject var ripEngine = OpticalDiscRipEngine.shared
    @ObservedObject var audio = AudioEngine.shared

    public init(vm: PlayerViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Group {
            if let disc = opticalManager.detectedDisc {
                discContentView(disc: disc)
            } else {
                noDiscView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $opticalManager.showingRipSheet) {
            if let disc = opticalManager.detectedDisc {
                OpticalDiscRipSheet(vm: vm, disc: disc)
            }
        }
    }

    // MARK: - Disc Content View

    @ViewBuilder
    private func discContentView(disc: OpticalDisc) -> some View {
        VStack(spacing: 0) {
            // Header with Artwork & Actions
            HStack(alignment: .top, spacing: 24) {
                // High-resolution Album Artwork
                Group {
                    if let data = disc.artworkData, let img = NSImage(data: data) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 140, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: Color.black.opacity(0.3), radius: 8, y: 3)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(
                                    colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 48, weight: .light))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: Color.black.opacity(0.15), radius: 6, y: 2)
                    }
                }

                // Disc Information & Actions
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(disc.title.isEmpty ? "Audio CD" : disc.title)
                            .font(.system(size: 24, weight: .bold))
                            .lineLimit(1)
                    }

                    Text(disc.artist.isEmpty ? "Unknown Artist" : disc.artist)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let year = disc.year {
                            Text(String(year))
                            Text("•")
                        }
                        if let genre = disc.genre, !genre.isEmpty {
                            Text(genre)
                            Text("•")
                        }
                        Text("\(disc.tracks.count) tracks (\(disc.formattedTotalDuration))")
                        Text("•")
                        Text(disc.deviceName)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                    // Control Buttons
                    HStack(spacing: 12) {
                        Button {
                            playDisc(disc: disc)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("Play Disc")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            opticalManager.showingRipSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle")
                                Text(ripEngine.isRipping ? "Rip in Progress…" : "Rip CD…")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.bordered)
                        .disabled(ripEngine.isRipping)

                        Button {
                            Task {
                                await opticalManager.refreshMetadataForCurrentDisc()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .help("Refresh Metadata & Cover Art from MusicBrainz")

                        Button {
                            opticalManager.eject()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "eject.fill")
                                Text("Eject")
                            }
                            .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .help("Eject optical disc from drive")
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding(24)

            // Overall Ripping Progress Banner (if active)
            if ripEngine.isRipping {
                HStack(spacing: 14) {
                    ProgressView(value: ripEngine.overallProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(ripEngine.currentStatusMessage)
                            .font(.caption.weight(.semibold))
                        Text("\(Int(ripEngine.overallProgress * 100))% overall (\(ripEngine.completedTracksCount) of \(disc.tracks.count) completed)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Cancel") {
                        ripEngine.cancelRip()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            Divider()

            // Tracks Table with per-song live progress bars
            tracksList(disc: disc)
        }
    }

    // MARK: - Tracks List

    @ViewBuilder
    private func tracksList(disc: OpticalDisc) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                // Table Header
                HStack(spacing: 12) {
                    Text("#")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)

                    Text("Title")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 200, alignment: .leading)

                    Spacer()

                    if ripEngine.isRipping || disc.tracks.contains(where: { $0.ripState != .idle }) {
                        Text("Rip Progress & Accuracy")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 240, alignment: .leading)
                    }

                    Text("Duration")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)

                Divider()
                    .padding(.horizontal, 24)

                // Track Rows
                ForEach(disc.tracks) { track in
                    trackRow(track: track, disc: disc)
                }
            }
            .padding(.bottom, 80) // bottom padding for player bar
        }
    }

    @ViewBuilder
    private func trackRow(track: OpticalTrack, disc: OpticalDisc) -> some View {
        let isHovered = (opticalManager.hoveredTrackId == track.id)
        let isCurrentPlaying = (audio.currentTrack?.path == track.sourceURL && audio.state == .playing)

        HStack(spacing: 12) {
            // Track # or Play Button
            ZStack {
                if isHovered || isCurrentPlaying {
                    Button {
                        playTrack(track: track, disc: disc)
                    } label: {
                        Image(systemName: isCurrentPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(isCurrentPlaying ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("\(track.trackNumber)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, alignment: .trailing)

            // Track Title & Artist
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: isCurrentPlaying ? .semibold : .regular))
                    .foregroundStyle(isCurrentPlaying ? Color.accentColor : Color.primary)
                    .lineLimit(1)

                if !track.artist.isEmpty && track.artist != disc.artist && track.artist != "Unknown Artist" {
                    Text(track.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 200, alignment: .leading)

            Spacer()

            // Song-by-song Rip Progress Bar & CRC Accuracy Status
            if ripEngine.isRipping || track.ripState != .idle {
                trackRipStatusView(track: track)
                    .frame(width: 240, alignment: .leading)
            }

            // Duration
            Text(track.formattedDuration)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrentPlaying ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .padding(.horizontal, 16)
        .onHover { h in
            opticalManager.hoveredTrackId = h ? track.id : nil
        }
        .onTapGesture(count: 2) {
            playTrack(track: track, disc: disc)
        }
        .contextMenu {
            Button("Play Track") {
                playTrack(track: track, disc: disc)
            }
            Divider()
            Button("Rip This Track…") {
                opticalManager.showingRipSheet = true
            }
        }
    }

    // MARK: - Per-Song Rip Progress Bar & Status View

    @ViewBuilder
    private func trackRipStatusView(track: OpticalTrack) -> some View {
        switch track.ripState {
        case .idle:
            Text("Waiting…")
                .font(.caption2)
                .foregroundStyle(.secondary)

        case .reading(let progress, let pass):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                HStack {
                    Text(pass > 1 ? "Verifying pass \(pass)" : "Reading audio")
                    Spacer()
                    Text("\(Int(progress * 100))%")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            }

        case .verifying(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                HStack {
                    Text("AccurateRip check")
                    Spacer()
                    Text("\(Int(progress * 100))%")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            }

        case .encoding(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                HStack {
                    Text("Encoding track")
                    Spacer()
                    Text("\(Int(progress * 100))%")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            }

        case .completed(let crc, let match, _):
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .font(.caption)

                Text(match == true ? "AccurateRip Match" : "Bit-perfect Match")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.green)

                Text("[\(String(format: "%08X", crc))]")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

        case .failed(let err):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red)
                    .font(.caption)
                Text("Error: \(err)")
                    .font(.caption2)
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Empty State (No Disc)

    @ViewBuilder
    private func noDiscView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.secondary)

            Text("No Optical Disc Detected")
                .font(.title2.weight(.bold))

            Text("Insert an audio CD into your connected optical drive to read, play, and rip.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if let drive = opticalManager.connectedDriveName {
                Text("Connected Drive: \(drive)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            Button {
                opticalManager.checkForInsertedDisc()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Check for Disc")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
        .padding(32)
    }

    // MARK: - Playback Helpers

    private func playDisc(disc: OpticalDisc) {
        let playableTracks = opticalManager.makeAllPlayableTracks()
        guard let first = playableTracks.first else { return }
        vm.playTrack(first, in: playableTracks)
    }

    private func playTrack(track: OpticalTrack, disc: OpticalDisc) {
        let playableTracks = opticalManager.makeAllPlayableTracks()
        let target = opticalManager.makePlayableTrack(from: track)
        vm.playTrack(target, in: playableTracks)
    }
}
