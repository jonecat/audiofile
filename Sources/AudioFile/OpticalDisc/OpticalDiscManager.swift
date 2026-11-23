import Foundation
import AppKit
import AVFoundation
import Combine
import Darwin
import IOKit

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

    private struct MountedAudioCD: Sendable {
        let volumeURL: URL
        let bsdDevice: String
    }

    private struct ParsedDiscPayload: Sendable {
        let disc: OpticalDisc
        let trackOffsets: [Int]
        let leadout: Int
    }

    private var loadingVolumePath: String?
    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    public init() {
        setupDriveNotifications()
        checkForInsertedDisc()
    }

    // MARK: - Notifications

    private func setupDriveNotifications() {
        let mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor [weak self] in
                self?.handleVolumeMounted(volumeURL)
            }
        }

        let unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor [weak self] in
                self?.handleVolumeUnmounted(volumeURL)
            }
        }

        workspaceObservers = [mountObserver, unmountObserver]
    }

    private func handleVolumeMounted(_ volumeURL: URL?) {
        if let url = volumeURL {
            guard let cdMount = Self.mountedAudioCD(at: url) else {
                return
            }
            beginLoadingPhysicalAudioCD(cdMount)
        } else {
            checkForInsertedDisc()
        }
    }

    private func handleVolumeUnmounted(_ volumeURL: URL?) {
        guard let trackedPath = detectedDisc?.volumeURL?.standardizedFileURL.path ?? loadingVolumePath else {
            return
        }
        if let unmounted = volumeURL, unmounted.standardizedFileURL.path != trackedPath {
            return
        }
        let stillMounted = Self.mountedAudioCDs().contains {
            $0.volumeURL.standardizedFileURL.path == trackedPath
        }
        if !stillMounted {
            ejectCurrentDiscUI()
        }
    }

    // MARK: - Kernel Mount Table & Passive IORegistry Inspection

    private nonisolated static func cString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { rawBuffer in
            let length = rawBuffer.firstIndex(of: 0) ?? rawBuffer.count
            return String(decoding: rawBuffer.prefix(length), as: UTF8.self)
        }
    }

    private nonisolated static func mountedAudioCDs() -> [MountedAudioCD] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }

        let capacity = Int(count) + 4
        var entries = Array(repeating: statfs(), count: capacity)
        let actual = entries.withUnsafeMutableBufferPointer { buf in
            getfsstat(buf.baseAddress, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard actual > 0 else { return [] }

        var results: [MountedAudioCD] = []
        for fs in entries.prefix(Int(actual)) {
            if cString(from: fs.f_fstypename) == "cddafs" {
                let mountPath = cString(from: fs.f_mntonname)
                let devicePath = cString(from: fs.f_mntfromname)
                if !mountPath.isEmpty {
                    results.append(MountedAudioCD(
                        volumeURL: URL(fileURLWithPath: mountPath, isDirectory: true),
                        bsdDevice: devicePath
                    ))
                }
            }
        }
        return results
    }

    private nonisolated static func mountedAudioCD(at url: URL) -> MountedAudioCD? {
        let targetPath = url.standardizedFileURL.path
        return mountedAudioCDs().first {
            $0.volumeURL.standardizedFileURL.path == targetPath
        }
    }

    private nonisolated static func extractDriveName(from service: io_registry_entry_t) -> String? {
        guard let props = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "Device Characteristics" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) as? [String: Any] else {
            return nil
        }

        let vendor = (props["Vendor Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let product = (props["Product Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !vendor.isEmpty && !product.isEmpty {
            if product.range(of: vendor, options: [.anchored, .caseInsensitive]) != nil {
                return product
            }
            return "\(vendor) \(product)"
        }

        let combined = !product.isEmpty ? product : vendor
        return combined.isEmpty ? nil : combined
    }

    private nonisolated static func driveNameFromIOKit(bsdDevice: String?) -> String? {
        if let rawDevice = bsdDevice, !rawDevice.isEmpty {
            let bsdName = rawDevice.hasPrefix("/dev/") ? String(rawDevice.dropFirst(5)) : rawDevice
            if !bsdName.isEmpty {
                let service = IOServiceGetMatchingService(
                    kIOMainPortDefault,
                    IOBSDNameMatching(kIOMainPortDefault, 0, bsdName)
                )
                if service != 0 {
                    defer { IOObjectRelease(service) }
                    if let name = extractDriveName(from: service) {
                        return name
                    }
                }
            }
        }

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOCDBlockStorageDevice"),
            &iterator
        )
        guard kr == KERN_SUCCESS, iterator != 0 else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let name = extractDriveName(from: service)
            IOObjectRelease(service)
            if let name {
                return name
            }
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    private func updateConnectedDriveName(_ newName: String?) {
        if connectedDriveName != newName {
            connectedDriveName = newName
        }
    }

    // MARK: - Scan & Detect

    public func checkForInsertedDisc() {
        let cdMounts = Self.mountedAudioCDs()
        if let firstCD = cdMounts.first {
            updateConnectedDriveName(Self.driveNameFromIOKit(bsdDevice: firstCD.bsdDevice))
            if detectedDisc?.volumeURL?.standardizedFileURL.path == firstCD.volumeURL.standardizedFileURL.path {
                return
            }
            beginLoadingPhysicalAudioCD(firstCD)
        } else {
            updateConnectedDriveName(Self.driveNameFromIOKit(bsdDevice: nil))
            if detectedDisc != nil || loadingVolumePath != nil {
                ejectCurrentDiscUI()
            }
        }
    }

    private func beginLoadingPhysicalAudioCD(_ mount: MountedAudioCD) {
        let standardizedPath = mount.volumeURL.standardizedFileURL.path
        if detectedDisc?.volumeURL?.standardizedFileURL.path == standardizedPath || loadingVolumePath == standardizedPath {
            return
        }

        loadTask?.cancel()
        loadingVolumePath = standardizedPath

        let resolvedDriveName = Self.driveNameFromIOKit(bsdDevice: mount.bsdDevice)
        updateConnectedDriveName(resolvedDriveName)
        let displayDriveName = resolvedDriveName ?? "Optical Drive"

        loadTask = Task { [weak self] in
            let payload = await Self.readDiscPayload(at: mount.volumeURL, driveName: displayDriveName)
            guard let self = self else { return }

            guard !Task.isCancelled else { return }
            if self.loadingVolumePath == standardizedPath {
                self.loadingVolumePath = nil
            }

            guard Self.mountedAudioCD(at: mount.volumeURL) != nil,
                  let payload else {
                return
            }

            if let current = self.detectedDisc, current.id == payload.disc.id {
                return
            }

            self.detectedDisc = payload.disc
            self.statusMessage = "Audio CD detected in \(displayDriveName)"

            self.metadataTask?.cancel()
            self.metadataTask = Task { [weak self] in
                await self?.refreshMetadataForCurrentDisc(
                    trackOffsets: payload.trackOffsets,
                    leadoutSector: payload.leadout
                )
            }
        }
    }

    private nonisolated static func readDiscPayload(at volumeURL: URL, driveName: String) async -> ParsedDiscPayload? {
        await Task.detached(priority: .utility) {
            let retryDelaysNs: [UInt64] = [0, 500_000_000, 1_000_000_000]

            for delayNs in retryDelaysNs {
                if delayNs > 0 {
                    try? await Task.sleep(nanoseconds: delayNs)
                }
                guard !Task.isCancelled, Self.mountedAudioCD(at: volumeURL) != nil else {
                    return nil
                }

                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: volumeURL,
                    includingPropertiesForKeys: nil,
                    options: []
                ) else {
                    continue
                }

                let audioTrackFiles = files.filter {
                    let ext = $0.pathExtension.lowercased()
                    return ext == "aiff" || ext == "aif" || ext == "cdda"
                }.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }

                guard !audioTrackFiles.isEmpty else {
                    continue
                }

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

                    let nextStart = (idx + 1 < trackOffsets.count)
                        ? trackOffsets[idx + 1]
                        : (parsedLeadout > 0 ? parsedLeadout : (startSector + 15000))
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

                return ParsedDiscPayload(disc: newDisc, trackOffsets: trackOffsets, leadout: leadout)
            }

            return nil
        }.value
    }

    // MARK: - Metadata Refresh

    public func refreshMetadataForCurrentDisc(trackOffsets: [Int] = [], leadoutSector: Int = 0) async {
        guard let disc = detectedDisc, !isScanning else { return }

        self.isScanning = true
        self.statusMessage = "Fetching album metadata & artwork from MusicBrainz…"

        let offsets = trackOffsets.isEmpty ? disc.tracks.map { $0.sectorStart } : trackOffsets
        let leadout = leadoutSector == 0 ? ((offsets.last ?? 0) + (disc.tracks.last?.sectorCount ?? 15000)) : leadoutSector

        let meta = await OpticalDiscMetadataService.shared.fetchMetadata(
            discID: disc.id,
            trackOffsets: offsets,
            leadoutSector: leadout,
            fallbackTitle: disc.title,
            fallbackArtist: disc.artist
        )

        guard !Task.isCancelled else {
            self.isScanning = false
            return
        }

        // Ensure disc has not been ejected or changed while network request was in flight
        guard var currentDisc = detectedDisc, currentDisc.id == disc.id else {
            self.isScanning = false
            return
        }

        if !meta.title.isEmpty { currentDisc.title = meta.title }
        if !meta.artist.isEmpty { currentDisc.artist = meta.artist }
        if meta.year != nil { currentDisc.year = meta.year }
        if meta.releaseDate != nil { currentDisc.releaseDate = meta.releaseDate }
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
        let volURL = detectedDisc?.volumeURL

        if AudioEngine.shared.currentTrack?.id.hasPrefix("optical_") == true {
            AudioEngine.shared.stop()
        }

        ejectCurrentDiscUI()

        Task.detached(priority: .userInitiated) {
            var ejected = false
            if let vol = volURL {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: vol)
                    ejected = true
                } catch {
                    ejected = false
                }
            }

            if !ejected {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
                proc.arguments = ["eject"]
                try? proc.run()
                proc.waitUntilExit()
            }
        }
    }

    private func ejectCurrentDiscUI() {
        loadTask?.cancel()
        loadTask = nil
        metadataTask?.cancel()
        metadataTask = nil
        loadingVolumePath = nil
        isScanning = false

        if detectedDisc != nil {
            detectedDisc = nil
            statusMessage = "Optical disc ejected."
            NotificationCenter.default.post(name: NSNotification.Name("OpticalDiscEjected"), object: nil)
        }
    }

    public func updateTrackRipState(trackNumber: Int, state: RipTrackState) {
        guard var disc = detectedDisc else { return }
        if let idx = disc.tracks.firstIndex(where: { $0.trackNumber == trackNumber }) {
            disc.tracks[idx].ripState = state
            self.detectedDisc = disc
        }
    }
}
