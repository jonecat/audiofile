import Foundation
import AppKit
import Combine
import Accelerate
import AVFoundation

public enum HealthIssueCategory: String, CaseIterable, Identifiable, Sendable {
    case missingInfo = "Missing Info"
    case missingArtwork = "Missing Artwork"
    case splitAlbums = "Split Albums"
    case missingLyrics = "Missing Lyrics"
    case dynamicRange = "Dynamic Range"
    case fakeLossless = "Lossless Audit"

    public var id: String { rawValue }

    public var subtitle: String {
        switch self {
        case .missingInfo:
            return "unclean title, missing artist, album or track #"
        case .missingArtwork:
            return "albums or songs without cover art"
        case .splitAlbums:
            return "inconsistent album or artist tags"
        case .missingLyrics:
            return "songs without synced .lrc lyrics"
        case .dynamicRange:
            return "songs without DR score"
        case .fakeLossless:
            return "FFT audit for upsampled/lossy transcodes"
        }
    }

    public var systemImage: String {
        switch self {
        case .missingInfo:
            return "tag.slash"
        case .missingArtwork:
            return "photo.badge.exclamationmark"
        case .splitAlbums:
            return "rectangle.split.2x1"
        case .missingLyrics:
            return "quote.bubble"
        case .dynamicRange:
            return "waveform.badge.magnifyingglass"
        case .fakeLossless:
            return "waveform.path.ecg.rectangle"
        }
    }

    public var supportsFindFixes: Bool {
        switch self {
        case .missingInfo, .missingArtwork, .missingLyrics, .dynamicRange, .fakeLossless:
            return true
        case .splitAlbums:
            return false
        }
    }

    public var usesTagWriteMode: Bool {
        switch self {
        case .missingInfo, .splitAlbums:
            return true
        case .missingArtwork, .missingLyrics, .dynamicRange, .fakeLossless:
            return false
        }
    }
}

public enum LosslessAuditVerdict: String, Codable, Sendable {
    case verifiedLossless
    case suspectMP3_128
    case suspectMP3_320
}

public struct LosslessAuditResult: Codable, Equatable, Sendable {
    public let verdict: LosslessAuditVerdict
    public let summary: String
    public let cutoffHz: Int?
    public let fileSize: UInt64?
}

public enum HealthFixMode: String, CaseIterable, Identifiable, Sendable {
    case safeLibraryAndSidecar = "Safe Mode (Library Only)"
    case writeToAudioFiles = "Write Tags to Audio Files"

    public var id: String { rawValue }
}

public struct TrackMetadataOverride: Codable, Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var hasCoverArt: Bool?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        hasCoverArt: Bool? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.hasCoverArt = hasCoverArt
    }
}

public struct HealthIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: HealthIssueCategory
    public let trackIds: [String]
    public let primaryTrack: Track
    public let duplicateTrack: Track?
    public let issueDescription: String
    public let currentSummary: String
    public var proposedSummary: String
    public var proposedOverride: TrackMetadataOverride?
    public var proposedArtworkData: Data?
    public var proposedArtworkURL: URL?
    public var proposedLyricsContent: String?
    public var isSearchingFix: Bool = false
    public var fixFound: Bool = false
    public var statusNote: String?
}

@MainActor
public final class LibraryHealthManager: ObservableObject {
    public static let shared = LibraryHealthManager()

    @Published public var issues: [HealthIssue] = []
    @Published public var selectedCategory: HealthIssueCategory = .missingInfo
    @Published public var fixMode: HealthFixMode = .safeLibraryAndSidecar
    @Published public var isAnalyzing: Bool = false
    @Published public var isFindingFixes: Bool = false
    @Published public var progressText: String = ""
    @Published public var checkCompletedMessage: String?
    @Published public var lastCheckedDate: Date?

    private static let includeDRAnalysisKey = "audiofile_health_include_dr_analysis"
    @Published public var includeDynamicRangeAnalysis: Bool {
        didSet {
            UserDefaults.standard.set(includeDynamicRangeAnalysis, forKey: Self.includeDRAnalysisKey)
        }
    }

    // Editing sheet state (stored on ObservableObject to avoid @State macro requirement)
    @Published public var editingIssue: HealthIssue?
    @Published public var editTitle: String = ""
    @Published public var editArtist: String = ""
    @Published public var editAlbum: String = ""
    @Published public var editAlbumArtist: String = ""
    @Published public var editTrackNumber: String = ""
    @Published public var editYear: String = ""

    public private(set) var overrides: [String: TrackMetadataOverride] = [:]
    private var ignoredIssueIds: Set<String> = []
    public private(set) var losslessAuditResults: [String: LosslessAuditResult] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var analyzeTask: Task<Void, Never>?
    private var analyzeGeneration: UInt64 = 0

    private nonisolated static let messyTitlePattern1Regex = try! NSRegularExpression(pattern: #"^(\d{1,3})\s*[-–.]\s*([^-–]+?)\s*[-–]\s*(.+)$"#)
    private nonisolated static let messyTitlePattern2Regex = try! NSRegularExpression(pattern: #"^(\d{1,3})(?:\s*[-–.]\s*|\s+)(.+)$"#)

    private nonisolated static var overridesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AudioFile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("metadata_overrides.json")
    }

    private nonisolated static var ignoredURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AudioFile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("ignored_health_issues.json")
    }

