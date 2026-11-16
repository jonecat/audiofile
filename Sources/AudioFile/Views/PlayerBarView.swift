import SwiftUI

public struct PlayerBarView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var audio = AudioEngine.shared

    public var body: some View {
        HStack(spacing: 12) {
            // Track Artwork & Info (isolated from 20Hz playback updates so tooltips never flicker or cancel)
            PlayerBarTrackInfoView(vm: vm, track: audio.currentTrack)

            Spacer(minLength: 6)

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
                PlayerBarScrubberView(vm: vm, audio: audio)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            // Right Actions: Audiophile Controls & Volume
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    // Signal Path, EQ & Queue Capsule
                    HStack(spacing: 10) {
                        Button {
                            vm.showingSignalPathPopover.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(signalPathIndicatorColor)
                                    .frame(width: 6, height: 6)
                                Image(systemName: "waveform.path.ecg")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Signal Path Inspection")
                        .popover(isPresented: $vm.showingSignalPathPopover, arrowEdge: .bottom) {
                            SignalPathPopoverView(vm: vm, audio: audio)
                        }

                        Button {
                            vm.showingEQPopover.toggle()
                        } label: {
                            Image(systemName: "slider.vertical.3")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle((vm.config.eqEnabled || vm.config.crossfeedEnabled) ? Color.accentColor : Color.primary.opacity(0.85))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("10-Band Parametric EQ & DSP")
                        .popover(isPresented: $vm.showingEQPopover, arrowEdge: .bottom) {
                            ParametricEQView(vm: vm, showDSPExtras: true)
                                .padding(16)
                                .frame(width: 470)
                        }

                        Button {
                            vm.showingQueuePopover.toggle()
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(vm.upcomingQueueItems.isEmpty ? Color.primary.opacity(0.85) : Color.accentColor)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Up Next Playback Queue")
                        .popover(isPresented: $vm.showingQueuePopover, arrowEdge: .bottom) {
                            QueuePopoverView(vm: vm, audio: audio)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.clear, in: .capsule)

                    // Volume Capsule
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
                        .frame(width: 88)
                        .controlSize(.mini)
                        .help("Adjust playback volume (+ / -)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.clear, in: .capsule)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private var signalPathIndicatorColor: Color {
        switch vm.signalPathTier {
        case .bitPerfect:
            return .green
        case .enhanced:
            return .cyan
        case .lossy:
            return .orange
        case .idle:
            return .secondary.opacity(0.6)
        }
    }
}

// MARK: - Isolated Track Info Header (Free from 20Hz currentTime redraws)

private struct PlayerBarTrackInfoView: View {
    @ObservedObject var vm: PlayerViewModel
    let track: Track?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                vm.selectedSection = .visualizer
            } label: {
                ArtworkView(track: track, cornerRadius: 8, shadowRadius: 3)
                    .frame(width: 66, height: 66)
            }
            .buttonStyle(.plain)
            .help("Open Now Playing & Visualizer (⌘4)")

            VStack(alignment: .leading, spacing: 3) {
                if let t = track {
                    Text(t.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text(t.displayArtist)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            DynamicRangeBadgeView(state: vm.currentDynamicRange, compact: true) {
                                vm.calculateDynamicRange(for: t, forceRecalculate: true)
                            }
                            FormatBadgeView(format: t.format, isLossless: t.isLossless)
                            if let shortQuality = t.shortQualityDescription {
                                Text(shortQuality)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        HStack(spacing: 6) {
                            DynamicRangeBadgeView(state: vm.currentDynamicRange, compact: true) {
                                vm.calculateDynamicRange(for: t, forceRecalculate: true)
                            }
                            FormatBadgeView(format: t.format, isLossless: t.isLossless)
                        }
                    }
                } else {
                    Text("No Track Playing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Select a song to start listening")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 80, idealWidth: 170, maxWidth: 220, alignment: .leading)

            if let t = track {
                Button {
                    vm.toggleFavorite(track: t)
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
    }
}

// MARK: - Isolated Scrubber (Receives 20Hz currentTime updates without affecting track info)

private struct PlayerBarScrubberView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var audio: AudioEngine

    var body: some View {
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
            .frame(minWidth: 90, idealWidth: 280, maxWidth: 420)
            .help("Click to seek in track")

            Text("-" + formatDuration(max(0, audio.duration - audio.currentTime)))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 46, alignment: .leading)
        }
    }

    private func formatDuration(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
