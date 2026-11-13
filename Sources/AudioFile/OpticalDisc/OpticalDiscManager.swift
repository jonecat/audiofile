import Foundation
import AppKit
import AVFoundation
import DiscRecording
import Combine

@MainActor
public final class OpticalDiscManager: ObservableObject {
    public static let shared = OpticalDiscManager()

    @Published public private(set) var detectedDisc: OpticalDisc?
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var connectedDriveName: String?
    @Published public private(set) var statusMessage: String = ""

    // UI state (stored on ObservableObject to avoid @State macro requirement with Swift 6 CLI)
    @Published public var showingRipSheet: Bool = false
    @Published public var hoveredTrackId: String? = nil
    @Published public var ripFormat: RipFormat = .flac
    @Published public var ripDestinationFolder: URL? = nil
    @Published public var verifyWithAccurateRip: Bool = true

    public var isDiscDetected: Bool {
        detectedDisc != nil
    }

    public var discTitle: String {
        guard let d = detectedDisc else { return "No Disc" }
        return d.title.isEmpty ? "Audio CD" : d.title
    }

    public var tracks: [OpticalTrack] {
        detectedDisc?.tracks ?? []
    }

    private var pollTimer: AnyCancellable?

    public init() {
        setupDriveNotifications()
        checkForInsertedDisc()

        // Periodic check every 2 seconds to catch hardware insertion/removal
        pollTimer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkForInsertedDisc()
            }
    }

    // MARK: - Notifications

    private func setupDriveNotifications() {
        // 1. DiscRecording notification center
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DRDeviceStatusChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForInsertedDisc()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DRDeviceAppearedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForInsertedDisc()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DRDeviceDisappearedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForInsertedDisc()
            }
        }

        // 2. NSWorkspace volume mount / unmount notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleVolumeMounted()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleVolumeUnmounted()
            }
        }
    }

    private func handleVolumeMounted() {
        checkForInsertedDisc()
    }

    private func handleVolumeUnmounted() {
        if let disc = detectedDisc {
            // Check if our volume is still mounted
            if let vol = disc.volumeURL, !FileManager.default.fileExists(atPath: vol.path) {
                ejectCurrentDiscUI()
            }
        }
    }

    // MARK: - Scan & Detect

    public func checkForInsertedDisc() {
        // 1. Inspect DiscRecording devices
        var driveDisplayName = "Optical Drive"

        if let devices = DRDevice.devices() as? [DRDevice], !devices.isEmpty {
            for dev in devices {
                driveDisplayName = dev.displayName() ?? "Optical Drive"
                let status = dev.status() as? [String: Any] ?? [:]
                let mediaState = status[DRDeviceMediaStateKey] as? String
                if mediaState == DRDeviceMediaStateMediaPresent {
                    break
                }
            }
        }

        self.connectedDriveName = driveDisplayName

        // 2. Direct check for /Volumes/Audio CD
        let directAudioCD = URL(fileURLWithPath: "/Volumes/Audio CD")
        if FileManager.default.fileExists(atPath: directAudioCD.path) && isAudioCDVolume(directAudioCD) {
            loadPhysicalAudioCD(at: directAudioCD, driveName: driveDisplayName)
            return
        }

        // 3. Scan /Volumes for mounted Audio CD (cddafs)
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        if let volumeURLs = try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.volumeLocalizedFormatDescriptionKey, .volumeIsRemovableKey],
            options: []
        ) {
            for volURL in volumeURLs {
                if isAudioCDVolume(volURL) {
                    loadPhysicalAudioCD(at: volURL, driveName: driveDisplayName)
                    return
                }
            }
        }

        // If no audio CD volume found and we previously had a disc, clear it
        if detectedDisc != nil {
            ejectCurrentDiscUI()
        }
    }

    private func isAudioCDVolume(_ url: URL) -> Bool {
        // 1. .TOC.plist is the official hallmark of macOS cddafs
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".TOC.plist").path) {
            return true
        }

        // 2. Volume localized format description ("CD Audio", "Audio CD", "cdda")
        if let values = try? url.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]),
           let format = values.volumeLocalizedFormatDescription {
            if format.localizedCaseInsensitiveContains("cd audio") ||
               format.localizedCaseInsensitiveContains("audio cd") ||
               format.localizedCaseInsensitiveContains("cdda") {
                return true
            }
        }

        // 3. Directory contents check for .aiff audio tracks
        if let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            let aiffTracks = files.filter {
                let lower = $0.lowercased()
                return lower.hasSuffix(".aiff") || lower.hasSuffix(".aif") || lower.hasSuffix(".cdda")
            }
            if !aiffTracks.isEmpty {
                return true
            }
        }

        return false
    }

    private func loadPhysicalAudioCD(at volumeURL: URL, driveName: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: volumeURL, includingPropertiesForKeys: nil, options: []) else {
            return
        }

        let audioTrackFiles = files.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "aiff" || ext == "aif" || ext == "cdda"
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !audioTrackFiles.isEmpty else { return }

        // Parse hardware .TOC.plist if present (macOS cddafs standard)
        var parsedFirstTrack = 1
        var parsedLastTrack = audioTrackFiles.count
        var parsedLeadout = 0
        var trackOffsets: [Int] = []

        let tocPlistURL = volumeURL.appendingPathComponent(".TOC.plist")
        if let data = try? Data(contentsOf: tocPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let sessions = plist["Sessions"] as? [[String: Any]],
           let firstSession = sessions.first {
            parsedFirstTrack = firstSession["First Track"] as? Int ?? 1
            parsedLastTrack = firstSession["Last Track"] as? Int ?? audioTrackFiles.count
            parsedLeadout = firstSession["Leadout Block"] as? Int ?? 0
            let trackArray = (firstSession["Track Array"] as? [[String: Any]]) ?? []
            for t in trackArray {
                if let start = t["Start Block"] as? Int {
                    trackOffsets.append(start)
                }
            }
        }

        var opticalTracks: [OpticalTrack] = []
        var currentSector = 150

        for (idx, trackURL) in audioTrackFiles.enumerated() {
            let trackNum = idx + 1
            let startSector = idx < trackOffsets.count ? trackOffsets[idx] : currentSector

            let nextStart = (idx + 1 < trackOffsets.count) ? trackOffsets[idx + 1] : (parsedLeadout > 0 ? parsedLeadout : (startSector + 15000))
            let sectorLength = max(nextStart - startSector, 150)
            let trackDuration = Double(sectorLength) / 75.0

            let track = OpticalTrack(
                trackNumber: trackNum,
                title: "Track \(trackNum)",
                artist: "Unknown Artist",
                duration: trackDuration,
                sectorStart: startSector,
                sectorCount: sectorLength,
                sourceURL: trackURL
            )
            opticalTracks.append(track)
            currentSector = startSector + sectorLength
        }

        if trackOffsets.isEmpty {
            trackOffsets = opticalTracks.map { $0.sectorStart }
        }
        let leadout = parsedLeadout > 0 ? parsedLeadout : currentSector

        let discID = OpticalDiscMetadataService.computeMusicBrainzDiscID(
            firstTrack: parsedFirstTrack,
            lastTrack: parsedLastTrack,
            leadoutSector: leadout,
            trackOffsets: trackOffsets
        )

        // If this disc is already loaded with the same discID, do not re-create or wipe out metadata
        if let current = detectedDisc, current.id == discID {
            return
        }

        let albumName = volumeURL.lastPathComponent == "Audio CD" ? "Audio CD" : volumeURL.lastPathComponent

        let newDisc = OpticalDisc(
            id: discID,
            title: albumName,
            artist: "Unknown Artist",
            tracks: opticalTracks,
            volumeURL: volumeURL,
            deviceName: driveName,
            isSimulated: false
        )

        self.detectedDisc = newDisc
        self.statusMessage = "Audio CD detected in \(driveName)"
        self.objectWillChange.send()

        // Fetch high-resolution metadata and artwork in background
        Task { [weak self] in
            await self?.refreshMetadataForCurrentDisc(trackOffsets: trackOffsets, leadoutSector: leadout)
        }
    }

    // MARK: - Metadata Refresh

    public func refreshMetadataForCurrentDisc(trackOffsets: [Int] = [], leadoutSector: Int = 0) async {
        guard let disc = detectedDisc else { return }

        self.isScanning = true
        self.statusMessage = "Fetching album metadata & artwork from MusicBrainz…"
        self.objectWillChange.send()

        let offsets = trackOffsets.isEmpty ? disc.tracks.map { $0.sectorStart } : trackOffsets
        let leadout = leadoutSector == 0 ? ((offsets.last ?? 0) + (disc.tracks.last?.sectorCount ?? 15000)) : leadoutSector

        let meta = await OpticalDiscMetadataService.shared.fetchMetadata(
            discID: disc.id,
            trackOffsets: offsets,
            leadoutSector: leadout,
            fallbackTitle: disc.title,
            fallbackArtist: disc.artist
        )

        // Ensure disc has not been ejected or changed while network request was in flight
        guard var currentDisc = detectedDisc, currentDisc.id == disc.id else {
            self.isScanning = false
            return
        }

        if !meta.title.isEmpty { currentDisc.title = meta.title }
        if !meta.artist.isEmpty { currentDisc.artist = meta.artist }
        if meta.year != nil { currentDisc.year = meta.year }
        if meta.genre != nil { currentDisc.genre = meta.genre }
        if meta.mbid != nil { currentDisc.mbid = meta.mbid }
        if meta.barcode != nil { currentDisc.barcode = meta.barcode }
        if meta.artworkData != nil { currentDisc.artworkData = meta.artworkData }
        if meta.artworkURL != nil { currentDisc.artworkURL = meta.artworkURL }

        // Update track titles and artists
        for i in 0..<currentDisc.tracks.count {
            let trackNum = currentDisc.tracks[i].trackNumber
            if let tTitle = meta.trackTitles[trackNum], !tTitle.isEmpty {
                currentDisc.tracks[i].title = tTitle
            }
            if let tArtist = meta.trackArtists[trackNum], !tArtist.isEmpty {
                currentDisc.tracks[i].artist = tArtist
            } else if !currentDisc.artist.isEmpty && currentDisc.artist != "Unknown Artist" {
                currentDisc.tracks[i].artist = currentDisc.artist
            }
        }

        self.detectedDisc = currentDisc
        self.isScanning = false
        self.statusMessage = "Loaded: \(currentDisc.artist) - \(currentDisc.title)"
        self.objectWillChange.send()
    }

    // MARK: - Disc Playback & Track Conversion

    /// Converts an `OpticalTrack` into an `AudioFile.Track` so that `AudioEngine` can play it directly from the disc.
    public func makePlayableTrack(from opticalTrack: OpticalTrack) -> Track {
        let disc = detectedDisc
        let albumTitle = disc?.title.isEmpty == false ? disc!.title : "Audio CD"
        let artistName = opticalTrack.artist.isEmpty ? (disc?.artist ?? "Unknown Artist") : opticalTrack.artist

        return Track(
            id: "optical_\(opticalTrack.id)",
            path: opticalTrack.sourceURL,
            title: opticalTrack.title,
            artist: artistName,
            album: albumTitle,
            trackNumber: opticalTrack.trackNumber,
            duration: opticalTrack.duration,
            format: "CDDA",
            sampleRate: 44100,
            bitDepth: 16,
            bitrate: 1411,
            hasCoverArt: disc?.artworkData != nil
        )
    }

    public func makeAllPlayableTracks() -> [Track] {
        guard let disc = detectedDisc else { return [] }
        return disc.tracks.map { makePlayableTrack(from: $0) }
    }

    // MARK: - Eject

    public func eject() {
        // 1. Eject via DiscRecording if device available
        if let devices = DRDevice.devices() as? [DRDevice] {
            for dev in devices {
                dev.ejectMedia()
            }
        }

        // 2. Unmount volume via NSWorkspace
        if let vol = detectedDisc?.volumeURL {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: vol)
        }

        // 3. Fallback CLI eject
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
        proc.arguments = ["eject"]
        try? proc.run()

        ejectCurrentDiscUI()
    }

    private func ejectCurrentDiscUI() {
        detectedDisc = nil
        statusMessage = "Optical disc ejected."

        NotificationCenter.default.post(name: NSNotification.Name("OpticalDiscEjected"), object: nil)
    }

    public func updateTrackRipState(trackNumber: Int, state: RipTrackState) {
        guard var disc = detectedDisc else { return }
        if let idx = disc.tracks.firstIndex(where: { $0.trackNumber == trackNumber }) {
            disc.tracks[idx].ripState = state
            self.detectedDisc = disc
        }
    }
}
