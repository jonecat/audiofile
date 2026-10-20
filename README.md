# ♬ AudioFile

> **High-Fidelity Native macOS Audiophile Music Player**  
> Built with Swift 6, SwiftUI **Liquid Glass** (macOS 26+), AVFoundation, CoreAudio, and Accelerate (`vDSP`).  
> Engineered to deliver complete audiophile parity with **OmaFLAC** in a native macOS Liquid Glass interface.

`AudioFile` is a native macOS audio player designed for audiophiles who demand bit-perfect lossless playback, high-resolution metadata, real-time 64-band FFT spectrum visualization, 5-line synchronized lyrics, and deep Apple ecosystem integration. Built with Apple's native **Liquid Glass** design system (`Glass`, `.glassEffect`, `GlassEffectContainer`, and `.glassEffectID`), every accented element dynamically adapts to your macOS **System Settings → Appearance** accent color.

---

## ✨ Features

- **Native macOS 26+ Liquid Glass Interface**:
  - Floating Liquid Glass bottom player deck (`PlayerBarView`) with circular interactive glass transport buttons, waveform seekbar, and capsule volume deck.
  - Morphing Liquid Glass pill tabs (`GlassEffectContainer` + `.glassEffectID`) in the **Settings (`⌘,`)** window.
  - High-contrast lossless format badges (`FLAC`, `ALAC`, `WAV`, `AIFF`) and full-row selection contrast that keeps active/playing tracks crisp when highlighted.
  - Dynamic system accent color integration: all active controls, spectrum analyzer bars, waveform progress, format badges, and lyric highlights follow the macOS Appearance accent color in real time.
  - Hover tooltips (`.help`) across all buttons and interactive controls.
- **Audiophile Lossless Playback & CoreAudio Engine**:
  - Native hardware-accelerated decoding for **FLAC**, **ALAC** (Apple Lossless), **WAV**, **AIFF**, **M4A/AAC**, and **MP3** via Apple `AVFoundation` and `CoreAudio`.
  - Full support for **16-bit**, **24-bit**, and **32-bit Float** lossless audio with exact sample rates (`44.1 kHz`, `48 kHz`, `88.2 kHz`, `96 kHz`, `176.4 kHz`, `192 kHz`).
  - True **gapless transitions** with double-buffered boundary sample alignment.
  - **Continuous Library Shuffle (`⇧⌘S`)**: Top-toolbar **Shuffle Library** button shuffles your entire collection and automatically queues freshly shuffled passes as the queue nears completion so playback never stops until you stop it.
  - Software volume boost up to 150% and instant mute/unmute.
