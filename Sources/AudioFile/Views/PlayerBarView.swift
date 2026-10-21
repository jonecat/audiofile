import SwiftUI

public struct PlayerBarView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var audio = AudioEngine.shared

    public var body: some View {
        HStack(spacing: 16) {
            // Track Artwork & Info
            HStack(spacing: 14) {
                Button {
                    vm.selectedSection = .visualizer
                } label: {
                    ArtworkView(track: audio.currentTrack, cornerRadius: 8, shadowRadius: 3)
                        .frame(width: 66, height: 66)
                }
                .buttonStyle(.plain)
                .help("Open Now Playing & Visualizer (⌘4)")

                VStack(alignment: .leading, spacing: 3) {
                    if let track = audio.currentTrack {
                        Text(track.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        Text(track.displayArtist)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            FormatBadgeView(format: track.format, isLossless: track.isLossless)
                            if let shortQuality = track.shortQualityDescription {
                                Text(shortQuality)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("No Track Playing")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Select a song to start listening")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .frame(width: 180, alignment: .leading)

                if let track = audio.currentTrack {
                    Button {
                        vm.toggleFavorite(track: track)
                    } label: {
                        Image(systemName: vm.isCurrentTrackFavorite ? "star.fill" : "star")
                            .foregroundStyle(vm.isCurrentTrackFavorite ? Color.accentColor : Color.primary.opacity(0.85))
                            .font(.system(size: 13))
                            .frame(width: 28, height: 28)
                            .contentShape(.circle)
                            .glassEffect(
                                vm.isCurrentTrackFavorite
                                    ? .regular.tint(Color.accentColor.opacity(0.25)).interactive()
                                    : .regular.interactive(),
                                in: .circle
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(.circle)
                    .help(vm.isCurrentTrackFavorite ? "Remove from Favorites (F)" : "Add to Favorites (F)")
                }
            }

            Spacer()

            // Center Controls & Scrubber
            VStack(spacing: 6) {
                // Transport Buttons inside a Liquid Glass container
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        // Shuffle
                        Button {
                            vm.toggleShuffle()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(vm.shuffle ? Color.white : Color.primary.opacity(0.85))
                                .frame(width: 28, height: 28)
                                .contentShape(.circle)
                                .glassEffect(
                                    vm.shuffle
                                        ? .regular.tint(Color.accentColor).interactive()
                                        : .regular.interactive(),
                                    in: .circle
                                )
                        }
                        .buttonStyle(.plain)
                        .contentShape(.circle)
                        .help("Shuffle (Z)")

                        // Previous Track
                        Button {
                            vm.previousTrack()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.primary)
                                .frame(width: 32, height: 32)
                                .contentShape(.circle)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .contentShape(.circle)
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Previous track (← / ⌘[)")

                        // Play / Pause
                        Button {
                            audio.togglePlayPause()
                        } label: {
                            Image(systemName: audio.state == .playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .offset(x: audio.state == .playing ? 0 : 1)
                                .frame(width: 38, height: 38)
                                .contentShape(.circle)
                                .glassEffect(.regular.tint(Color.accentColor).interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .contentShape(.circle)
                        .keyboardShortcut(.space, modifiers: [])
                        .help("Play / Pause (Space)")

                        // Next Track
                        Button {
                            vm.nextTrack()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.primary)
                                .frame(width: 32, height: 32)
                                .contentShape(.circle)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .contentShape(.circle)
                        .keyboardShortcut("]", modifiers: .command)
                        .help("Next track (→ / ⌘])")

                        // Repeat Mode
                        Button {
                            vm.cycleRepeatMode()
                        } label: {
                            Image(systemName: vm.repeatMode.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(vm.repeatMode != .off ? Color.white : Color.primary.opacity(0.85))
                                .frame(width: 28, height: 28)
                                .contentShape(.circle)
                                .glassEffect(
                                    vm.repeatMode != .off
                                        ? .regular.tint(Color.accentColor).interactive()
                                        : .regular.interactive(),
                                    in: .circle
                                )
                        }
                        .buttonStyle(.plain)
                        .contentShape(.circle)
                        .help("Repeat mode: \(vm.repeatMode.rawValue) (R)")
                    }
                }

                // Scrubber Bar & Times
                HStack(spacing: 8) {
                    Text(formatDuration(audio.currentTime))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 42, alignment: .trailing)

                    WaveformBarView(
                        waveform: vm.currentWaveform,
                        currentTime: audio.currentTime,
                        duration: audio.duration
                    ) { seekTime in
                        audio.seek(to: seekTime)
                    }
                    .frame(maxWidth: 420)
                    .help("Click to seek in track")

                    Text("-" + formatDuration(max(0, audio.duration - audio.currentTime)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 46, alignment: .leading)
                }
            }

            Spacer()

            // Right Actions: Volume
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    Button {
                        audio.isMuted.toggle()
                    } label: {
                        Image(systemName: audio.isMuted || audio.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Mute / Unmute (M)")

                    Slider(value: Binding(
                        get: { audio.volume },
                        set: { audio.volume = $0 }
                    ), in: 0...1.5)
                    .tint(Color.accentColor)
                    .frame(width: 96)
                    .controlSize(.mini)
                    .help("Adjust playback volume (+ / -)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.clear, in: .capsule)
            }
            .frame(width: 230, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private func formatDuration(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
