import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var library = LibraryManager.shared
    @Environment(\.dismiss) private var dismiss
    @Namespace private var tabNamespace

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

            Divider()

            // Tab Content
            Group {
                switch vm.selectedSettingsTab {
                case .library:
                    libraryTab
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
        }
        .frame(width: 620, height: 490)
        .alert("Lyrics Cache Cleared", isPresented: $vm.showingCacheClearedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("All cached .lrc lyrics and negative cache markers have been removed.")
        }
    }

    private func tabButton(for tab: SettingsTab) -> some View {
        let isSelected = (vm.selectedSettingsTab == tab)
        return Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                vm.selectedSettingsTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(.capsule)
            .glassEffect(isSelected ? .regular.tint(Color.accentColor).interactive() : .identity, in: .capsule)
            .glassEffectID(isSelected ? "activeSettingsTab" : tab.id, in: tabNamespace)
        }
        .buttonStyle(.plain)
        .contentShape(.capsule)
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

            Spacer()
        }
    }

    // MARK: - Tab 2: Audio

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audiophile Audio Engine")
                    .font(.title3.weight(.bold))
                Text("Native Apple CoreAudio and AVAudioEngine playback pipeline with gapless pre-buffering.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

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
                        Text("FLAC, ALAC, WAV, AIFF, APE, DSD (DSF/DFF), M4A/AAC, MP3")
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
                        Text("Gapless Preload:").foregroundColor(.secondary)
                        Text("Double-buffered boundary sample alignment")
                    }
                    GridRow {
                        Text("Output Matching:").foregroundColor(.secondary)
                        Text("Direct pitch match with native DAC sample rate conversion")
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }

            Spacer()
        }
    }

    // MARK: - Tab 3: Visualizer

    private var visualizerTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Visualizer")
                    .font(.title3.weight(.bold))
                Text("Real-time DSP-driven visualizers powered by Apple Accelerate (vDSP).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
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

            VStack(alignment: .leading, spacing: 12) {
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

            VStack(alignment: .leading, spacing: 10) {
                Text("DSP Characteristics")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
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
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }

            Spacer()
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