- **Synchronized 5-Line Lyrics Engine**:
  - **Multi-Stage LRCLIB Integration**: Fetches time-synchronized `.lrc` lyrics on-demand via [LRCLIB](https://lrclib.net) using exact `/api/get` matching, remaster/edition suffix stripping, and multi-stage `/api/search` fallback scored by artist, title, album, and track duration—with automatic retry/backoff on transient `503`/`429` responses.
  - **Local Sidecar `.lrc` Priority**: Automatically detects and loads `<track>.lrc` files located alongside audio tracks in your library.
  - **Offline Disk Caching**: Saves fetched `.lrc` files locally (`~/Library/Caches/AudioFile/lyrics/`) for instant 0ms offline access without poisoning cache on transient network errors.
  - **5-Line Synchronized Window & Adjustable Text Size Slider**: Displays 2 previous lines, the active lyric line, and 2 upcoming lines, with a live **Text & Card Size Slider** (`0.85x–2.8x`) that dynamically expands the Lyrics card and scales the Spectrum Analyzer to fit.
  - **Smooth Instrumental Break Scrolling**: Normalizes instrumental intros, breaks, and outros (`♪ Instrumental Break ♪`) into timeline entries so instrumental sections scroll smoothly through all 5 rows (`next2 → next1 → curr → prev1 → prev2`).
- **Real-Time 64-Band FFT Spectrum Visualizer**:
  - Live audio tap feeding a 2048-point Fast Fourier Transform via the **Accelerate framework (`vDSP`)**.
  - Hann-windowed, 64 logarithmically spaced frequency bands (`20 Hz – 20,000 Hz`).
  - Equal-loudness treble compensation, logarithmic dB scaling, and dynamic attack/decay envelope ballistics with peak-hold cap markers.
  - User-configurable refresh rates: **30 FPS (Energy Saver)**, **60 FPS (Default Smooth)**, and **120 FPS (ProMotion Ultra)**.
  - Dedicated **Lyrics** and **Visualizer** pill toggles directly inside the Now Playing / Visualizer header.
- **High-Resolution Track Dynamics Waveform Scrubber**:
  - Pre-calculates 512 amplitude dynamics bins in background worker tasks and caches waveforms on disk (`~/Library/Caches/AudioFile/waveforms/`).
  - Interactive seekbar in the floating bottom player deck with played vs. unplayed accent contrast and click/drag scrubbing.
- **Hierarchical Library, Track Menus & Playlists**:
  - **Artists (`⌘1`)**: 3-column macOS browser (**Artists → Albums → Songs**) with complete binary MP4/M4A (`trkn`/`disk`), ID3 (`TRCK`/`TPOS`), and filename-prefix track sorting.
  - **Albums (`⌘2`)**: Adaptive album artwork grid with release year, track count, and Liquid Glass modal tracklist sheet.
  - **Songs (`⌘3`)**: Native macOS sortable `Table` with single-click row selection, double-click playback, format pills, quality readout, favorite stars (`★`), and per-row kebab (`⋯`) menus.
  - **Visualizer / Now Playing (`⌘4`)**: Hero view with album artwork, lossless format/bit-depth badge, adjustable 5-line synchronized lyrics card, and live 64-band FFT spectrum analyzer.
  - **Playlists (`⌘5` / `⌘6`)**: Built-in **★ Favorites**, **🕒 Recently Played**, and custom user playlists with a **Delete** action and destructive confirmation modal.
  - **Unified Context & Kebab (`⋯`) Menus**: Right-click any track or click its `⋯` button to **Play**, **Play Next**, **Favorite**, **Add to Playlist**, **Remove from Playlist**, or **Show in Finder**.
  - **Settings (`⌘,`)**: Native macOS application menu integration (**AudioFile → Settings…**) with 5 Liquid Glass tabs (**Library**, **Audio**, **Visualizer**, **Lyrics**, and **About** specification table).
- **Incremental Background Library Sync (NAS & Remote Friendly)**:
  - Instant startup loading from cached `~/Library/Application Support/AudioFile/library.json` with automatic metadata backfill for track/disc numbers.
  - Non-destructive incremental background scanner using file size and modification timestamp (`stat`) caching.
  - Unmounted network drive protection: prevents wiping cached tracks if a remote NAS or external drive is offline.
- **Full macOS System Integration**:
  - **Menu Bar**: Native **AudioFile**, **Controls**, and **View** menus with standard keyboard shortcuts.
  - **Media Keys & Control Center**: Full integration with `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` (track title, artist, album, artwork, and playback progress appear in macOS Control Center and Lock Screen).
  - **Drag and Drop**: Drag audio files or folders directly into the window to play immediately or add to your library.

---

## ⌨️ Controls & Shortcuts

| Action | Shortcut / Mouse |
| :--- | :--- |
| **Play / Pause** | `Space` or media key |
| **Play Selected Track** | Double-click track row (single-click selects row) |
| **Next Track** | `⌘→` / `⌘]` or click `▷\|` |
| **Previous Track** | `⌘←` / `⌘[` or click `\|◁` |
| **Shuffle Entire Library (Continuous)** | `⇧⌘S` or click **Shuffle Library** in top toolbar |
| **Seek Backward / Forward 5s** | `Shift + ←` / `Shift + →` or click waveform scrubber |
| **Seek Backward / Forward 30s** | `⌥⌘←` / `⌥⌘→` |
| **Volume Up / Down** | `+` / `-` or volume slider |
| **Mute / Unmute** | `M` or click speaker icon |
| **Cycle Repeat Mode (Off / All / 1)** | `R` or click repeat button |
| **Toggle Queue Shuffle** | `Z` or click shuffle button |
| **Toggle Lyrics Card** | `L` or click **Lyrics** pill on Visualizer screen |
| **Favorite Current Track** | `F` or click `★` |
| **Global Search** | `⌘F` or click toolbar search field |
| **Switch to Artists View** | `⌘1` |
| **Switch to Albums View** | `⌘2` |
| **Switch to Songs View** | `⌘3` |
| **Switch to Visualizer / Now Playing** | `⌘4` |
| **Switch to Favorites** | `⌘5` |
| **Switch to Recently Played** | `⌘6` |
| **Open Settings** | `⌘,` (**AudioFile → Settings…**) |

---

## 🛠️ Building & Running

### Requirements
- **macOS 26.0+** (Liquid Glass SDK)
- **Xcode / Command Line Tools** with Swift 6.2+

### Build & Run from Command Line
```bash
# Clone the repository
git clone https://github.com/jonecat/audiofile.git
cd audiofile

# Run directly in debug mode
swift run AudioFile
```

### Build the Standalone Application Bundle (`AudioFile.app`)
```bash
# Compile optimized release build and package into ad-hoc signed AudioFile.app
./scripts/build_app.sh

# Launch the built macOS application
open AudioFile.app
```

You can drag `AudioFile.app` directly into your `/Applications` folder.

---

## 🏗️ Architecture

```text
audiofile/
├── Package.swift                           # Swift Package Manager configuration (.macOS(.v26), Swift 6)
├── Resources/
│   ├── Info.plist                          # macOS bundle configuration & audio file associations
│   ├── AppIcon.icns                        # High-resolution Retina application icon (16x16 to 1024x1024)
│   └── AppIcon_1024.png
├── scripts/
│   └── build_app.sh                        # Release compilation and ad-hoc signed .app bundle packager
└── Sources/
    └── AudioFile/
        ├── AudioFile.swift                 # @main SwiftUI App entry point, Settings (⌘,) & menu commands
        ├── Models/
        │   ├── Track.swift                 # Audio track metadata model, format descriptors & quality info
        │   ├── Playlist.swift              # Playlist and PlaylistsData models
        │   ├── AppConfig.swift             # Persistent app configuration (folders, volume, repeat, FPS, lyricsScale)
        │   └── LRC.swift                   # Synced lyrics parser, 5-line sliding window & normalized instrumental lines
        ├── Audio/
        │   ├── AudioEngine.swift           # AVAudioEngine player, audio tap, gapless queue & MPRemoteCommandCenter
        │   ├── VisualizerEngine.swift      # Accelerate vDSP 64-band FFT, logarithmic spacing & ballistics physics
        │   └── WaveformEngine.swift        # Background track amplitude dynamics analyzer & disk cache
        ├── Lyrics/
        │   ├── LRCLIBClient.swift          # Multi-stage LRCLIB API client, retry backoff & local .lrc cache
        │   └── LyricsManager.swift         # Observable coordinator for active song synchronized lyrics
        ├── Library/
        │   ├── LibraryManager.swift        # In-memory library catalog, incremental sync & track/disc sorting
        │   ├── MetadataReader.swift        # AVURLAsset tag extractor (MP4 trkn/disk, ID3 TRCK/TPOS, artwork)
        │   └── PlaylistManager.swift       # PlaylistManager for Favorites, Recently Played & custom playlists
        ├── ViewModels/
        │   └── PlayerViewModel.swift       # Global observable coordinator (playback, continuous library shuffle, UI state)
        └── Views/
            ├── MainSplitView.swift         # Root NavigationSplitView, Shuffle/Refresh toolbar & drag-and-drop
            ├── SidebarView.swift           # Sidebar navigation panel with live track & playlist counts
            ├── PlayerBarView.swift         # Floating Liquid Glass bottom deck: transport, waveform scrubber & volume
            ├── ArtistsView.swift           # 3-column hierarchical browser (Artists → Albums → Songs)
            ├── AlbumsView.swift            # Adaptive album grid with Liquid Glass modal tracklist sheet
            ├── SongsView.swift             # Native macOS sortable Table with single/double-click & kebab menus
            ├── VisualizerView.swift        # Now Playing view: artwork, Lyrics/Visualizer toggles, 5-line lyrics & FFT
            ├── PlaylistsView.swift         # Playlist viewer with Play, Shuffle, and Delete confirmation modal
            ├── SettingsView.swift          # 5-tab Liquid Glass settings (Library, Audio, Visualizer, Lyrics, About)
            ├── AboutView.swift             # Stylized About AudioFile view with specs & repository links
            └── Components/
                ├── FormatBadgeView.swift   # High-contrast Liquid Glass format badge pills (FLAC, ALAC, WAV, etc.)
                ├── ArtworkView.swift       # Async album artwork loader with accent-tinted fallback
                ├── SpectrumBarView.swift   # 64-band animated spectrum analyzer Canvas with accent gradient & peaks
                ├── WaveformBarView.swift   # Interactive waveform seeker in the bottom player bar
                ├── LyricsCardView.swift    # 5-line synchronized lyrics card with text/card size slider
                └── TrackMenuView.swift     # Shared TrackMenuItems context menu & TrackKebabMenuButton (⋯)
```

---

## 📁 Configuration & Data Paths

`AudioFile` stores user configuration and cached library metadata in standard macOS application support and cache directories:
- `~/Library/Application Support/AudioFile/config.json`: Library folders, volume, repeat mode, shuffle, visualizer FPS, and lyrics scale/visibility preferences.
- `~/Library/Application Support/AudioFile/library.json`: Scanned track database and metadata index.
- `~/Library/Application Support/AudioFile/playlists.json`: User-created playlists, favorites, and recently played tracks.
- `~/Library/Caches/AudioFile/waveforms/`: Cached 512-point track amplitude waveforms for instant loading.
- `~/Library/Caches/AudioFile/lyrics/`: Cached synchronized `.lrc` lyrics for instant offline playback.

*(Note: If migrating from `OmaFLAC`, `AudioFile` automatically detects and imports existing tracks and playlists from `~/.config/omaflac/` on first launch.)*

---

## 👤 Author & License

Created by **Jon Lawrence** — [https://github.com/jonecat/audiofile](https://github.com/jonecat/audiofile)  
Released under the **MIT License**.
