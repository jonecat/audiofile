import SwiftUI

public struct VisualizerView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var audio = AudioEngine.shared

    public var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 560
            let artworkSize: CGFloat = isCompact ? 100 : 130

            VStack(spacing: isCompact ? 10 : 16) {
                if let track = audio.currentTrack {
                    // Top Section: Artwork & Track Info
                    HStack(alignment: .center, spacing: 20) {
                        Button {
                            vm.inspectingArtworkTrack = track
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                ArtworkView(track: track, cornerRadius: 10, shadowRadius: 6)
                                    .frame(width: artworkSize, height: artworkSize)

                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Circle().fill(Color.black.opacity(0.6)))
                                    .padding(5)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Click to view full album artwork")
                        .onHover { inside in
                            if inside {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.displayTitle)
                                .font(.system(size: isCompact ? 18 : 22, weight: .bold))
                                .lineLimit(2)

                            Text(track.displayArtist)
                                .font(.system(size: isCompact ? 14 : 16, weight: .semibold))
                                .foregroundColor(.secondary)
                                .lineLimit(1)

                            // Album with release year: e.g. (1984)
                            Text(track.displayAlbum + (track.formattedYear.map { " (\($0))" } ?? ""))
                                .font(.system(size: isCompact ? 12 : 14))
                                .foregroundColor(.secondary.opacity(0.85))
                                .lineLimit(1)

                            HStack(spacing: 8) {
                                FormatBadgeView(format: track.format, isLossless: track.isLossless)

                                Text(track.qualityDescription)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 2)
                        }
                        Spacer()

                        // Content Area Toggles for Lyrics & Visualizer
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                Button {
                                    vm.toggleLyrics()
                                } label: {
                                    Label("Lyrics", systemImage: vm.showLyrics ? "quote.bubble.fill" : "quote.bubble")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(vm.showLyrics ? Color.white : Color.primary.opacity(0.85))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .contentShape(.capsule)
                                        .glassEffect(
                                            vm.showLyrics
                                                ? .regular.tint(Color.accentColor).interactive()
                                                : .regular.interactive(),
                                            in: .capsule
                                        )
                                }
                                .buttonStyle(.plain)
                                .contentShape(.capsule)
                                .help("Toggle Lyrics (L)")

                                Button {
                                    vm.toggleVisualizer()
                                } label: {
                                    Label("Visualizer", systemImage: "waveform")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(vm.showVisualizer ? Color.white : Color.primary.opacity(0.85))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .contentShape(.capsule)
                                        .glassEffect(
                                            vm.showVisualizer
                                                ? .regular.tint(Color.accentColor).interactive()
                                                : .regular.interactive(),
                                            in: .capsule
                                        )
                                }
                                .buttonStyle(.plain)
                                .contentShape(.capsule)
                                .help("Toggle Spectrum Analyzer")
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                    // Synchronized Lyrics Card (Toggleable, Expands dynamically to fill content when visualizer is off)
                    if vm.showLyrics {
                        LyricsCardView(
                            status: vm.lyrics.status,
                            window: vm.lyrics.currentWindow,
                            scale: $vm.lyricsScale,
                            isExpanded: !vm.showVisualizer,
                            onSeek: { timestamp in
                                vm.audio.seek(to: timestamp)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: vm.showVisualizer ? nil : .infinity)
                        .layoutPriority(vm.showVisualizer ? 0 : 1)
                        .padding(.horizontal, 24)
                        .padding(.bottom, vm.showVisualizer ? 0 : 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Responsive Real-Time Multi-Mode Visualizer (Toggleable, Isolated for 60/120 FPS performance)
                    if vm.showVisualizer {
                        VisualizerCardContainer(vm: vm)
                            .frame(maxWidth: .infinity, minHeight: 60, maxHeight: .infinity)
                            .layoutPriority(0)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !vm.showLyrics {
                        Spacer(minLength: 12)
                    }

                } else {
                    ContentUnavailableView(
                        "Nothing Playing",
                        systemImage: "waveform",
                        description: Text("Choose a song from your library or double click to play")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 80)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background {
                if let track = audio.currentTrack {
                    ArtworkView(track: track, cornerRadius: 0, shadowRadius: 0)
                        .blur(radius: 70)
                        .opacity(0.28)
                        .ignoresSafeArea()
                }
            }
            .sheet(item: $vm.inspectingArtworkTrack) { track in
                ArtworkDetailModalView(vm: vm, track: track)
            }
        }
    }
}

// MARK: - Isolated Visualizer Container (Updates at 60/120 FPS without invalidating parent views)

private struct VisualizerCardContainer: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var visualizer = VisualizerState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(VisualizerMode.allCases) { mode in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                vm.setVisualizerMode(mode)
                            }
                        } label: {
                            Label(mode.rawValue, systemImage: mode.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: vm.visualizerMode.systemImage)
                            .foregroundColor(.accentColor)
                        Text(vm.visualizerMode.rawValue.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Switch visualizer mode (click visualization to cycle)")

                Spacer()
            }

            ZStack {
                switch vm.visualizerMode {
                case .bars:
                    SpectrumBarView(bands: visualizer.bands, peaks: visualizer.peaks)
                case .vuMeter:
                    DualVUMeterView(
                        left: visualizer.vuLeft,
                        right: visualizer.vuRight,
                        leftPeak: visualizer.vuLeftPeak,
                        rightPeak: visualizer.vuRightPeak
                    )
                case .circular:
                    CircularSpectrumView(bands: visualizer.bands, peaks: visualizer.peaks)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    vm.cycleVisualizerMode()
                }
            }
            .help("Click to switch to \(vm.visualizerMode.next.rawValue)")
        }
    }
}
