import Foundation
import CryptoKit

public struct ParsedReleaseDate: Comparable, Hashable, Sendable {
    public let year: Int
    public let month: Int?
    public let day: Int?

    public init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var specificity: Int {
        if day != nil { return 3 }
        if month != nil { return 2 }
        return 1
    }

    public var sortKey: Int {
        year * 10_000 + (month ?? 13) * 100 + (day ?? 32)
    }

    public var formattedString: String {
        if let month, let day {
            return String(format: "%04d-%02d-%02d", year, month, day)
        } else if let month {
            return String(format: "%04d-%02d", year, month)
        } else {
            return String(format: "%04d", year)
        }
    }

    public static func < (lhs: ParsedReleaseDate, rhs: ParsedReleaseDate) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    public static func compare(_ a: ParsedReleaseDate?, _ b: ParsedReleaseDate?) -> ComparisonResult {
        switch (a, b) {
        case let (dA?, dB?):
            if dA.sortKey < dB.sortKey { return .orderedAscending }
            if dA.sortKey > dB.sortKey { return .orderedDescending }
            return .orderedSame
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        case (.none, .none):
            return .orderedSame
        }
    }

    public static func best(from dates: [ParsedReleaseDate]) -> ParsedReleaseDate? {
        var best: ParsedReleaseDate? = nil
        for d in dates {
            if best == nil || d.specificity > best!.specificity {
                best = d
                if d.specificity == 3 {
                    break
                }
            }
        }
        return best
    }