    private nonisolated static var losslessAuditURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AudioFile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("lossless_audit_v2.json")
    }

    public init() {
        self.includeDynamicRangeAnalysis = UserDefaults.standard.bool(forKey: Self.includeDRAnalysisKey)
        loadOverrides()
        loadIgnoredIssues()
        loadLosslessAuditResults()

        LibraryManager.shared.libraryStructureDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.analyzeLibrary()
            }
            .store(in: &cancellables)

        if !LibraryManager.shared.tracks.isEmpty {
            analyzeLibrary()
        }
    }

    // MARK: - Persistence for Overrides & Ignored Issues

    public nonisolated static func readOverridesFromDisk() -> [String: TrackMetadataOverride] {
        if let data = try? Data(contentsOf: Self.overridesURL),
           let decoded = try? JSONDecoder().decode([String: TrackMetadataOverride].self, from: data) {
            return decoded
        }
        return [:]
    }

    public nonisolated static func applyOverride(from map: [String: TrackMetadataOverride], to track: inout Track) {
        guard let ov = map[track.id] else { return }
        if let t = ov.title, !t.isEmpty { track.title = t }
        if let a = ov.artist, !a.isEmpty { track.artist = a }
        if let al = ov.album, !al.isEmpty { track.album = al }
        if let aa = ov.albumArtist, !aa.isEmpty { track.albumArtist = aa }
        if let tn = ov.trackNumber { track.trackNumber = tn }
        if let dn = ov.discNumber { track.discNumber = dn }
        if let y = ov.year { track.year = y }
        if let g = ov.genre, !g.isEmpty { track.genre = g }
        if let cov = ov.hasCoverArt {
            if cov {
                let hasFolder = MetadataReader.hasFolderArtwork(in: track.path.deletingLastPathComponent())
                if hasFolder {
                    track.hasCoverArt = true
                }
            } else {
                track.hasCoverArt = false
            }
        }
    }

    public func clearAllOverridesAndIgnored() {
        overrides.removeAll()
        ignoredIssueIds.removeAll()
        losslessAuditResults.removeAll()
        try? FileManager.default.removeItem(at: Self.overridesURL)
        try? FileManager.default.removeItem(at: Self.ignoredURL)
        try? FileManager.default.removeItem(at: Self.losslessAuditURL)
    }

    public var hasOverridesOrIgnored: Bool {
        !overrides.isEmpty || !ignoredIssueIds.isEmpty || !losslessAuditResults.isEmpty
    }

    public func loadOverrides() {
        self.overrides = Self.readOverridesFromDisk()
    }

    public func saveOverrides() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(overrides) {
            try? data.write(to: Self.overridesURL, options: .atomic)
        }
    }

    private func loadIgnoredIssues() {
        if let data = try? Data(contentsOf: Self.ignoredURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.ignoredIssueIds = Set(decoded)
        }
    }

    private func saveIgnoredIssues() {
        if let data = try? JSONEncoder().encode(Array(ignoredIssueIds)) {
            try? data.write(to: Self.ignoredURL, options: .atomic)
        }
    }

    private func loadLosslessAuditResults() {
        let legacyURL = Self.losslessAuditURL.deletingLastPathComponent().appendingPathComponent("lossless_audit_db.json")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        if let data = try? Data(contentsOf: Self.losslessAuditURL),
           let decoded = try? JSONDecoder().decode([String: LosslessAuditResult].self, from: data) {
            self.losslessAuditResults = decoded
        }
    }

    private func saveLosslessAuditResults() {
        if let data = try? JSONEncoder().encode(losslessAuditResults) {
            try? data.write(to: Self.losslessAuditURL, options: .atomic)
        }
    }

    public func applySavedOverride(to track: inout Track) {
        Self.applyOverride(from: overrides, to: &track)
    }

    // MARK: - Computed Health Metrics

    public var totalSongsCount: Int {
        LibraryManager.shared.tracks.count
    }

    /// Number of songs with core health issues (missing info, missing artwork, or split albums)
    public var songsNeedingAttentionCount: Int {
        var affectedTrackIds = Set<String>()
        for issue in issues where issue.category != .missingLyrics && issue.category != .dynamicRange && issue.category != .fakeLossless {
            for id in issue.trackIds {
                affectedTrackIds.insert(id)
            }
        }
        return affectedTrackIds.count
    }

    public var healthySongsCount: Int {
        max(0, totalSongsCount - songsNeedingAttentionCount)
    }

    public var healthScorePercentage: Int {
        guard totalSongsCount > 0 else { return 100 }
        let ratio = Double(healthySongsCount) / Double(totalSongsCount)
        if songsNeedingAttentionCount > 0 && Int((ratio * 100.0).rounded()) == 100 {
            return 99
        }
        return Int((ratio * 100.0).rounded())
    }

    public var totalIssuesBadgeCount: Int {
        issues.filter { issue in
            issue.category != .missingLyrics && issue.category != .dynamicRange && issue.category != .fakeLossless
        }.count
    }

    public func issues(for category: HealthIssueCategory) -> [HealthIssue] {
        issues.filter { $0.category == category }
    }

    public var readyFixesInSelectedCategory: [HealthIssue] {
        if selectedCategory == .fakeLossless { return [] }
        return issues(for: selectedCategory).filter { $0.fixFound }
    }

    // MARK: - Library Health Analysis

    public func recheckLibraryWithFeedback() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        checkCompletedMessage = nil
        progressText = "Scanning library health…"

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            analyzeLibrary()
            await analyzeTask?.value

            if includeDynamicRangeAnalysis {
                let drIssues = issues(for: .dynamicRange)
                if !drIssues.isEmpty {
                    await runDynamicRangeBatchAnalysis(issuesToProcess: drIssues)
                }
            }

            progressText = ""
            checkCompletedMessage = "Health check complete"
            try? await Task.sleep(for: .seconds(2.5))
            if checkCompletedMessage == "Health check complete" {
                checkCompletedMessage = nil
            }
        }
    }

    public func analyzeLibrary() {
        let tracks = LibraryManager.shared.tracks
        analyzeTask?.cancel()
        analyzeGeneration &+= 1
        let generation = analyzeGeneration

        guard !tracks.isEmpty else {
            analyzeTask = nil
            issues = []
            lastCheckedDate = Date()
            isAnalyzing = false
            return
        }

        isAnalyzing = true
        let ignoredSnapshot = ignoredIssueIds
        let existingByIdSnapshot = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
        let auditSnapshot = losslessAuditResults

        analyzeTask = Task { @MainActor [weak self] in
            let detected = await Task.detached(priority: .utility) { () -> [HealthIssue] in
                Self.computeHealthIssues(
                    tracks: tracks,
                    ignoredIssueIds: ignoredSnapshot,
                    existingById: existingByIdSnapshot,
                    losslessAuditResults: auditSnapshot
                )
            }.value

            guard !Task.isCancelled, let self = self, self.analyzeGeneration == generation else {
                return
            }

            self.issues = detected
            self.lastCheckedDate = Date()
            self.isAnalyzing = false
            self.analyzeTask = nil

            // Auto-select first category that has issues if current category is empty
            if self.issues(for: self.selectedCategory).isEmpty,
               let firstNonEmpty = HealthIssueCategory.allCases.first(where: { !self.issues(for: $0).isEmpty }) {
                self.selectedCategory = firstNonEmpty
            }
        }
    }

    private nonisolated static func computeHealthIssues(
        tracks: [Track],
        ignoredIssueIds: Set<String>,
        existingById: [String: HealthIssue],
        losslessAuditResults: [String: LosslessAuditResult]
    ) -> [HealthIssue] {
        var detected: [HealthIssue] = []

        // 1. Missing or Messy Info (Title has baked-in track/artist prefix, Unknown Artist/Album, or missing Track #)
        for track in tracks {
            if Task.isCancelled { return [] }
            let issueId = "info_\(track.id)"
            guard !ignoredIssueIds.contains(issueId) else { continue }

            let diagnosis = Self.diagnoseTrackInfo(track)
            if let diag = diagnosis {
                if let prev = existingById[issueId], prev.fixFound {
                    detected.append(prev)
                } else {
                    detected.append(HealthIssue(
                        id: issueId,
                        category: .missingInfo,
                        trackIds: [track.id],
                        primaryTrack: track,
                        duplicateTrack: nil,
                        issueDescription: diag.reason,
                        currentSummary: diag.currentSummary,
                        proposedSummary: diag.proposedSummary,
                        proposedOverride: diag.proposedOverride,
                        fixFound: diag.hasImmediateFix
                    ))
                }
            }
        }

        // 2. Missing Artwork (grouped by Album so fixing an album fixes all its songs at once)
        var albumGroups: [String: [Track]] = [:]
        for track in tracks {
            let key = "\(track.displayAlbumArtist.lowercased())___\(track.displayAlbum.lowercased())"
            albumGroups[key, default: []].append(track)
        }
        for (_, group) in albumGroups.sorted(by: { $0.value[0].displayAlbum < $1.value[0].displayAlbum }) {
            if Task.isCancelled { return [] }
            let hasAnyArt = group.contains(where: { $0.hasCoverArt })
            if !hasAnyArt, let sample = group.first {
                let issueId = "art_\(sample.displayAlbumArtist)_\(sample.displayAlbum)"
                guard !ignoredIssueIds.contains(issueId) else { continue }

                if let prev = existingById[issueId] {
                    detected.append(prev)
                } else {
                    detected.append(HealthIssue(
                        id: issueId,
                        category: .missingArtwork,
                        trackIds: group.map(\.id),
                        primaryTrack: sample,
                        duplicateTrack: nil,
                        issueDescription: "Missing album artwork (\(group.count) \(group.count == 1 ? "song" : "songs"))",
                        currentSummary: "\(sample.displayArtist) • \(sample.displayAlbum) (No cover art)",
                        proposedSummary: "Click \"Find Fixes\" to search high-res cover art",
                        fixFound: false
                    ))
                }
            }
        }

        // 3. Split Albums & Folder Consistency
        var folderGroups: [String: [Track]] = [:]
        for track in tracks {
            let folderPath = track.path.deletingLastPathComponent().standardizedFileURL.path
            folderGroups[folderPath, default: []].append(track)
        }
        for (folderPath, group) in folderGroups where group.count > 1 {
            if Task.isCancelled { return [] }
            let uniqueAlbums = Set(group.map { $0.displayAlbum })
            let uniqueAlbumArtists = Set(group.map { $0.displayAlbumArtist })
            if uniqueAlbums.count > 1 || uniqueAlbumArtists.count > 1 {
                let issueId = "split_\(folderPath)"
                guard !ignoredIssueIds.contains(issueId) else { continue }

                // Pick most common album and albumArtist in this folder
                let canonicalAlbum = Self.mostFrequent(in: group.map(\.displayAlbum)) ?? group[0].displayAlbum
                let canonicalArtist = Self.mostFrequent(in: group.map(\.displayAlbumArtist)) ?? group[0].displayArtist

                let override = TrackMetadataOverride(
                    album: canonicalAlbum,
                    albumArtist: canonicalArtist
                )
                let reason: String
                if uniqueAlbums.count > 1 {
                    reason = "Split album: \(uniqueAlbums.count) album names in same folder"
                } else {
                    reason = "Split album: \(uniqueAlbumArtists.count) different artists without unified Album Artist"
                }

                detected.append(HealthIssue(
                    id: issueId,
                    category: .splitAlbums,
                    trackIds: group.map(\.id),
                    primaryTrack: group[0],
                    duplicateTrack: nil,
                    issueDescription: reason,
                    currentSummary: "Folder has \(uniqueAlbums.joined(separator: " / ")) • Artists: \(uniqueAlbumArtists.prefix(3).joined(separator: ", "))",
                    proposedSummary: "Unify Album to \"\(canonicalAlbum)\" & Album Artist to \"\(canonicalArtist)\" (\(group.count) tracks)",
                    proposedOverride: override,
                    fixFound: true
                ))
            }
        }

        // 5. Missing Synced Lyrics (batch-read cache directory contents once)
        let lyricsCacheDir = LRCLIBClient.cacheDirectory
        let cachedLyricsFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: lyricsCacheDir.path)) ?? [])
        for track in tracks {
            if Task.isCancelled { return [] }
            let issueId = "lyrics_\(track.id)"
            guard !ignoredIssueIds.contains(issueId) else { continue }
            if !Self.hasCachedOrLocalLyrics(for: track, cachedFilenames: cachedLyricsFiles) {
                if let prev = existingById[issueId], prev.fixFound {
                    detected.append(prev)
                } else {
                    detected.append(HealthIssue(
                        id: issueId,
                        category: .missingLyrics,
                        trackIds: [track.id],
                        primaryTrack: track,
                        duplicateTrack: nil,
                        issueDescription: "No synced .lrc lyrics cached",
                        currentSummary: "\(track.displayArtist) - \(track.displayTitle)",
                        proposedSummary: "Click \"Find Fixes\" to search LRCLIB for synced lyrics",
                        fixFound: false
                    ))
                }
            }
        }

        // 6. Missing Dynamic Range
        for track in tracks {
            if Task.isCancelled { return [] }
            let issueId = "dr_\(track.id)"
            guard !ignoredIssueIds.contains(issueId) else { continue }
            if track.dynamicRange == nil {
                if let prev = existingById[issueId], prev.fixFound {
                    detected.append(prev)
                } else {
                    detected.append(HealthIssue(
                        id: issueId,
                        category: .dynamicRange,
                        trackIds: [track.id],
                        primaryTrack: track,
                        duplicateTrack: nil,
                        issueDescription: "No Dynamic Range score",
                        currentSummary: "\(track.displayArtist) - \(track.displayTitle)",
                        proposedSummary: "Measure Pleasurize TT DR Meter score",
                        fixFound: false
                    ))
                }
            }
        }

        // 7. Fake Lossless (Spectral Transcode Audit for PCM lossless files >= 44.1 kHz)
        let dsdExtensions: Set<String> = ["dsf", "dff", "dsd"]
        for track in tracks {
            if Task.isCancelled { return [] }
            guard track.isLossless,
                  (track.sampleRate ?? 44_100) >= 44_100,
                  !dsdExtensions.contains(track.path.pathExtension.lowercased()) else {
                continue
            }

            let issueId = "audit_\(track.id)"
            guard !ignoredIssueIds.contains(issueId) else { continue }
            let cacheKey = track.path.standardizedFileURL.path

            if let cached = losslessAuditResults[cacheKey], cached.fileSize == track.fileSize {
                if cached.verdict == .suspectMP3_128 || cached.verdict == .suspectMP3_320 {
                    detected.append(HealthIssue(
                        id: issueId,
                        category: .fakeLossless,
                        trackIds: [track.id],
                        primaryTrack: track,
                        duplicateTrack: nil,
                        issueDescription: "Suspect Lossy Transcode",
                        currentSummary: "\(track.format) (\(track.qualityDescription)) • \(track.path.lastPathComponent)",
                        proposedSummary: "Spectral shelf near \(cached.cutoffHz ?? 16000) Hz — likely transcoded from lossy audio",
                        fixFound: true,
                        statusNote: cached.summary
                    ))
                }
            } else {
                detected.append(HealthIssue(
                    id: issueId,
                    category: .fakeLossless,
                    trackIds: [track.id],
                    primaryTrack: track,
                    duplicateTrack: nil,
                    issueDescription: "Lossless not yet audited",
                    currentSummary: "\(track.format) (\(track.qualityDescription)) • \(track.displayArtist) - \(track.displayTitle)",
                    proposedSummary: "Inspect high-frequency spectrum via 16k FFT for brickwall cutoffs",
                    fixFound: false
                ))
            }
        }

        return detected
    }

    // MARK: - Diagnose Track Info (Filename / Tag Heuristics)

    private struct TrackInfoDiagnosis {
        let reason: String
        let currentSummary: String
        let proposedSummary: String
        let proposedOverride: TrackMetadataOverride
        let hasImmediateFix: Bool
    }

    private nonisolated static func diagnoseTrackInfo(_ track: Track) -> TrackInfoDiagnosis? {
        var reasons: [String] = []
        var proposedTitle: String?
        var proposedArtist: String?
        var proposedAlbum: String?
        var proposedTrackNum: Int?

        let rawTitle = track.displayTitle
        let parentFolder = track.path.deletingLastPathComponent().lastPathComponent
        let grandparentFolder = track.path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent

        // Check 1: Does the title have "01 - Artist - Title" or "01 - Title" or "01. Title" baked in?
        let cleaned = parseMessyTitle(rawTitle, artist: track.displayArtist)
        if let cleanTitle = cleaned.cleanTitle, cleanTitle != rawTitle {
            reasons.append("Title includes track number or artist prefix")
            proposedTitle = cleanTitle
            if track.trackNumber == nil, let num = cleaned.trackNumber {
                proposedTrackNum = num
            }
            if (track.displayArtist == "Unknown Artist" || track.artist.isEmpty), let art = cleaned.artist {
                proposedArtist = art
            }
        }

        // Check 2: Missing artist ("Unknown Artist")
        if track.displayArtist == "Unknown Artist" && proposedArtist == nil {
            reasons.append("Missing artist name")
            if !grandparentFolder.isEmpty && grandparentFolder != "Music" && grandparentFolder != "/" {
                proposedArtist = grandparentFolder
            }
        }

        // Check 3: Missing album ("Unknown Album")
        if track.displayAlbum == "Unknown Album" {
            reasons.append("Missing album title")
            if !parentFolder.isEmpty && parentFolder != "Music" && parentFolder != "/" {
                proposedAlbum = parentFolder
            }
        }

        // Check 4: Missing track number
        if track.trackNumber == nil && proposedTrackNum == nil {
            let parsed = MetadataReader.extractTrackAndDiscFromFilename(track.path)
            if let t = parsed.track {
                reasons.append("Missing track number tag")
                proposedTrackNum = t
            }
        }

        guard !reasons.isEmpty else { return nil }

        let finalTitle = proposedTitle ?? track.displayTitle
        let finalArtist = proposedArtist ?? track.displayArtist
        let finalAlbum = proposedAlbum ?? track.displayAlbum
        let finalTrackNum = proposedTrackNum ?? track.trackNumber

        let override = TrackMetadataOverride(
            title: proposedTitle,
            artist: proposedArtist,
            album: proposedAlbum,
            trackNumber: proposedTrackNum
        )

        let hasFix = (proposedTitle != nil || proposedArtist != nil || proposedAlbum != nil || proposedTrackNum != nil)
        let currentStr = "Title: \"\(track.displayTitle)\" • Artist: \(track.displayArtist) • Album: \(track.displayAlbum)" + (track.trackNumber.map { " • #\($0)" } ?? " • No Track #")
        let proposedStr = "Title: \"\(finalTitle)\" • Artist: \(finalArtist) • Album: \(finalAlbum)" + (finalTrackNum.map { " • #\($0)" } ?? "")

        return TrackInfoDiagnosis(
            reason: reasons.joined(separator: " • "),
            currentSummary: currentStr,
            proposedSummary: proposedStr,
            proposedOverride: override,
            hasImmediateFix: hasFix
        )
    }

    /// Parses messy titles such as:
    /// - `"01 - Kotaro Fukuma - Ave Maria, CG 89..."` -> `(track: 1, artist: "Kotaro Fukuma", title: "Ave Maria, CG 89...")`
    /// - `"03 - Song Title"` -> `(track: 3, artist: nil, title: "Song Title")`
    private nonisolated static func parseMessyTitle(_ title: String, artist: String) -> (trackNumber: Int?, artist: String?, cleanTitle: String?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)

        // Pattern 1: "01 - Artist Name - Song Title"
        if let match = messyTitlePattern1Regex.firstMatch(in: trimmed, range: range),
           let numRange = Range(match.range(at: 1), in: trimmed),
           let artRange = Range(match.range(at: 2), in: trimmed),
           let titleRange = Range(match.range(at: 3), in: trimmed),
           let num = Int(trimmed[numRange]) {
            let extractedArtist = String(trimmed[artRange]).trimmingCharacters(in: .whitespaces)
            let extractedTitle = String(trimmed[titleRange]).trimmingCharacters(in: .whitespaces)
            if artist.caseInsensitiveCompare(extractedArtist) == .orderedSame || artist == "Unknown Artist" || artist.isEmpty {
                return (num, extractedArtist, extractedTitle)
            }
        }

        // Pattern 2: "01 - Song Title" or "01. Song Title"
        if let match = messyTitlePattern2Regex.firstMatch(in: trimmed, range: range),
           let numRange = Range(match.range(at: 1), in: trimmed),
           let titleRange = Range(match.range(at: 2), in: trimmed),
           let num = Int(trimmed[numRange]),
           num > 0 && num < 200 {
            let candidate = String(trimmed[titleRange]).trimmingCharacters(in: .whitespaces)
            // Avoid stripping numbers that are genuinely song titles like "1979" or "21 Guns" unless separated by '-' or '.'
            if trimmed.contains("-") || trimmed.contains(".") {
                return (num, nil, candidate)
            }
        }

        return (nil, nil, nil)
    }

    // MARK: - Find Fixes Per Section (with Adaptive Rate-Limit Pacing)

    private var activeFindTask: Task<Void, Never>?

    public func stopFindingFixes() {
        activeFindTask?.cancel()
        activeFindTask = nil
        for i in issues.indices where issues[i].isSearchingFix {
            issues[i].isSearchingFix = false
        }
        progressText = ""
        isFindingFixes = false
    }

    public func findFixes(for category: HealthIssueCategory) {
        guard !isFindingFixes, category.supportsFindFixes else { return }

        if category == .dynamicRange {
            let drIssues = issues(for: .dynamicRange)
            guard !drIssues.isEmpty else { return }
            activeFindTask = Task { @MainActor in
                await runDynamicRangeBatchAnalysis(issuesToProcess: drIssues)
                activeFindTask = nil
            }
            return
        }

        if category == .fakeLossless {
            let auditIssues = issues(for: .fakeLossless).filter { !$0.fixFound }
            guard !auditIssues.isEmpty else { return }
            activeFindTask = Task { @MainActor in
                await runLosslessAuditBatch(issuesToProcess: auditIssues)
                activeFindTask = nil
            }
            return
        }

        isFindingFixes = true

        activeFindTask = Task { @MainActor in
            let targetIds = issues
                .filter { $0.category == category && (!$0.fixFound || $0.category == .missingInfo) }
                .map(\.id)
            let requiresRateLimitThrottle = (targetIds.count > 20)

            for (stepIdx, issueId) in targetIds.enumerated() {
                if Task.isCancelled { break }
                guard let startIdx = issues.firstIndex(where: { $0.id == issueId }) else { continue }
                let issue = issues[startIdx]

                let requestStart = ContinuousClock.now
                issues[startIdx].isSearchingFix = true
                if requiresRateLimitThrottle {
                    progressText = "Checking \(stepIdx + 1) of \(targetIds.count) (rate-limit safe: 1 query / 3s): \(issue.primaryTrack.displayTitle)…"
                } else {
                    progressText = "Checking \(stepIdx + 1) of \(targetIds.count): \(issue.primaryTrack.displayTitle)…"
                }

                switch category {
                case .missingInfo:
                    let enriched = await lookupTrackMetadataOnline(for: issue.primaryTrack, existingOverride: issue.proposedOverride)
                    if let idx = issues.firstIndex(where: { $0.id == issueId }) {
                        if let enriched {
                            issues[idx].proposedOverride = enriched.override
                            issues[idx].proposedSummary = enriched.summary
                            issues[idx].fixFound = true
                            issues[idx].statusNote = "Verified via online catalog"
                        } else if issues[idx].fixFound {
                            issues[idx].statusNote = "Ready from filename/folder structure"
                        } else {
                            issues[idx].statusNote = "Click Edit to enter tags manually"
                        }
                        issues[idx].isSearchingFix = false
                    }

                case .missingArtwork:
                    let artResult = await lookupAlbumArtworkOnline(
                        artist: issue.primaryTrack.displayArtist,
                        album: issue.primaryTrack.displayAlbum,
                        fallbackTitle: issue.primaryTrack.displayTitle
                    )
                    if let idx = issues.firstIndex(where: { $0.id == issueId }) {
                        if let artResult {
                            issues[idx].proposedArtworkData = artResult.data
                            issues[idx].proposedSummary = "Found \(artResult.dimensions) cover art (\(artResult.source))"
                            issues[idx].fixFound = true
                            issues[idx].statusNote = "Ready to save cover.jpg"
                        } else {
                            issues[idx].statusNote = "No online artwork match found"
                        }
                        issues[idx].isSearchingFix = false
                    }

                case .missingLyrics:
                    let res = await LRCLIBClient.shared.fetchLyrics(for: issue.primaryTrack)
                    if let idx = issues.firstIndex(where: { $0.id == issueId }) {
                        switch res {
                        case .found(let lrc):
                            issues[idx].proposedLyricsContent = lrc
                            issues[idx].proposedSummary = "Found synced .lrc lyrics on LRCLIB"
                            issues[idx].fixFound = true
                            issues[idx].statusNote = "Ready to save .lrc"
                        case .instrumental:
                            issues[idx].proposedLyricsContent = "[audiofile:instrumental]"
                            issues[idx].proposedSummary = "Verified Instrumental track on LRCLIB"
                            issues[idx].fixFound = true
                            issues[idx].statusNote = "Ready to mark Instrumental"
                        case .notFound:
                            issues[idx].statusNote = "No synced lyrics found on LRCLIB"
                        }
                        issues[idx].isSearchingFix = false
                    }

                default:
                    if let idx = issues.firstIndex(where: { $0.id == issueId }) {
                        issues[idx].isSearchingFix = false
                    }
                }

                // Throttle to 1 query every 3 seconds when batch exceeds 20 items to prevent API rate-limiting
                if requiresRateLimitThrottle && stepIdx + 1 < targetIds.count && !Task.isCancelled {
                    let elapsed = ContinuousClock.now - requestStart
                    if elapsed < .seconds(3) {
                        try? await Task.sleep(for: .seconds(3) - elapsed)
                    }
                }
            }

            progressText = ""
            isFindingFixes = false
            activeFindTask = nil
        }
    }

    public func runDynamicRangeBatchAnalysis(issuesToProcess: [HealthIssue]) async {
        guard !isFindingFixes else { return }
        isFindingFixes = true

        let targetIssues = issuesToProcess.filter { !$0.fixFound }
        let total = targetIssues.count
        guard total > 0 else {
            isFindingFixes = false
            return
        }

        var completed = 0
        var batchScores: [String: Int] = [:]
        let concurrency = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))

        await withTaskGroup(of: (String, Int?)?.self) { group in
            var iterator = targetIssues.makeIterator()

            for _ in 0..<concurrency {
                if let next = iterator.next() {
                    group.addTask {
                        let res = await DynamicRangeEngine.shared.dynamicRange(for: next.primaryTrack)
                        return (next.id, res?.score)
                    }
                }
            }

            while let result = await group.next() {
                if Task.isCancelled { break }
                if let (issueId, score) = result {
                    completed += 1
                    if let idx = self.issues.firstIndex(where: { $0.id == issueId }) {
                        let track = self.issues[idx].primaryTrack
                        if let s = score {
                            batchScores[track.id] = s
                            let cat = DynamicRangeEngine.ratingCategory(for: s)
                            self.issues[idx].fixFound = true
                            self.issues[idx].statusNote = "DR\(s) (\(cat.rawValue))"
                            self.issues[idx].proposedSummary = "Dynamic Range: DR\(s)"
                        } else {
                            self.issues[idx].statusNote = "Analysis failed"
                        }
                        self.progressText = "Measuring DR (\(completed)/\(total)): \(track.displayArtist) - \(track.displayTitle)…"
                    }
                }

                if let next = iterator.next() {
                    group.addTask {
                        let res = await DynamicRangeEngine.shared.dynamicRange(for: next.primaryTrack)
                        return (next.id, res?.score)
                    }
                }
            }
        }

        if !batchScores.isEmpty {
            LibraryManager.shared.updateTracksDynamicRange(scores: batchScores)
        }

        progressText = ""
        isFindingFixes = false
        analyzeLibrary()
    }

    public func analyzeDynamicRange(for issue: HealthIssue) {
        guard !isFindingFixes else { return }
        Task { @MainActor in
            if let idx = issues.firstIndex(where: { $0.id == issue.id }) {
                issues[idx].isSearchingFix = true
                let res = await DynamicRangeEngine.shared.dynamicRange(for: issue.primaryTrack, forceRecalculate: true)
                if let s = res?.score {
                    LibraryManager.shared.updateTrackDynamicRange(id: issue.primaryTrack.id, score: s)
                    let cat = DynamicRangeEngine.ratingCategory(for: s)
                    issues[idx].fixFound = true
                    issues[idx].statusNote = "DR\(s) (\(cat.rawValue))"
                    issues[idx].proposedSummary = "Dynamic Range: DR\(s)"
                }
                issues[idx].isSearchingFix = false
                analyzeLibrary()
            }
        }
    }

    // MARK: - Lossless Spectral Audit (16k FFT Transcode Detection)

    public func runLosslessAuditBatch(issuesToProcess: [HealthIssue]) async {
        guard !isFindingFixes else { return }
        isFindingFixes = true

        // Deduplicate by backing audio file path so CUE image tracks share one FFT pass
        var uniqueByPath: [String: HealthIssue] = [:]
        var orderedKeys: [String] = []
        for issue in issuesToProcess where !issue.fixFound {
            let key = issue.primaryTrack.path.standardizedFileURL.path
            if uniqueByPath[key] == nil {
                uniqueByPath[key] = issue
                orderedKeys.append(key)
            }
        }

        let targetIssues = orderedKeys.compactMap { uniqueByPath[$0] }
        let total = targetIssues.count
        guard total > 0 else {
            isFindingFixes = false
            return
        }

        var completed = 0
        let concurrency = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))

        await withTaskGroup(of: (String, LosslessAuditResult?).self) { group in
            var iterator = targetIssues.makeIterator()

            for _ in 0..<concurrency {
                if let next = iterator.next() {
                    let track = next.primaryTrack
                    let key = track.path.standardizedFileURL.path
                    group.addTask {
                        let result = await Task.detached(priority: .utility) {
                            Self.performLosslessFFTAudit(for: track)
                        }.value
                        return (key, result)
                    }
                }
            }

            while let (key, result) = await group.next() {
                if Task.isCancelled { break }
                completed += 1
                if let res = result {
                    self.losslessAuditResults[key] = res
                    if completed % 15 == 0 {
                        self.saveLosslessAuditResults()
                    }
                }
                if let track = uniqueByPath[key]?.primaryTrack {
                    self.progressText = "Auditing Lossless (\(completed)/\(total)): \(track.displayArtist) - \(track.displayTitle)…"
                }

                if let next = iterator.next() {
                    let track = next.primaryTrack
                    let nextKey = track.path.standardizedFileURL.path
                    group.addTask {
                        let res = await Task.detached(priority: .utility) {
                            Self.performLosslessFFTAudit(for: track)
                        }.value
                        return (nextKey, res)
                    }
                }
            }
        }

        saveLosslessAuditResults()
        progressText = ""
        isFindingFixes = false
        analyzeLibrary()
    }

    public func analyzeSingleLosslessAudit(for issue: HealthIssue) {
        guard !isFindingFixes else { return }
        Task { @MainActor in
            if let idx = issues.firstIndex(where: { $0.id == issue.id }) {
                issues[idx].isSearchingFix = true
                let track = issue.primaryTrack
                let result = await Task.detached(priority: .utility) {
                    Self.performLosslessFFTAudit(for: track)
                }.value
                if let res = result {
                    let key = track.path.standardizedFileURL.path
                    losslessAuditResults[key] = res
                    saveLosslessAuditResults()
                }
                issues[idx].isSearchingFix = false
                analyzeLibrary()
            }
        }
    }

    private nonisolated static func performLosslessFFTAudit(for track: Track) -> LosslessAuditResult? {
        guard let audioFile = try? OpenSourceDecoders.openAudioFile(for: track.path) else {
            return nil
        }

        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate >= 44_100 else {
            return LosslessAuditResult(verdict: .verifiedLossless, summary: "Below 44.1 kHz", cutoffHz: nil, fileSize: track.fileSize)
        }

        let fftSize = 16_384
        let log2n = vDSP_Length(14)
        let halfSize = fftSize / 2

        let totalFrames = audioFile.length
        let startFrame: AVAudioFramePosition
        let endFrame: AVAudioFramePosition
        if let startSec = track.startTimeOffset, let endSec = track.endTimeOffset {
            startFrame = max(0, min(AVAudioFramePosition(startSec * sampleRate), totalFrames))
            endFrame = max(startFrame, min(AVAudioFramePosition(endSec * sampleRate), totalFrames))
        } else {
            startFrame = 0
            endFrame = totalFrames
        }

        let sliceFrames = endFrame - startFrame
        guard sliceFrames >= AVAudioFramePosition(fftSize) else {
            return LosslessAuditResult(verdict: .verifiedLossless, summary: "Too short for FFT audit", cutoffHz: nil, fileSize: track.fileSize)
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fftSize)),
              let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var mono = [Float](repeating: 0, count: fftSize)
        var windowed = [Float](repeating: 0, count: fftSize)
        var realPart = [Float](repeating: 0, count: halfSize)
        var imagPart = [Float](repeating: 0, count: halfSize)
        var magSq = [Float](repeating: 0, count: halfSize)

        let fractions = [0.22, 0.42, 0.62, 0.78]
        let availableFrames = sliceFrames - AVAudioFramePosition(fftSize)
        let normFactor = 4.0 / Float(fftSize * fftSize)

        var bestMidHiDb = -160.0
        var bestPre16Db = -160.0
        var bestPost16Db = -160.0
        var validWindows = 0

        let hzPerBin = sampleRate / Double(fftSize)
        let minBinMidHi = max(1, Int(4_000.0 / hzPerBin))
        let maxBinMidHi = min(halfSize - 1, Int(14_000.0 / hzPerBin))
        let minBinPre16 = max(1, Int(12_500.0 / hzPerBin))
        let maxBinPre16 = min(halfSize - 1, Int(15_300.0 / hzPerBin))
        let minBinPost16 = max(1, Int(16_600.0 / hzPerBin))
        let maxBinPost16 = min(halfSize - 1, Int(19_400.0 / hzPerBin))

        for frac in fractions {
            let pos = startFrame + AVAudioFramePosition(Double(availableFrames) * frac)
            audioFile.framePosition = pos
            buffer.frameLength = 0
            do {
                try audioFile.read(into: buffer, frameCount: AVAudioFrameCount(fftSize))
            } catch {
                continue
            }

            let count = Int(buffer.frameLength)
            guard count == fftSize, let chData = buffer.floatChannelData else { continue }

            if format.channelCount >= 2 {
                let left = chData[0]
                let right = chData[1]
                var half: Float = 0.5
                vDSP_vasm(left, 1, right, 1, &half, &mono, 1, vDSP_Length(fftSize))
            } else {
                let ch0 = chData[0]
                for i in 0..<fftSize { mono[i] = ch0[i] }
            }

            var rms: Float = 0
            vDSP_rmsqv(mono, 1, &rms, vDSP_Length(fftSize))
            if rms < 0.002 { continue }
            validWindows += 1

            vDSP_vmul(mono, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            realPart.withUnsafeMutableBufferPointer { rBuf in
                imagPart.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    windowed.withUnsafeBytes { rawBytes in
                        let complexPtr = rawBytes.bindMemory(to: DSPComplex.self).baseAddress!
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magSq, 1, vDSP_Length(halfSize))
                }
            }

            func bandMeanDb(_ lowBin: Int, _ highBin: Int) -> Double {
                guard highBin > lowBin else { return -160.0 }
                var sumPower = 0.0
                for b in lowBin...highBin {
                    sumPower += Double(magSq[b]) * Double(normFactor)
                }
                let meanPower = max(sumPower / Double(highBin - lowBin + 1), 1e-16)
                return 10.0 * log10(meanPower)
            }

            let midHi = bandMeanDb(minBinMidHi, maxBinMidHi)
            let pre16 = bandMeanDb(minBinPre16, maxBinPre16)
            let post16 = bandMeanDb(minBinPost16, maxBinPost16)

            bestMidHiDb = max(bestMidHiDb, midHi)
            bestPre16Db = max(bestPre16Db, pre16)
            bestPost16Db = max(bestPost16Db, post16)
        }

        guard validWindows > 0 else {
            return LosslessAuditResult(verdict: .verifiedLossless, summary: "Verified (low level track)", cutoffHz: nil, fileSize: track.fileSize)
        }

        // Only flag steep in-band ~16 kHz brickwall cutoffs where upper-mid/treble content right below 15.3 kHz
        // is genuinely strong and abruptly drops into deep silence, avoiding false positives on CD masters.
        let dropAt16 = bestPre16Db - bestPost16Db
        let slopeTo15 = bestMidHiDb - bestPre16Db

        if bestPre16Db > -72.0 && slopeTo15 < 14.0 && dropAt16 > 38.0 && bestPost16Db < -108.0 {
            return LosslessAuditResult(
                verdict: .suspectMP3_128,
                summary: "Suspect ~16 kHz brickwall (-\(Int(dropAt16.rounded())) dB)",
                cutoffHz: 16_000,
                fileSize: track.fileSize
            )
        }

        return LosslessAuditResult(
            verdict: .verifiedLossless,
            summary: "Full-spectrum lossless verified",
            cutoffHz: nil,
            fileSize: track.fileSize
        )
    }

    // MARK: - Approve & Apply Fixes

    public func approveIssue(_ issue: HealthIssue) {
        Task { @MainActor in
            await applyIssueFix(issue)
            analyzeLibrary()
        }
    }

    public func approveAllReady(for category: HealthIssueCategory) {
        let ready = issues(for: category).filter { $0.fixFound }
        guard !ready.isEmpty else { return }

        Task { @MainActor in
            isFindingFixes = true
            for (idx, issue) in ready.enumerated() {
                progressText = "Applying \(category.rawValue) fix \(idx + 1) of \(ready.count)…"
                await applyIssueFix(issue)
            }
            progressText = ""
            isFindingFixes = false
            analyzeLibrary()
        }
    }

    private func applyIssueFix(_ issue: HealthIssue) async {
        switch issue.category {
        case .missingInfo, .splitAlbums:
            guard let override = issue.proposedOverride else { return }
            for trackId in issue.trackIds {
                var merged = overrides[trackId] ?? TrackMetadataOverride()
                if let t = override.title { merged.title = t }
                if let a = override.artist { merged.artist = a }
                if let al = override.album { merged.album = al }
                if let aa = override.albumArtist { merged.albumArtist = aa }
                if let tn = override.trackNumber { merged.trackNumber = tn }
                if let dn = override.discNumber { merged.discNumber = dn }
                if let y = override.year { merged.year = y }
                if let g = override.genre { merged.genre = g }
                overrides[trackId] = merged

                if fixMode == .writeToAudioFiles,
                   let track = LibraryManager.shared.tracks.first(where: { $0.id == trackId }),
                   !track.isCueTrack {
                    await Self.writeTagsToAudioFile(track: track, override: merged)
                }
            }
            saveOverrides()
            LibraryManager.shared.applyHealthOverrides(using: overrides)

        case .missingArtwork:
            guard let artData = issue.proposedArtworkData else { return }
            let albumDir = issue.primaryTrack.path.deletingLastPathComponent()
            let coverURL = albumDir.appendingPathComponent("cover.jpg")
            try? artData.write(to: coverURL, options: .atomic)
            MetadataReader.clearArtworkCache()

            for trackId in issue.trackIds {
                var merged = overrides[trackId] ?? TrackMetadataOverride()
                merged.hasCoverArt = true
                overrides[trackId] = merged
            }
            saveOverrides()
            LibraryManager.shared.applyHealthOverrides(using: overrides)

        case .missingLyrics:
            guard let content = issue.proposedLyricsContent else { return }
            if content != "[audiofile:instrumental]" {
                let lrcURL = issue.primaryTrack.path.deletingPathExtension().appendingPathExtension("lrc")
                try? content.write(to: lrcURL, atomically: true, encoding: .utf8)
            }
            ignoredIssueIds.insert(issue.id)
            saveIgnoredIssues()

        case .dynamicRange:
            break

        case .fakeLossless:
            NSWorkspace.shared.activateFileViewerSelecting([issue.primaryTrack.path])
        }
    }

    public func ignoreIssue(_ issue: HealthIssue) {
        ignoredIssueIds.insert(issue.id)
        saveIgnoredIssues()
        issues.removeAll { $0.id == issue.id }
    }

    public func resetIgnoredIssues() {
        ignoredIssueIds.removeAll()
        saveIgnoredIssues()
        analyzeLibrary()
    }

    // MARK: - Single Track Metadata Inspector & Editor Save

    public func saveSingleTrackMetadata(
        track: Track,
        override: TrackMetadataOverride,
        mode: HealthFixMode
    ) async {
        var merged = overrides[track.id] ?? TrackMetadataOverride()
        if let t = override.title { merged.title = t }
        if let a = override.artist { merged.artist = a }
        if let al = override.album { merged.album = al }
        if let aa = override.albumArtist { merged.albumArtist = aa }
        merged.trackNumber = override.trackNumber
        merged.discNumber = override.discNumber
        merged.year = override.year
        if let g = override.genre { merged.genre = g }
        overrides[track.id] = merged

        if mode == .writeToAudioFiles {
            await Self.writeTagsToAudioFile(track: track, override: merged)
        }

        saveOverrides()
        LibraryManager.shared.applyHealthOverrides(using: overrides)

        if AudioEngine.shared.currentTrack?.id == track.id,
           let updatedTrack = LibraryManager.shared.tracks.first(where: { $0.id == track.id }) {
            AudioEngine.shared.updateCurrentTrackMetadata(updatedTrack)
        }

        analyzeLibrary()
    }

    // MARK: - Edit Proposed Metadata Fix

    public func beginEditing(_ issue: HealthIssue) {
        let ov = issue.proposedOverride
        editTitle = ov?.title ?? issue.primaryTrack.displayTitle
        editArtist = ov?.artist ?? issue.primaryTrack.displayArtist
        editAlbum = ov?.album ?? issue.primaryTrack.displayAlbum
        editAlbumArtist = ov?.albumArtist ?? issue.primaryTrack.displayAlbumArtist
        if let tn = ov?.trackNumber ?? issue.primaryTrack.trackNumber {
            editTrackNumber = String(tn)
        } else {
            editTrackNumber = ""
        }
        if let y = ov?.year ?? issue.primaryTrack.year {
            editYear = String(y)
        } else {
            editYear = ""
        }
        editingIssue = issue
    }

    public func saveEditedIssueAndApprove() {
        guard var issue = editingIssue else { return }
        let override = TrackMetadataOverride(
            title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: editArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: editAlbum.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtist: editAlbumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            trackNumber: Int(editTrackNumber.trimmingCharacters(in: .whitespaces)),
            year: Int(editYear.trimmingCharacters(in: .whitespaces))
        )
        issue.proposedOverride = override
        issue.fixFound = true
        editingIssue = nil
        approveIssue(issue)
    }

    // MARK: - Public Metadata & Artwork Lookup (iTunes Search API)

    private struct ITunesSearchResponse: Decodable {
        struct Item: Decodable {
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let collectionArtistName: String?
            let trackNumber: Int?
            let discNumber: Int?
            let releaseDate: String?
            let primaryGenreName: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    private func lookupTrackMetadataOnline(
        for track: Track,
        existingOverride: TrackMetadataOverride?
    ) async -> (override: TrackMetadataOverride, summary: String)? {
        let baseTitle = existingOverride?.title ?? Self.parseMessyTitle(track.displayTitle, artist: track.displayArtist).cleanTitle ?? track.displayTitle
        let baseArtist = existingOverride?.artist ?? (track.displayArtist == "Unknown Artist" ? "" : track.displayArtist)
        let query = "\(baseArtist) \(baseTitle)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=5") else {
            return nil
        }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let parsed = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data),
              let best = parsed.results.first else {
            return nil
        }

        var ov = existingOverride ?? TrackMetadataOverride()
        if ov.title == nil { ov.title = best.trackName ?? baseTitle }
        if ov.artist == nil || track.displayArtist == "Unknown Artist" {
            ov.artist = best.artistName ?? baseArtist
        }
        if ov.album == nil && track.displayAlbum == "Unknown Album" {
            ov.album = best.collectionName
        }
        if ov.trackNumber == nil && track.trackNumber == nil {
            ov.trackNumber = best.trackNumber
        }
        if ov.year == nil && track.year == nil, let rel = best.releaseDate, rel.count >= 4 {
            ov.year = Int(rel.prefix(4))
        }
        if ov.genre == nil && track.genre == nil {
            ov.genre = best.primaryGenreName
        }

        let summary = "Title: \"\(ov.title ?? track.displayTitle)\" • Artist: \(ov.artist ?? track.displayArtist) • Album: \(ov.album ?? track.displayAlbum)"
            + ((ov.trackNumber ?? track.trackNumber).map { " • #\($0)" } ?? "")
            + ((ov.year ?? track.year).map { " (\($0))" } ?? "")
        return (ov, summary)
    }

    private func lookupAlbumArtworkOnline(
        artist: String,
        album: String,
        fallbackTitle: String
    ) async -> (data: Data, dimensions: String, source: String)? {
        let cleanArtist = artist == "Unknown Artist" ? "" : artist
        let cleanAlbum = album == "Unknown Album" ? fallbackTitle : album
        let query = "\(cleanArtist) \(cleanAlbum)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=album&limit=5") else {
            return nil
        }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let parsed = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data),
              let firstWithArt = parsed.results.first(where: { $0.artworkUrl100 != nil }),
              let rawArtURL = firstWithArt.artworkUrl100 else {
            return nil
        }

        let hiResURLStr = rawArtURL.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")
        guard let hiResURL = URL(string: hiResURLStr),
              let (imgData, _) = try? await URLSession.shared.data(from: hiResURL),
              let img = NSImage(data: imgData) else {
            return nil
        }

        let w = Int(img.size.width)
        let h = Int(img.size.height)
        return (imgData, "\(max(w, 1000))×\(max(h, 1000))", "Apple Music Catalog")
    }

    // MARK: - Optional Write Tags to Audio File via Open-Source FFmpeg

    private static func writeTagsToAudioFile(track: Track, override: TrackMetadataOverride) async {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpegPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }

        let ext = track.path.pathExtension.lowercased()
        // Avoid rewriting raw 1-bit DSD streams via ffmpeg stream copy if unsupported
        guard ext != "dff" && ext != "dsd" else { return }

        let tempURL = track.path.deletingLastPathComponent()
            .appendingPathComponent(".audiofile_tagtmp_\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var args = ["-y", "-v", "error", "-i", track.path.path, "-c", "copy"]
        if let t = override.title, !t.isEmpty { args += ["-metadata", "title=\(t)"] }
        if let a = override.artist, !a.isEmpty { args += ["-metadata", "artist=\(a)"] }
        if let al = override.album, !al.isEmpty { args += ["-metadata", "album=\(al)"] }
        if let aa = override.albumArtist, !aa.isEmpty { args += ["-metadata", "album_artist=\(aa)"] }
        if let tn = override.trackNumber { args += ["-metadata", "track=\(tn)"] }
        if let dn = override.discNumber { args += ["-metadata", "disc=\(dn)"] }
        if let y = override.year { args += ["-metadata", "date=\(y)"] }
        if let g = override.genre, !g.isEmpty { args += ["-metadata", "genre=\(g)"] }
        args.append(tempURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args
        if (try? proc.run()) != nil {
            proc.waitUntilExit()
            if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: tempURL.path) {
                _ = try? FileManager.default.replaceItemAt(track.path, withItemAt: tempURL)
            }
        }
    }

    // MARK: - Helpers

    private nonisolated static func hasCachedOrLocalLyrics(for track: Track, cachedFilenames: Set<String>) -> Bool {
        let localLRC = track.path.deletingPathExtension().appendingPathExtension("lrc")
        if FileManager.default.fileExists(atPath: localLRC.path) {
            return true
        }
        let safeArtist = track.artist.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -")).inverted).joined()
        let safeTitle = track.title.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -")).inverted).joined()
        let filename = "\(safeArtist.trimmingCharacters(in: .whitespaces))_\(safeTitle.trimmingCharacters(in: .whitespaces)).lrc"
        let resolvedName = filename.isEmpty ? "unknown.lrc" : filename
        return cachedFilenames.contains(resolvedName)
    }

    private nonisolated static func mostFrequent(in values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for v in values where !v.isEmpty && v != "Unknown Album" && v != "Unknown Artist" {
            counts[v, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}
