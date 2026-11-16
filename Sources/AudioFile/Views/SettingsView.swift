import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var library = LibraryManager.shared
    @ObservedObject var audio = AudioEngine.shared
    @Environment(\.dismiss) private var dismiss

    public init(vm: PlayerViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header with Liquid Glass Tab Bar & Close Button
            HStack {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(SettingsTab.allCases) { tab in
                            tabButton(for: tab)
                        }
                    }
                    .padding(4)
                    .glassEffect(.clear, in: .capsule)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Close Settings")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(height: 60)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(100)

            Divider()

            // Tab Content
            Group {
                switch vm.selectedSettingsTab {
                case .library:
                    libraryTab
                case .cdDrive:
                    cdDriveTab
                case .audio:
                    audioTab
                case .visualizer:
                    visualizerTab
                case .lyrics:
                    lyricsTab
                case .about:
                    aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .animation(.easeInOut(duration: 0.2), value: vm.selectedSettingsTab)
        }
        .frame(width: 720, height: 580)
        .alert("Lyrics Cache Cleared", isPresented: $vm.showingCacheClearedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("All cached .lrc lyrics and negative cache markers have been removed.")
        }
        .alert("Clear All Library Data & Rescan?", isPresented: $vm.showingResetLibraryConfirmation) {
            Button("Clear All Data & Rescan", role: .destructive) {
                vm.resetAndRescanLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete all playlists, favorites, recently played history, play counts, and cached library metadata.\n\nYour audio files on disk will NOT be touched or deleted. Your library will be rescanned from scratch.")
        }
    }

    private func tabButton(for tab: SettingsTab) -> some View {
        let isSelected = (vm.selectedSettingsTab == tab)
        return Button {
            withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                vm.selectedSettingsTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(.capsule)
            .glassEffect(
                isSelected
                    ? .regular.tint(Color.accentColor).interactive()
                    : .regular.interactive(),
                in: .capsule
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .contentShape(.capsule)
        .fixedSize(horizontal: true, vertical: false)
        .help("\(tab.rawValue) settings")
    }

    // MARK: - Tab 1: Library

    private var libraryTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library Folders")
                    .font(.title3.weight(.bold))
                Text("AudioFile scans these directories recursively for lossless and high-resolution audio files.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Configured Directories", systemImage: "folder")
                        .font(.headline)
                    Spacer()
                    Button {
                        chooseFolder()
                    } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Choose a music folder to add to your library")
                }

                ScrollView {
                    VStack(spacing: 0) {
                        if vm.config.libraryFolders.isEmpty {
                            Text("No folders configured. Click Add Folder to include your music.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(24)
                        } else {
                            ForEach(vm.config.libraryFolders, id: \.self) { folder in
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(.accentColor)
                                    Text(folder.path)
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        removeFolder(folder)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove folder from library")
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
                .glassEffect(.clear, in: .rect(cornerRadius: 12))
            }

            // Sync Controls
            VStack(alignment: .leading, spacing: 10) {
                Text("Library Synchronization")
                    .font(.headline)

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            library.startSync(folders: vm.config.libraryFolders, fullRescan: false)
                        } label: {
                            HStack(spacing: 6) {
                                if library.isSyncing && !library.isFullRescan {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Syncing…")
                                } else {
                                    Label("Sync Library (Incremental)", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(library.isSyncing)
                        .help("Scan library folders for new or modified audio files")

                        Button {
                            library.startSync(folders: vm.config.libraryFolders, fullRescan: true)
                        } label: {
                            HStack(spacing: 6) {
                                if library.isSyncing && library.isFullRescan {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Rescanning Metadata…")
                                } else {
                                    Label("Full Metadata Rescan", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(library.isSyncing)
                        .help("Re-read metadata tags for all audio files in your library")

                        if !library.syncStatusText.isEmpty {
                            Text(library.syncStatusText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        } else if let completedMsg = library.syncCompletedMessage {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                                Text(completedMsg)
                                    .foregroundStyle(Color.green)
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: library.isSyncing)
                    .animation(.easeInOut(duration: 0.2), value: library.syncCompletedMessage)
                }
            }

            // Reset & Rebuild Section
            VStack(alignment: .leading, spacing: 10) {
                Text("Reset & Rebuild Library")
                    .font(.headline)

                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Permanently erases all library databases, playlists, favorites, recently played history, and play counts, then performs a complete fresh rescan from your configured folders.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        HStack {
                            Button(role: .destructive) {
                                vm.showingResetLibraryConfirmation = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash")
                                    Text("Clear All Library Data & Rescan…")
                                }
                                .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(library.isSyncing)
                            .help("Permanently delete playlists, favorites, recently played, and cache, then rescan library folders")

                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
        }
    }

    // MARK: - Tab: CD Drive & Optical Ripping

    private var cdDriveTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Optical CD Drive & Accurate Ripping")
                    .font(.title3.weight(.bold))
                Text("Bit-perfect CDDA audio reading, disc playback, MusicBrainz metadata, and Whipper-grade AccurateRip verification.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Hardware Drive Status
            VStack(alignment: .leading, spacing: 10) {
                Text("Optical Drive Status")
                    .font(.headline)

                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 18))
                                .foregroundColor(vm.opticalDiscManager.isDiscDetected ? .accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.opticalDiscManager.connectedDriveName ?? "Optical Drive")
                                    .font(.system(size: 13, weight: .semibold))

                                if let disc = vm.opticalDiscManager.detectedDisc {
                                    Text("Disc Present: \(disc.title) — \(disc.artist) (\(disc.tracks.count) tracks)")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                } else {
                                    Text("No optical disc currently inserted")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            if vm.opticalDiscManager.isDiscDetected {
                                Button("Eject") {
                                    vm.opticalDiscManager.eject()
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }

                            Button {
                                vm.opticalDiscManager.checkForInsertedDisc()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .help("Scan for optical drives and media")
                        }
                    }
                    .padding(14)
                }
            }

            // AccurateRip & Encoding Info
            VStack(alignment: .leading, spacing: 10) {
                Text("Rip Accuracy & Encoding Standards")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Accuracy Verification:").foregroundColor(.secondary)
                        Text("AccurateRip v1/v2 & IEEE 802.3 CRC-32 (Whipper / EAC standard)")
                    }
                    GridRow {
                        Text("Supported Encoders:").foregroundColor(.secondary)
                        Text("FLAC (Lossless), ALAC (Lossless), Opus, Ogg Vorbis, WAV, WavPack, MP3")
                    }
                    GridRow {
                        Text("Directory Hierarchy:").foregroundColor(.secondary)
                        Text("Standard Artist / Album / Track - Song.ext")
                    }
                    GridRow {
                        Text("Cover Artwork:").foregroundColor(.secondary)
                        Text("Cover Art Archive & High-Resolution Artwork (cover.jpg)")
                    }
                }
                .font(.system(size: 12))
            }

            Spacer()
        }
    }

    // MARK: - Tab 2: Audio

    private var audioTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audiophile Audio Engine")
                        .font(.title3.weight(.bold))
                    Text("CoreAudio DAC routing, sample-rate switching, exclusive mode, ReplayGain, and 10-band Parametric EQ.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // 1. CoreAudio Output DAC & Bit-Perfect Routing
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Hardware DAC & Output Routing")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "Active Clock: %.1f kHz", audio.hardwareSampleRate / 1000.0))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Text("Output Device")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 110, alignment: .leading)

                            Picker("Output Device", selection: Binding(
                                get: { vm.config.selectedOutputDeviceUID ?? "" },
                                set: { vm.selectOutputDevice(uid: $0.isEmpty ? nil : $0) }
                            )) {
                                Text("System Default Output").tag("")
                                ForEach(audio.availableDevices) { dev in
                                    Text("\(dev.name) (\(dev.formattedSampleRate))").tag(dev.id)
                                }
                            }
                            .labelsHidden()

                            Button {
                                vm.refreshOutputDevices()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Rescan connected CoreAudio DACs and interfaces")
                        }

                        Divider()

                        Toggle(isOn: Binding(
                            get: { vm.config.autoSampleRateSwitching },
                            set: { vm.setAutoSampleRateSwitching($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bit-Perfect Auto Sample-Rate Switching")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Automatically matches the DAC hardware sample rate to each track (44.1 / 48 / 88.2 / 96 / 192 kHz) to bypass macOS resampling.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        Toggle(isOn: Binding(
                            get: { vm.config.exclusiveHogMode },
                            set: { vm.setExclusiveHogMode($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Exclusive DAC (\"Hog\") Mode")
                                        .font(.system(size: 13, weight: .medium))
                                    if audio.isHogModeActive {
                                        Text("LOCKED")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.purple)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.purple.opacity(0.16)))
                                    }
                                }
                                Text("Acquires exclusive hardware access on dedicated external USB/Thunderbolt DACs so system alerts and other apps cannot mix into playback.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }

                // 2. ReplayGain & Loudness Normalization
                VStack(alignment: .leading, spacing: 12) {
                    Text("ReplayGain Normalization")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Normalization Mode")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Picker("ReplayGain Mode", selection: Binding(
                                get: { vm.config.replayGainMode },
                                set: { vm.setReplayGainMode($0) }
                            )) {
                                ForEach(ReplayGainMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 260)
                        }

                        HStack(spacing: 12) {
                            Text("Preamp Trim")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 110, alignment: .leading)

                            Slider(value: Binding(
                                get: { Double(vm.config.replayGainPreampDb) },
                                set: { vm.setReplayGainPreamp(Float($0)) }
                            ), in: -6.0...6.0, step: 0.5)

                            Text(String(format: "%+.1f dB", vm.config.replayGainPreampDb))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                        .disabled(vm.config.replayGainMode == .off)

                        Text("Applies embedded REPLAYGAIN tags with automatic peak clipping prevention using REPLAYGAIN_*_PEAK headroom.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }

                // 3. Headphone Crossfeed (BS2B)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Headphone Crossfeed (BS2B Acoustic Staging)")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { vm.config.crossfeedEnabled },
                            set: { vm.setCrossfeedEnabled($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable BS2B Headphone Crossfeed")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Blends a ~700 Hz low-pass cross-channel signal with a 260 µs interaural delay to restore speaker-like soundstage and reduce ear fatigue.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        HStack(spacing: 12) {
                            Text("Feed Level")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 110, alignment: .leading)

                            Slider(value: Binding(
                                get: { Double(vm.config.crossfeedLevel) },
                                set: { vm.setCrossfeedLevel(Float($0)) }
                            ), in: 0.05...0.75)
                            .disabled(!vm.config.crossfeedEnabled)

                            Text("\(Int((vm.config.crossfeedLevel * 100).rounded()))%")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }

                // 4. 10-Band Parametric EQ
                VStack(alignment: .leading, spacing: 12) {
                    Text("Parametric Equalizer")
                        .font(.headline)

                    ParametricEQView(vm: vm, showDSPExtras: false)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }

                // 5. Engine Specifications Grid
                VStack(alignment: .leading, spacing: 12) {
                    Text("Engine Specifications")
                        .font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("Playback Backend:").foregroundColor(.secondary)
                            Text("Apple CoreAudio & AVAudioEngine (macOS Native)")
                        }
                        GridRow {
                            Text("Supported Formats:").foregroundColor(.secondary)
                            Text("FLAC, ALAC, WAV, AIFF, APE, DSD (DSF/DFF), M4A/AAC, MP3 + .CUE")
                        }
                        GridRow {
                            Text("Bit Depths:").foregroundColor(.secondary)
                            Text("1-bit DSD, 16-bit, 24-bit, 32-bit Float")
                        }
                        GridRow {
                            Text("Sample Rates:").foregroundColor(.secondary)
                            Text("44.1 to 192 kHz PCM • 2.82 / 5.64 MHz DSD64/128")
                        }
                        GridRow {
                            Text("Gapless Playback:").foregroundColor(.secondary)
                            Text("Sample-accurate .dataPlayedBack node pre-scheduling")
                        }
                        GridRow {
                            Text("DSP Pipeline:").foregroundColor(.secondary)
                            Text("10-band Parametric EQ (AutoEQ) • BS2B Crossfeed • ReplayGain")
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Tab 3: Visualizer

    private var visualizerTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Audio Visualizer")
                    .font(.title3.weight(.bold))
                Text("Real-time DSP-driven visualizers powered by Apple Accelerate (vDSP).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Visualization Style")
                    .font(.headline)

                Picker("", selection: Binding(
                    get: { vm.visualizerMode },
                    set: { vm.setVisualizerMode($0) }
                )) {
                    ForEach(VisualizerMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)
                .help("Select default visualization style")

                Text(visualizerDescription(for: vm.visualizerMode))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Default Panels")
                    .font(.headline)

                Toggle("Show Track Info & Artwork by Default", isOn: $vm.showTrackInfo)
                    .font(.system(size: 13))

                Toggle("Show Visualizer Spectrum by Default", isOn: $vm.showVisualizer)
                    .font(.system(size: 13))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Target Frame Rate")
                    .font(.headline)

                Picker("", selection: Binding(
                    get: { vm.config.visualizerFPS },
                    set: { vm.setVisualizerFPS($0) }
                )) {
                    Text("30 FPS (Energy Saver)").tag(30)
                    Text("60 FPS (Default Smooth)").tag(60)
                    Text("120 FPS (ProMotion Ultra)").tag(120)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420, alignment: .leading)
                .help("Select target frame rate for the audio visualizer")

                Text("Controls the calculation and redraw frequency. 120 FPS provides maximum fluid motion on Apple ProMotion displays.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("DSP Characteristics")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("DSP Framework:").foregroundColor(.secondary)
                        Text("Apple Accelerate (vDSP FFT & Vectorized Math)")
                    }
                    GridRow {
                        Text("Frequency Spectrum:").foregroundColor(.secondary)
                        Text("64 Logarithmic Bands (35 Hz to 16,000 Hz)")
                    }
                    GridRow {
                        Text("Window Function:").foregroundColor(.secondary)
                        Text("Hann Window with spectral leakage suppression")
                    }
                    GridRow {
                        Text("Analog VU Movement:").foregroundColor(.secondary)
                        Text("D'Arsonval Galvanometer Spring-Damper Inertia")
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Tab 4: Lyrics

    private var lyricsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lyrics Engine")
                    .font(.title3.weight(.bold))
                Text("Synchronized LRC lyric retrieval and real-time playback tracking.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                Toggle("Show Synchronized 5-Line Lyrics by Default", isOn: $vm.showLyrics)
                    .font(.system(size: 13))

                Toggle("Automatically Fetch Lyrics from LRCLIB", isOn: Binding(
                    get: { vm.config.autoFetchLyrics },
                    set: {
                        vm.config.autoFetchLyrics = $0
                        vm.config.save()
                    }
                ))
                .font(.system(size: 13))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Lyrics Cache")
                    .font(.headline)

                HStack(spacing: 12) {
                    Button("Clear Lyrics Disk Cache") {
                        Task {
                            await LRCLIBClient.shared.clearCache()
                            await MainActor.run {
                                vm.showingCacheClearedAlert = true
                            }
                        }
                    }
                    .buttonStyle(.glass)
                    .help("Delete all locally cached .lrc lyrics files")

                    Text("Stored locally in ~/Library/Caches/AudioFile/lyrics/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Tab 5: About (Table Representation)

    private struct AboutSpecification: Identifiable {
        let id: String
        let property: String
        let value: String

        init(_ property: String, _ value: String) {
            self.id = property
            self.property = property
            self.value = value
        }
    }

    private var aboutSpecifications: [AboutSpecification] {
        [
            AboutSpecification("App Version", AppUpdater.shared.currentVersion),
            AboutSpecification("Platform", "macOS 26.0+ (Liquid Glass Native)"),
            AboutSpecification("UI Framework", "Swift 6 & SwiftUI Liquid Glass (AppKit)"),
            AboutSpecification("Audio Engine", "Apple CoreAudio & AVAudioEngine"),
            AboutSpecification("FFT Visualizer", "Apple Accelerate (vDSP 64-Band Real-Time)"),
            AboutSpecification("Lyrics Provider", "LRCLIB API (Synchronized 5-Line LRC)"),
            AboutSpecification("Waveform Engine", "Asynchronous RMS downsampling & dynamics cache"),
            AboutSpecification("Playback Pipeline", "Lossless gapless boundary preloading"),
            AboutSpecification("Audio Codecs", "FLAC, ALAC, WAV, AIFF, APE, DSD (DSF/DFF), M4A/AAC, MP3"),
            AboutSpecification("Author", "Jon Lawrence"),
            AboutSpecification("Repository", "https://github.com/jonecat/audiofile"),
            AboutSpecification("License", "MIT License")
        ]
    }

    private var aboutTab: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 48, height: 48)
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("AudioFile")
                        .font(.title2.weight(.bold))
                    Text("Native Audiophile Music Player for macOS")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            vm.updater.checkForUpdates(userInitiated: true)
                        } label: {
                            Label(
                                vm.updater.isCheckingForUpdates ? "Checking…" : "Check for Updates…",
                                systemImage: "arrow.down.circle"
                            )
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(vm.updater.isCheckingForUpdates || vm.updater.isInstallingUpdate)
                        .help("Check GitHub Releases for a newer version of AudioFile")

                        Link(destination: URL(string: "https://github.com/jonecat/audiofile")!) {
                            Label("GitHub", systemImage: "link")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Open AudioFile repository on GitHub")
                    }
                }
            }

            // About Information Table
            Table(aboutSpecifications) {
                TableColumn("Component") { item in
                    Text(item.property)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .width(min: 130, ideal: 150, max: 170)

                TableColumn("Specification") { item in
                    Text(item.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 12))
            .glassEffect(.clear, in: .rect(cornerRadius: 12))
        }
    }

    // MARK: - Folder Helpers

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a music folder to add to your AudioFile library"
        panel.prompt = "Add Folder"

        if panel.runModal() == .OK, let url = panel.url {
            if !vm.config.libraryFolders.contains(url) {
                vm.config.libraryFolders.append(url)
                vm.config.save()
                vm.library.startSync(folders: vm.config.libraryFolders, fullRescan: false)
            }
        }
    }

    private func removeFolder(_ folder: URL) {
        vm.config.libraryFolders.removeAll { $0 == folder }
        vm.config.save()
        vm.library.startSync(folders: vm.config.libraryFolders, fullRescan: false)
    }

    private func visualizerDescription(for mode: VisualizerMode) -> String {
        switch mode {
        case .bars:
            return "Classic 64-band logarithmic frequency analyzer with responsive attack, exponential decay, and peak caps."
        case .vuMeter:
            return "Twin Left/Right vintage analog VU meters with authentic D'Arsonval needle inertia and peak overload LEDs."
        case .circular:
            return "Symmetrical 360° radial frequency halo with a dynamic sub-bass pulsating core."
        }
    }
}