    private static let ymdRegex = try! NSRegularExpression(pattern: #"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[T\s].*)?$"#)
    private static let compactYmdRegex = try! NSRegularExpression(pattern: #"^(\d{4})(\d{2})(\d{2})(?:[T\s].*)?$"#)
    private static let ymRegex = try! NSRegularExpression(pattern: #"^(\d{4})[-/.](\d{1,2})(?:[T\s].*)?$"#)
    private static let yearRegex = try! NSRegularExpression(pattern: #"(?:^|\D)(\d{4})(?:\D|$)"#)

    public static func parse(_ raw: String?, fallbackYear: Int? = nil) -> ParsedReleaseDate? {
        if let raw {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let candidate: String
                if let tIdx = trimmed.firstIndex(of: "T") {
                    candidate = String(trimmed[..<tIdx]).trimmingCharacters(in: .whitespaces)
                } else if let spaceIdx = trimmed.firstIndex(of: " ") {
                    let prefix = String(trimmed[..<spaceIdx])
                    let rest = String(trimmed[trimmed.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
                    // Strip trailing time like "1972-02-01 08:00:00" while keeping prose dates like "Jan 12, 1969"
                    if prefix.count >= 4, prefix.prefix(4).allSatisfy(\.isNumber), !rest.isEmpty, rest.first?.isNumber == true {
                        candidate = prefix
                    } else {
                        candidate = trimmed
                    }
                } else {
                    candidate = trimmed
                }

                let nsRange = NSRange(candidate.startIndex..., in: candidate)

                // 1. YYYY[-/.]M{1,2}[-/.]D{1,2}
                if let match = ymdRegex.firstMatch(in: candidate, range: nsRange),
                   let yRange = Range(match.range(at: 1), in: candidate),
                   let mRange = Range(match.range(at: 2), in: candidate),
                   let dRange = Range(match.range(at: 3), in: candidate),
                   let y = Int(candidate[yRange]), (1000...2999).contains(y),
                   let rawM = Int(candidate[mRange]),
                   let rawD = Int(candidate[dRange]) {
                    let m = (1...12).contains(rawM) ? rawM : nil
                    let d = (m != nil && (1...31).contains(rawD)) ? rawD : nil
                    return ParsedReleaseDate(year: y, month: m, day: d)
                }

                // 2. Exact 8-digit YYYYMMDD
                if let match = compactYmdRegex.firstMatch(in: candidate, range: nsRange),
                   let yRange = Range(match.range(at: 1), in: candidate),
                   let mRange = Range(match.range(at: 2), in: candidate),
                   let dRange = Range(match.range(at: 3), in: candidate),
                   let y = Int(candidate[yRange]), (1000...2999).contains(y),
                   let m = Int(candidate[mRange]), (1...12).contains(m),
                   let d = Int(candidate[dRange]), (1...31).contains(d) {
                    return ParsedReleaseDate(year: y, month: m, day: d)
                }

                // 3. YYYY[-/.]M{1,2}
                if let match = ymRegex.firstMatch(in: candidate, range: nsRange),
                   let yRange = Range(match.range(at: 1), in: candidate),
                   let mRange = Range(match.range(at: 2), in: candidate),
                   let y = Int(candidate[yRange]), (1000...2999).contains(y),
                   let rawM = Int(candidate[mRange]) {
                    let m = (1...12).contains(rawM) ? rawM : nil
                    return ParsedReleaseDate(year: y, month: m, day: nil)
                }

                // 4. Any 4-digit year token (1000...2999)
                let matches = yearRegex.matches(in: candidate, range: nsRange)
                for match in matches {
                    if let yRange = Range(match.range(at: 1), in: candidate),
                       let y = Int(candidate[yRange]),
                       (1000...2999).contains(y) {
                        return ParsedReleaseDate(year: y, month: nil, day: nil)
                    }
                }
            }
        }

        if let fallbackYear, (1000...2999).contains(fallbackYear) {
            return ParsedReleaseDate(year: fallbackYear, month: nil, day: nil)
        }
        return nil
    }
}

public struct Track: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let path: URL
    public var title: String {
        didSet { rebuildCachedProperties() }
    }
    public var artist: String {
        didSet { rebuildCachedProperties() }
    }
    public var album: String {
        didSet { rebuildCachedProperties() }
    }
    public var albumArtist: String? {
        didSet { rebuildCachedProperties() }
    }
    public var genre: String? {
        didSet { rebuildCachedProperties() }
    }
    public var year: Int? {
        didSet { rebuildCachedProperties() }
    }
    public var releaseDate: String? {
        didSet { rebuildCachedProperties() }
    }
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval {
        didSet { rebuildCachedProperties() }
    }
    public var format: String {
        didSet { rebuildCachedProperties() }
    }
    public var sampleRate: Double? {
        didSet { rebuildCachedProperties() }
    }
    public var bitDepth: Int? {
        didSet { rebuildCachedProperties() }
    }
    public var bitrate: Int? {
        didSet { rebuildCachedProperties() }
    }
    public var hasCoverArt: Bool
    public var fileSize: UInt64?
    public var modifiedDate: Date?
    public var dynamicRange: Int?
    public var playCount: Int?
    public var startTimeOffset: TimeInterval?
    public var endTimeOffset: TimeInterval?
    public var replayGainTrackDb: Double?
    public var replayGainAlbumDb: Double?
    public var replayGainPeak: Double?

    public var isCueTrack: Bool {
        startTimeOffset != nil
    }

    // Precomputed display, formatting, and sort keys (not persisted)
    public private(set) var displayTitle: String = ""
    public private(set) var displayArtist: String = ""
    public private(set) var displayAlbum: String = ""
    public private(set) var displayAlbumArtist: String = ""
    public private(set) var artistSortKey: String = ""
    public private(set) var titleSortKey: String = ""
    public private(set) var albumSortKey: String = ""
    public private(set) var formattedDuration: String = "00:00"
    public private(set) var formattedSampleRate: String? = nil
    public private(set) var qualityColumnText: String = ""
    public private(set) var isLossless: Bool = false
    public private(set) var parsedReleaseDate: ParsedReleaseDate? = nil
    public private(set) var formattedReleaseDate: String? = nil
    public private(set) var releaseDateSortKey: Int = Int.max
    public private(set) var searchHaystack: String = ""

    private enum CodingKeys: String, CodingKey {
        case id, path, title, artist, album, albumArtist, genre, year, releaseDate
        case trackNumber, discNumber, duration, format, sampleRate, bitDepth, bitrate
        case hasCoverArt, fileSize, modifiedDate, dynamicRange, playCount
        case startTimeOffset, endTimeOffset, replayGainTrackDb, replayGainAlbumDb, replayGainPeak
    }

    public init(
        id: String? = nil,
        path: URL,
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        releaseDate: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval = 0,
        format: String,
        sampleRate: Double? = nil,
        bitDepth: Int? = nil,
        bitrate: Int? = nil,
        hasCoverArt: Bool = false,
        fileSize: UInt64? = nil,
        modifiedDate: Date? = nil,
        dynamicRange: Int? = nil,
        playCount: Int? = nil,
        startTimeOffset: TimeInterval? = nil,
        endTimeOffset: TimeInterval? = nil,
        replayGainTrackDb: Double? = nil,
        replayGainAlbumDb: Double? = nil,
        replayGainPeak: Double? = nil
    ) {
        self.path = path
        self.id = id ?? Track.generateId(for: path)
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.releaseDate = releaseDate
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.format = format
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.hasCoverArt = hasCoverArt
        self.fileSize = fileSize
        self.modifiedDate = modifiedDate
        self.dynamicRange = dynamicRange
        self.playCount = playCount
        self.startTimeOffset = startTimeOffset
        self.endTimeOffset = endTimeOffset
        self.replayGainTrackDb = replayGainTrackDb
        self.replayGainAlbumDb = replayGainAlbumDb
        self.replayGainPeak = replayGainPeak
        rebuildCachedProperties()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.path = try container.decode(URL.self, forKey: .path)
        self.title = try container.decode(String.self, forKey: .title)
        self.artist = try container.decode(String.self, forKey: .artist)
        self.album = try container.decode(String.self, forKey: .album)
        self.albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre)
        self.year = try container.decodeIfPresent(Int.self, forKey: .year)
        self.releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        self.trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        self.discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.format = try container.decode(String.self, forKey: .format)
        self.sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate)
        self.bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        self.bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        self.hasCoverArt = try container.decode(Bool.self, forKey: .hasCoverArt)
        self.fileSize = try container.decodeIfPresent(UInt64.self, forKey: .fileSize)
        self.modifiedDate = try container.decodeIfPresent(Date.self, forKey: .modifiedDate)
        self.dynamicRange = try container.decodeIfPresent(Int.self, forKey: .dynamicRange)
        self.playCount = try container.decodeIfPresent(Int.self, forKey: .playCount)
        self.startTimeOffset = try container.decodeIfPresent(TimeInterval.self, forKey: .startTimeOffset)
        self.endTimeOffset = try container.decodeIfPresent(TimeInterval.self, forKey: .endTimeOffset)
        self.replayGainTrackDb = try container.decodeIfPresent(Double.self, forKey: .replayGainTrackDb)
        self.replayGainAlbumDb = try container.decodeIfPresent(Double.self, forKey: .replayGainAlbumDb)
        self.replayGainPeak = try container.decodeIfPresent(Double.self, forKey: .replayGainPeak)
        rebuildCachedProperties()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try container.encodeIfPresent(genre, forKey: .genre)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encode(duration, forKey: .duration)
        try container.encode(format, forKey: .format)
        try container.encodeIfPresent(sampleRate, forKey: .sampleRate)
        try container.encodeIfPresent(bitDepth, forKey: .bitDepth)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encode(hasCoverArt, forKey: .hasCoverArt)
        try container.encodeIfPresent(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(modifiedDate, forKey: .modifiedDate)
        try container.encodeIfPresent(dynamicRange, forKey: .dynamicRange)
        try container.encodeIfPresent(playCount, forKey: .playCount)
        try container.encodeIfPresent(startTimeOffset, forKey: .startTimeOffset)
        try container.encodeIfPresent(endTimeOffset, forKey: .endTimeOffset)
        try container.encodeIfPresent(replayGainTrackDb, forKey: .replayGainTrackDb)
        try container.encodeIfPresent(replayGainAlbumDb, forKey: .replayGainAlbumDb)
        try container.encodeIfPresent(replayGainPeak, forKey: .replayGainPeak)
    }

    public static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id &&
        lhs.playCount == rhs.playCount &&
        lhs.dynamicRange == rhs.dynamicRange &&
        lhs.hasCoverArt == rhs.hasCoverArt &&
        lhs.title == rhs.title &&
        lhs.artist == rhs.artist &&
        lhs.album == rhs.album &&
        lhs.albumArtist == rhs.albumArtist &&
        lhs.trackNumber == rhs.trackNumber &&
        lhs.discNumber == rhs.discNumber &&
        lhs.year == rhs.year &&
        lhs.genre == rhs.genre &&
        lhs.duration == rhs.duration &&
        lhs.path == rhs.path &&
        lhs.format == rhs.format &&
        lhs.sampleRate == rhs.sampleRate &&
        lhs.bitDepth == rhs.bitDepth &&
        lhs.bitrate == rhs.bitrate &&
        lhs.releaseDate == rhs.releaseDate &&
        lhs.fileSize == rhs.fileSize &&
        lhs.modifiedDate == rhs.modifiedDate &&
        lhs.startTimeOffset == rhs.startTimeOffset &&
        lhs.endTimeOffset == rhs.endTimeOffset &&
        lhs.replayGainTrackDb == rhs.replayGainTrackDb &&
        lhs.replayGainAlbumDb == rhs.replayGainAlbumDb &&
        lhs.replayGainPeak == rhs.replayGainPeak
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private mutating func rebuildCachedProperties() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        displayTitle = trimmedTitle.isEmpty ? path.deletingPathExtension().lastPathComponent : trimmedTitle

        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        displayArtist = trimmedArtist.isEmpty ? "Unknown Artist" : trimmedArtist

        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        displayAlbum = trimmedAlbum.isEmpty ? "Unknown Album" : trimmedAlbum

        if let aa = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
           !aa.isEmpty,
           UUID(uuidString: aa) == nil {
            displayAlbumArtist = aa
        } else {
            displayAlbumArtist = displayArtist
        }

        let loweredArtist = displayArtist.lowercased()
        if loweredArtist.count > 4 && loweredArtist.hasPrefix("the ") {
            artistSortKey = String(loweredArtist.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        } else {
            artistSortKey = loweredArtist
        }
        titleSortKey = displayTitle.lowercased()
        albumSortKey = displayAlbum.lowercased()

        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let totalSeconds = Int(safeDuration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        formattedDuration = String(format: "%02d:%02d", minutes, seconds)

        let upperFormat = format.uppercased()
        isLossless = upperFormat == "FLAC" || upperFormat == "ALAC" || upperFormat == "WAV" || upperFormat == "AIFF" || upperFormat == "AIF" || upperFormat == "APE" || upperFormat == "DSD"

        if let rate = sampleRate, rate > 0 {
            if rate >= 1_000_000.0 {
                let mhz = rate / 1_000_000.0
                if upperFormat == "DSD", rate >= 2_000_000, let tier = Self.dsdTierLabel(for: rate) {
                    formattedSampleRate = String(format: "%.2f MHz (%@)", mhz, tier)
                } else {
                    formattedSampleRate = String(format: "%.2f MHz", mhz)
                }
            } else if rate >= 1000.0 {
                let khz = rate / 1000.0
                if khz == khz.rounded() {
                    formattedSampleRate = String(format: "%.0f kHz", khz)
                } else {
                    formattedSampleRate = String(format: "%.1f kHz", khz)
                }
            } else {
                formattedSampleRate = "\(Int(rate)) Hz"
            }
        } else {
            formattedSampleRate = nil
        }

        if let depth = bitDepth, depth > 0, let rateStr = formattedSampleRate {
            qualityColumnText = "\(depth)-bit • \(rateStr)"
        } else if let br = bitrate {
            if let rateStr = formattedSampleRate {
                qualityColumnText = "\(br) kbps • \(rateStr)"
            } else {
                qualityColumnText = "\(br) kbps"
            }
        } else if let rateStr = formattedSampleRate {
            qualityColumnText = rateStr
        } else {
            qualityColumnText = ""
        }

        parsedReleaseDate = ParsedReleaseDate.parse(releaseDate, fallbackYear: year)
        formattedReleaseDate = parsedReleaseDate?.formattedString
        releaseDateSortKey = parsedReleaseDate?.sortKey ?? Int.max

        searchHaystack = "\(title)\0\(artist)\0\(album)\0\(genre ?? "")\0\(formattedReleaseDate ?? "")\0\(path.path)".lowercased()
    }

    private static func dsdTierLabel(for rate: Double) -> String? {
        let ratio = Int((rate / 44_100.0).rounded())
        switch ratio {
        case 56...72: return "DSD64"
        case 112...144: return "DSD128"
        case 224...288: return "DSD256"
        case 448...576: return "DSD512"
        case 896...1152: return "DSD1024"
        default: return nil
        }
    }

    public static func generateId(for path: URL) -> String {
        let pathString = path.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(pathString.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    public var playCountValue: Int {
        playCount ?? 0
    }

    public var playCountSortKey: Int {
        playCount ?? 0
    }

    public var dynamicRangeSortKey: Int {
        dynamicRange ?? 0
    }

    public var formattedYear: String? {
        formattedReleaseDate ?? year.map { String($0) }
    }

    public var dsdTierLabel: String? {
        guard format.uppercased() == "DSD", let rate = sampleRate, rate >= 2_000_000 else {
            return nil
        }
        return Self.dsdTierLabel(for: rate)
    }

    public var shortQualityDescription: String? {
        if let depth = bitDepth, depth > 0, let rate = sampleRate, rate > 0 {
            if rate >= 1_000_000.0 {
                let mhz = rate / 1_000_000.0
                if let tier = dsdTierLabel {
                    return String(format: "%d-bit/%.2fMHz (%@)", depth, mhz, tier)
                }
                return String(format: "%d-bit/%.2fMHz", depth, mhz)
            } else {
                let khz = rate / 1000.0
                if khz == khz.rounded() {
                    return String(format: "%d-bit/%.0fkHz", depth, khz)
                } else {
                    return String(format: "%d-bit/%.1fkHz", depth, khz)
                }
            }
        } else if let depth = bitDepth, depth > 0 {
            return "\(depth)-bit"
        } else if let br = bitrate, br > 0, let rate = sampleRate, rate > 0 {
            let khz = rate / 1000.0
            if khz == khz.rounded() {
                return String(format: "%d kbps/%.0fkHz", br, khz)
            } else {
                return String(format: "%d kbps/%.1fkHz", br, khz)
            }
        } else if let br = bitrate, br > 0 {
            return "\(br) kbps"
        } else if let formattedRate = formattedSampleRate {
            return formattedRate.replacingOccurrences(of: " ", with: "")
        }
        return nil
    }

    public var qualityDescription: String {
        var parts: [String] = []

        if let depth = bitDepth, depth > 0 {
            parts.append("\(depth)-bit")
        } else if let br = bitrate, br > 0 {
            parts.append("\(br) kbps")
        }

        if let formattedRate = formattedSampleRate {
            parts.append(formattedRate)
        }

        if isLossless {
            parts.append("Lossless")
        }

        return parts.joined(separator: " • ")
    }

    public func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        return searchHaystack.contains(q)
    }
}
