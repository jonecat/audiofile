import SwiftUI

public struct VisualizerView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var audio = AudioEngine.shared

    public var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height

            Group {
                if let track = audio.currentTrack {
                    contentView(track: track, width: w, height: h)
                } else {
                    emptyPlaybackView()
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
            .animation(.easeInOut(duration: 0.25), value: vm.showTrackInfo)
            .animation(.easeInOut(duration: 0.25), value: vm.showLyrics)
            .animation(.easeInOut(duration: 0.25), value: vm.showVisualizer)
        }
    }

    // MARK: - Responsive Content Router

    @ViewBuilder
    private func contentView(track: Track, width w: CGFloat, height h: CGFloat) -> some View {
        if !vm.showTrackInfo && !vm.showLyrics && !vm.showVisualizer {
            // All 3 toggled off
            allPanelsHiddenView()
        } else if !vm.showVisualizer {
            // Visualizer is OFF: Lyrics and Artwork become much larger to fill the viewport
            if vm.showTrackInfo && vm.showLyrics {
                if w >= 820 {
                    // Wide 2-Column Split: Parallel & Top-Justified to Lyrics Card
                    twoColumnInfoAndLyricsView(track: track, width: w, height: h)
                } else {
                    // Narrow Stacked: Larger Artwork/Info on Top, Expansive Full-Height Lyrics on Bottom
                    stackedInfoAndLyricsView(track: track, height: h)
                }
            } else if vm.showTrackInfo && !vm.showLyrics {
                // Info ONLY: Hero Vinyl / Artwork Center Stage
                soloHeroView(track: track, width: w, height: h)
            } else {
                // Lyrics ONLY: Full-Screen Lyrics Immersion
                soloLyricsView()
            }
        } else {
            // Visualizer is ON
            if vm.showTrackInfo && vm.showLyrics {
                // All 3 ON: Standard Stacked
                allThreeSectionsView(track: track, height: h)
            } else if vm.showTrackInfo && !vm.showLyrics {
                // Info + Visualizer
                infoAndVisualizerView(track: track, height: h)
            } else if !vm.showTrackInfo && vm.showLyrics {
                // Lyrics + Visualizer
                lyricsAndVisualizerView(height: h)
            } else {
                // Visualizer ONLY
                soloVisualizerView()
            }
        }
    }

    // MARK: - Layout Variants

    @ViewBuilder
    private func twoColumnInfoAndLyricsView(track: Track, width w: CGFloat, height h: CGFloat) -> some View {
        let topBarHeight: CGFloat = 32
        let spacingBetweenTopAndCards: CGFloat = 10
        let availableCardHeight = h - topBarHeight - spacingBetweenTopAndCards - 28
        let columnSpacing: CGFloat = 28

        // Allow artwork to expand generously to fill the vertical viewport comfortably
        // Leaves at least 380pt for the lyrics card on the right
        let maxAllowedWidth = max(300, w - columnSpacing - 380 - 48)
        let maxAllowedHeight = max(260, availableCardHeight - 160)
        let artSize = min(maxAllowedWidth, maxAllowedHeight, 520)

        VStack(spacing: spacingBetweenTopAndCards) {
            // Top Bar: Upper-right controls (Lyrics label, scale slider, toggles bar)
            HStack(alignment: .center, spacing: columnSpacing) {
                // Above Left Column: space matching artSize exactly
                Color.clear
                    .frame(width: artSize, height: 1)

                // Above Right Column: Lyrics Header + Section Toggles Bar
                HStack(alignment: .center, spacing: 8) {
                    Label("Lyrics", systemImage: "music.note.list")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    Spacer()

                    LyricsCardView.scaleSlider(scale: $vm.lyricsScale)

                    VisualizerTogglesBar(vm: vm)
                        .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            // Two-Column Content: Left & Right Columns are strictly parallel & top-justified with a clean 28pt gap
            HStack(alignment: .top, spacing: columnSpacing) {
                // Left Column: Artwork & Info (Top edge aligns with the top of the lyrics card)
                VisualizerSideInfoView(track: track, vm: vm, artworkSize: artSize)

                // Right Column: Lyrics Card (showHeader: false, starts immediately at card top)
                LyricsCardView(
                    status: vm.lyrics.status,
                    window: vm.lyrics.currentWindow,
                    scale: $vm.lyricsScale,
                    isExpanded: true,
                    showHeader: false,
                    onSeek: { vm.audio.seek(to: $0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private func stackedInfoAndLyricsView(track: Track, height h: CGFloat) -> some View {
        let artSize = min(h * 0.28, 200)

        VStack(spacing: 12) {
            HStack {
                Spacer()
                VisualizerTogglesBar(vm: vm)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            VisualizerHeaderView(
                track: track,
                vm: vm,
                artworkSize: artSize,
                titleSize: 22,
                artistSize: 16
            )

            LyricsCardView(
                status: vm.lyrics.status,
                window: vm.lyrics.currentWindow,
                scale: $vm.lyricsScale,
                isExpanded: true,
                showHeader: true,
                onSeek: { vm.audio.seek(to: $0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func allThreeSectionsView(track: Track, height h: CGFloat) -> some View {
        let isCompact = h < 580
        let artSize: CGFloat = isCompact ? 95 : (h < 720 ? 115 : 130)

        VStack(spacing: isCompact ? 10 : 14) {
            HStack {
                Spacer()
                VisualizerTogglesBar(vm: vm)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            VisualizerHeaderView(
                track: track,
                vm: vm,
                artworkSize: artSize,
                titleSize: isCompact ? 17 : 20,
                artistSize: isCompact ? 13 : 15
            )

            LyricsCardView(
                status: vm.lyrics.status,
                window: vm.lyrics.currentWindow,
                scale: $vm.lyricsScale,
                isExpanded: false,
                showHeader: true,
                onSeek: { vm.audio.seek(to: $0) }
            )
            .padding(.horizontal, 24)

            VisualizerCardContainer(vm: vm)
                .frame(maxWidth: .infinity, minHeight: 60, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func infoAndVisualizerView(track: Track, height h: CGFloat) -> some View {
        let artSize = min(170, max(120, h * 0.24))

        VStack(spacing: 14) {
            HStack {
                Spacer()
                VisualizerTogglesBar(vm: vm)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            VisualizerHeaderView(
                track: track,
                vm: vm,
                artworkSize: artSize,
                titleSize: 22,
                artistSize: 16
            )

            VisualizerCardContainer(vm: vm)
                .frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func lyricsAndVisualizerView(height h: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Label("Lyrics", systemImage: "music.note.list")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                LyricsCardView.scaleSlider(scale: $vm.lyricsScale)

                VisualizerTogglesBar(vm: vm)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            LyricsCardView(
                status: vm.lyrics.status,
                window: vm.lyrics.currentWindow,
                scale: $vm.lyricsScale,
                isExpanded: true,
                showHeader: false,
                onSeek: { vm.audio.seek(to: $0) }
            )
            .frame(maxWidth: .infinity, maxHeight: h * 0.44)
            .padding(.horizontal, 24)

            VisualizerCardContainer(vm: vm)
                .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func soloLyricsView() -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Label("Lyrics", systemImage: "music.note.list")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                LyricsCardView.scaleSlider(scale: $vm.lyricsScale)

                VisualizerTogglesBar(vm: vm)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            LyricsCardView(
                status: vm.lyrics.status,
                window: vm.lyrics.currentWindow,
                scale: $vm.lyricsScale,
                isExpanded: true,
                showHeader: false,
                onSeek: { vm.audio.seek(to: $0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func soloVisualizerView() -> some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                VisualizerTogglesBar(vm: vm)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            VisualizerCardContainer(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func soloHeroView(track: Track, width w: CGFloat, height h: CGFloat) -> some View {
        let topBarHeight: CGFloat = 52
        let bottomMargin: CGFloat = 38
        let textBlockHeight: CGFloat = 135
        let maxAllowedHeight = max(200, h - topBarHeight - textBlockHeight - bottomMargin)
        let maxAllowedWidth = max(200, w - 48)
        let artSize = min(maxAllowedWidth, maxAllowedHeight, 820)

        VStack(spacing: 0) {
            HStack {
                Spacer()
                VisualizerTogglesBar(vm: vm)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            VisualizerSoloHeroView(track: track, vm: vm, artworkSize: artSize, bottomMargin: bottomMargin)
        }
    }

    // MARK: - Empty & Fallback Views

    @ViewBuilder
    private func allPanelsHiddenView() -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                VisualizerTogglesBar(vm: vm)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            VStack(spacing: 14) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.secondary.opacity(0.8))

                Text("All Visualizer Panels Hidden")
                    .font(.title3.weight(.bold))

                Text("Use the toggle buttons in the upper right corner to show Info, Lyrics, or Visualizer.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                HStack(spacing: 10) {
                    Button("Show Info") { vm.showTrackInfo = true }
                        .buttonStyle(.bordered)
                    Button("Show Lyrics") { vm.showLyrics = true }
                        .buttonStyle(.bordered)
                    Button("Show Visualizer") { vm.showVisualizer = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
    }

    @ViewBuilder
    private func emptyPlaybackView() -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                VisualizerTogglesBar(vm: vm)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            ContentUnavailableView(
                "Nothing Playing",
                systemImage: "waveform",
                description: Text("Choose a song from your library or double click to play")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 40)
        }
    }
}

// MARK: - Pinned Upper-Right Toggles Bar

private struct VisualizerTogglesBar: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                toggleButton(
                    title: "Info",
                    icon: vm.showTrackInfo ? "info.circle.fill" : "info.circle",
                    isActive: vm.showTrackInfo,
                    helpText: "Toggle Track Info & Artwork (I)"
                ) {
                    vm.toggleTrackInfo()
                }

                toggleButton(
                    title: "Lyrics",
                    icon: vm.showLyrics ? "quote.bubble.fill" : "quote.bubble",
                    isActive: vm.showLyrics,
                    helpText: "Toggle Lyrics (L)"
                ) {
                    vm.toggleLyrics()
                }

                toggleButton(
                    title: "Visualizer",
                    icon: "waveform",
                    isActive: vm.showVisualizer,
                    helpText: "Toggle Spectrum Analyzer (V)"
                ) {
                    vm.toggleVisualizer()
                }
            }
        }
    }

    @ViewBuilder
    private func toggleButton(
        title: String,
        icon: String,
        isActive: Bool,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(.capsule)
                .glassEffect(
                    isActive
                        ? .regular.tint(Color.accentColor).interactive()
                        : .regular.interactive(),
                    in: .capsule
                )
        }
        .buttonStyle(.plain)
        .contentShape(.capsule)
        .help(helpText)
    }
}

// MARK: - Isolated Header View

private struct VisualizerHeaderView: View {
    let track: Track
    @ObservedObject var vm: PlayerViewModel
    let artworkSize: CGFloat
    let titleSize: CGFloat
    let artistSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Button {
                vm.inspectingArtworkTrack = track
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkView(track: track, cornerRadius: artworkSize > 160 ? 14 : 10, shadowRadius: artworkSize > 160 ? 10 : 6)
                        .frame(width: artworkSize, height: artworkSize)

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: artworkSize > 160 ? 11 : 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(artworkSize > 160 ? 6 : 4)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(artworkSize > 160 ? 7 : 5)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: artworkSize > 160 ? 14 : 10)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Click to view full album artwork")

            VStack(alignment: .leading, spacing: 4) {
                Text(track.displayTitle)
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(2)

                Text(track.displayArtist)
                    .font(.system(size: artistSize, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(track.displayAlbum + (track.formattedYear.map { " (\($0))" } ?? ""))
                    .font(.system(size: max(11, artistSize - 2)))
                    .foregroundColor(.secondary.opacity(0.85))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    DynamicRangeBadgeView(state: vm.currentDynamicRange) {
                        vm.calculateDynamicRange(for: track, forceRecalculate: true)
                    }

                    FormatBadgeView(format: track.format, isLossless: track.isLossless)

                    Text(track.qualityDescription)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Side Info View (For Expansive Two-Column Layout)

private struct VisualizerSideInfoView: View {
    let track: Track
    @ObservedObject var vm: PlayerViewModel
    let artworkSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                vm.inspectingArtworkTrack = track
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkView(track: track, cornerRadius: artworkSize > 360 ? 18 : 16, shadowRadius: artworkSize > 360 ? 16 : 12)
                        .frame(width: artworkSize, height: artworkSize)

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: artworkSize > 360 ? 12 : 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(artworkSize > 360 ? 7 : 6)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(artworkSize > 360 ? 9 : 8)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: artworkSize > 360 ? 18 : 16)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Click to view full album artwork")

            VStack(alignment: .leading, spacing: 5) {
                Text(track.displayTitle)
                    .font(.system(size: artworkSize > 380 ? 28 : 24, weight: .bold))
                    .lineLimit(2)

                Text(track.displayArtist)
                    .font(.system(size: artworkSize > 380 ? 19 : 17, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(track.displayAlbum + (track.formattedYear.map { " (\($0))" } ?? ""))
                    .font(.system(size: artworkSize > 380 ? 15 : 14))
                    .foregroundColor(.secondary.opacity(0.85))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    DynamicRangeBadgeView(state: vm.currentDynamicRange) {
                        vm.calculateDynamicRange(for: track, forceRecalculate: true)
                    }

                    FormatBadgeView(format: track.format, isLossless: track.isLossless)

                    Text(track.qualityDescription)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
            .frame(width: artworkSize, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(width: artworkSize, alignment: .topLeading)
    }
}

// MARK: - Solo Hero View (When Only Info Is Active)

private struct VisualizerSoloHeroView: View {
    let track: Track
    @ObservedObject var vm: PlayerViewModel
    let artworkSize: CGFloat
    let bottomMargin: CGFloat

    var body: some View {
        let titleSize: CGFloat = artworkSize > 550 ? 32 : (artworkSize > 380 ? 28 : 24)
        let artistSize: CGFloat = artworkSize > 550 ? 21 : (artworkSize > 380 ? 19 : 17)
        let albumSize: CGFloat = artworkSize > 550 ? 16 : (artworkSize > 380 ? 15 : 14)
        let cornerRad: CGFloat = min(24, max(14, artworkSize * 0.04))

        VStack(spacing: 14) {
            Spacer(minLength: 10)

            Button {
                vm.inspectingArtworkTrack = track
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkView(track: track, cornerRadius: cornerRad, shadowRadius: artworkSize > 450 ? 24 : 16)
                        .frame(width: artworkSize, height: artworkSize)

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: artworkSize > 500 ? 14 : 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(artworkSize > 500 ? 8 : 7)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .padding(artworkSize > 500 ? 12 : 9)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRad)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Click to view full album artwork")

            VStack(spacing: 5) {
                Text(track.displayTitle)
                    .font(.system(size: titleSize, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: max(artworkSize, 360))

                Text(track.displayArtist)
                    .font(.system(size: artistSize, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: max(artworkSize, 360))

                Text(track.displayAlbum + (track.formattedYear.map { " (\($0))" } ?? ""))
                    .font(.system(size: albumSize))
                    .foregroundColor(.secondary.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: max(artworkSize, 360))

                HStack(spacing: 8) {
                    DynamicRangeBadgeView(state: vm.currentDynamicRange) {
                        vm.calculateDynamicRange(for: track, forceRecalculate: true)
                    }

                    FormatBadgeView(format: track.format, isLossless: track.isLossless)

                    Text(track.qualityDescription)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: max(16, bottomMargin - 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
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
