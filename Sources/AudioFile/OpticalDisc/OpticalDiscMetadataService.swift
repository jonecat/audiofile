import Foundation
import AppKit
import CryptoKit

public actor OpticalDiscMetadataService {
    public static let shared = OpticalDiscMetadataService()

    private let userAgent = "AudioFile/1.0.0 ( contact@audiofile.app )"

    // MARK: - MusicBrainz DiscID Calculation

    /// Computes the official MusicBrainz DiscID from CD TOC parameters.
    /// Specifications:
    /// Format string: "%02X%02X%08X" (first track, last track, leadout sector)
    /// Followed by 99 8-digit hexadecimal sector offsets ("%08X") padded with 0.
    /// Resulting string is SHA-1 hashed and base64 encoded with character substitutions: '+' -> '.', '/' -> '_', '=' -> '-'.
    public static func computeMusicBrainzDiscID(
        firstTrack: Int,
        lastTrack: Int,
        leadoutSector: Int,
        trackOffsets: [Int]
    ) -> String {
        var s = String(format: "%02X%02X%08X", firstTrack, lastTrack, leadoutSector)
        for i in 0..<99 {
            let offset = i < trackOffsets.count ? trackOffsets[i] : 0
            s += String(format: "%08X", offset)
        }
        let sha1 = Insecure.SHA1.hash(data: Data(s.utf8))
        var b64 = Data(sha1).base64EncodedString()
        b64 = b64.replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
        return b64
    }

    // MARK: - Metadata Lookup

    public struct DiscMetadataResult: Sendable {
        public var title: String = ""
        public var artist: String = ""
        public var year: Int?
        public var releaseDate: String?
        public var genre: String?
        public var discNumber: Int?
        public var totalDiscs: Int?
        public var discSubtitle: String?
        public var mbid: String?
        public var barcode: String?
        public var artworkURL: URL?
        public var artworkData: Data?
        public var trackTitles: [Int: String] = [:]
        public var trackArtists: [Int: String] = [:]
    }

    /// Fetches metadata and high-resolution album artwork for an optical disc.
    public func fetchMetadata(
        discID: String,
        firstTrack: Int = 1,
        trackOffsets: [Int],
        leadoutSector: Int,
        fallbackTitle: String? = nil,
        fallbackArtist: String? = nil
    ) async -> DiscMetadataResult {
        var result = DiscMetadataResult()

        // 1. Query MusicBrainz by DiscID (with multi-disc medium matching & TOC fallback)
        let mbResult = await queryMusicBrainz(
            discID: discID,
            firstTrack: firstTrack,
            trackOffsets: trackOffsets,
            leadoutSector: leadoutSector
        )
        if let mb = mbResult {
            if !mb.title.isEmpty { result.title = mb.title }
            if !mb.artist.isEmpty { result.artist = mb.artist }
            if mb.year != nil { result.year = mb.year }
            if mb.releaseDate != nil { result.releaseDate = mb.releaseDate }
            if mb.genre != nil { result.genre = mb.genre }
            if mb.discNumber != nil { result.discNumber = mb.discNumber }
            if mb.totalDiscs != nil { result.totalDiscs = mb.totalDiscs }
            if mb.discSubtitle != nil { result.discSubtitle = mb.discSubtitle }
            if mb.mbid != nil { result.mbid = mb.mbid }
            if mb.barcode != nil { result.barcode = mb.barcode }
            for (num, title) in mb.trackTitles {
                result.trackTitles[num] = title
            }
            for (num, art) in mb.trackArtists {
                result.trackArtists[num] = art
            }
        }

        // 2. Fallbacks if still untitled
        if result.title.isEmpty, let fTitle = fallbackTitle, !fTitle.isEmpty {
            result.title = fTitle
        }
        if result.artist.isEmpty, let fArtist = fallbackArtist, !fArtist.isEmpty {
            result.artist = fArtist
        }

        // 3. Fetch High-Resolution Album Artwork
        // First try Cover Art Archive via MBID, then fallback to iTunes Search API (1400x1400)
        if let mbid = result.mbid {
            if let caaData = await fetchCoverArtArchive(mbid: mbid) {
                result.artworkData = caaData
            }
        }

        if result.artworkData == nil && !result.title.isEmpty && result.title != "Audio CD" {
            let queryArtist = result.artist.isEmpty ? "" : result.artist
            if let itunesArt = await fetchiTunesArtwork(artist: queryArtist, album: result.title) {
                result.artworkData = itunesArt.data
                result.artworkURL = itunesArt.url
            }
        }

        return result
    }

    // MARK: - MusicBrainz Query

    private func queryMusicBrainz(
        discID: String,
        firstTrack: Int,
        trackOffsets: [Int],
        leadoutSector: Int
    ) async -> DiscMetadataResult? {
        var bestResult: DiscMetadataResult? = nil
        var didMakeRequest = false

        // Step 1: Single-request exact MusicBrainz DiscID lookup with full includes
        let discIDURL = "https://musicbrainz.org/ws/2/discid/\(discID)?inc=artist-credits+recordings+release-groups+genres&fmt=json"
        didMakeRequest = true
        if let json = await performMusicBrainzJSONRequest(urlString: discIDURL),
           let releases = json["releases"] as? [[String: Any]],
           !releases.isEmpty {
            bestResult = Self.parseBestMetadata(
                fromReleases: releases,
                discID: discID,
                trackOffsets: trackOffsets,
                leadoutSector: leadoutSector
            )
        }

        // Step 2: Rate-limited fuzzy TOC fallback if exact DiscID did not match any usable release
        if bestResult == nil && !trackOffsets.isEmpty {
            if didMakeRequest {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            }
            let effectiveFirstTrack = max(1, firstTrack)
            let lastTrack = effectiveFirstTrack + trackOffsets.count - 1
            var tocParts = ["\(effectiveFirstTrack)", "\(lastTrack)", "\(leadoutSector)"]
            for off in trackOffsets { tocParts.append("\(off)") }
            let tocString = tocParts.joined(separator: "+")
            let fuzzyURL = "https://musicbrainz.org/ws/2/discid/-?toc=\(tocString)&inc=artist-credits+recordings+release-groups+genres&fmt=json"
            didMakeRequest = true
            if let json = await performMusicBrainzJSONRequest(urlString: fuzzyURL),
               let releases = json["releases"] as? [[String: Any]],
               !releases.isEmpty {
                bestResult = Self.parseBestMetadata(
                    fromReleases: releases,
                    discID: discID,
                    trackOffsets: trackOffsets,
                    leadoutSector: leadoutSector
                )
            }
        }

        // Step 3: Safety net — fetch full release if tracklist was omitted
        if let current = bestResult,
           current.trackTitles.isEmpty,
           let mbid = current.mbid,
           !mbid.isEmpty {
            if didMakeRequest {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            }
            let releaseURL = "https://musicbrainz.org/ws/2/release/\(mbid)?inc=artist-credits+recordings+release-groups+genres+discids&fmt=json"
            if let releaseJSON = await performMusicBrainzJSONRequest(urlString: releaseURL),
               let detailed = Self.parseBestMetadata(
                   fromReleases: [releaseJSON],
                   discID: discID,
                   trackOffsets: trackOffsets,
                   leadoutSector: leadoutSector
               ) {
                bestResult = detailed
            }
        }

        return bestResult
    }

    private func performMusicBrainzJSONRequest(urlString: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        for attempt in 0..<2 {
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse else {
                return nil
            }
            if http.statusCode == 200 {
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            if (http.statusCode == 503 || http.statusCode == 429), attempt == 0 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            }
            return nil
        }
        return nil
    }

    // MARK: - Release & Medium Matching

    /// Scores every `(release, medium)` candidate across MusicBrainz results so multi-disc editions
    /// resolve to the exact matching disc instead of blindly picking Disc 1 (`media.first`).
    public static func parseBestMetadata(
        fromReleases releases: [[String: Any]],
        discID: String,
        trackOffsets: [Int],
        leadoutSector: Int
    ) -> DiscMetadataResult? {
        let expectedDurationsMs = expectedDurationsMilliseconds(trackOffsets: trackOffsets, leadoutSector: leadoutSector)

        var bestCandidate: (release: [String: Any], medium: [String: Any], mediumIdx: Int, totalDiscs: Int, score: Int)? = nil

        for release in releases {
            guard let mediaList = release["media"] as? [[String: Any]], !mediaList.isEmpty else {
                continue
            }
            for (idx, medium) in mediaList.enumerated() {
                let candidateScore = scoreCandidate(
                    release: release,
                    medium: medium,
                    discID: discID,
                    trackOffsets: trackOffsets,
                    leadoutSector: leadoutSector,
                    expectedDurationsMs: expectedDurationsMs
                )
                if bestCandidate == nil || candidateScore > bestCandidate!.score {
                    bestCandidate = (release, medium, idx, mediaList.count, candidateScore)
                }
            }
        }

        guard let winner = bestCandidate else { return nil }
        return extractResult(
            from: winner.release,
            medium: winner.medium,
            mediumIndex: winner.mediumIdx,
            totalDiscs: winner.totalDiscs
        )
    }

    private static func expectedDurationsMilliseconds(trackOffsets: [Int], leadoutSector: Int) -> [Double] {
        guard !trackOffsets.isEmpty else { return [] }
        return (0..<trackOffsets.count).map { i in
            let nextSector = (i + 1 < trackOffsets.count) ? trackOffsets[i + 1] : leadoutSector
            guard nextSector > trackOffsets[i] else { return 0 }
            return Double(nextSector - trackOffsets[i]) / 75.0 * 1000.0
        }
    }

    private static func scoreCandidate(
        release: [String: Any],
        medium: [String: Any],
        discID: String,
        trackOffsets: [Int],
        leadoutSector: Int,
        expectedDurationsMs: [Double]
    ) -> Int {
        var score = 0
        let expectedTrackCount = trackOffsets.count
        let tracks = (medium["tracks"] as? [[String: Any]]) ?? []
        let mediumTrackCount = (medium["track-count"] as? Int) ?? tracks.count
        let discs = (medium["discs"] as? [[String: Any]]) ?? []

        // 1. Exact MusicBrainz DiscID match on this medium
        if discs.contains(where: { ($0["id"] as? String) == discID }) {
            score += 1_000_000
        }

        // 2. Track count match / mismatch penalty
        if expectedTrackCount > 0 {
            if mediumTrackCount == expectedTrackCount {
                score += 100_000
                if tracks.count == expectedTrackCount {
                    score += 20_000
                }
            } else {
                score -= 500_000 + abs(mediumTrackCount - expectedTrackCount) * 10_000
            }

            // 3. TOC offset & leadout proximity across attached discs
            var minSectorDelta: Int? = nil
            for d in discs {
                guard let mbOffsets = d["offsets"] as? [Int], mbOffsets.count == expectedTrackCount else {
                    continue
                }
                var delta = zip(mbOffsets, trackOffsets).reduce(0) { $0 + abs($1.0 - $1.1) }
                if leadoutSector > 0, let mbSectors = d["sectors"] as? Int, mbSectors > 0 {
                    delta += abs(mbSectors - leadoutSector)
                }
                if minSectorDelta == nil || delta < minSectorDelta! {
                    minSectorDelta = delta
                }
            }
            if let sectorDelta = minSectorDelta {
                score += max(0, 60_000 - min(60_000, sectorDelta))
            }

            // 4. Per-track duration proximity
            if tracks.count == expectedTrackCount, expectedDurationsMs.count == expectedTrackCount {
                let sortedTracks = tracks.enumerated().sorted { a, b in
                    trackPosition(a.element, fallbackIndex: a.offset) < trackPosition(b.element, fallbackIndex: b.offset)
                }.map(\.element)

                var totalDeltaMs = 0.0
                var comparedCount = 0
                for i in 0..<expectedTrackCount {
                    let expectedMs = expectedDurationsMs[i]
                    guard expectedMs > 0,
                          let mbLen = (sortedTracks[i]["length"] as? NSNumber)?.doubleValue else {
                        continue
                    }
                    totalDeltaMs += abs(mbLen - expectedMs)
                    comparedCount += 1
                }
                if comparedCount > 0 {
                    let meanDeltaMs = totalDeltaMs / Double(comparedCount)
                    if meanDeltaMs <= 3000.0 {
                        score += Int(40_000.0 - min(40_000.0, meanDeltaMs * 10.0))
                    } else {
                        score -= min(100_000, Int(meanDeltaMs))
                    }
                }
            }
        }

        // 5. Release / medium quality tie-breakers
        if let status = release["status"] as? String {
            switch status {
            case "Official": score += 500
            case "Bootleg": score -= 200
            case "Promotion": score -= 100
            default: break
            }
        }
        if let format = medium["format"] as? String, format.uppercased().contains("CD") {
            score += 100
        }
        if !tracks.isEmpty {
            score += 200
        }
        if let date = release["date"] as? String, !date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 100
        }
        if let barcode = release["barcode"] as? String, !barcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 25
        }
        if let country = release["country"] as? String {
            if country == "US" {
                score += 30
            } else if country == "XW" || country == "XE" {
                score += 20
            }
        }

        return score
    }

    private static func extractResult(
        from release: [String: Any],
        medium: [String: Any],
        mediumIndex: Int,
        totalDiscs: Int
    ) -> DiscMetadataResult {
        var result = DiscMetadataResult()
        result.mbid = release["id"] as? String
        result.title = (release["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result.barcode = release["barcode"] as? String

        if let dateStr = release["date"] as? String,
           let parsed = ParsedReleaseDate.parse(dateStr) {
            result.releaseDate = parsed.formattedString
            result.year = parsed.year
        }

        if let artist = formatArtistCredit(release["artist-credit"] as? [[String: Any]]) {
            result.artist = artist
        }

        result.genre = extractTopGenre(from: release)

        result.discNumber = (medium["position"] as? Int) ?? (mediumIndex + 1)
        result.totalDiscs = totalDiscs
        if let sub = (medium["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sub.isEmpty {
            result.discSubtitle = sub
        }

        if let tracks = medium["tracks"] as? [[String: Any]] {
            for (idx, trackObj) in tracks.enumerated() {
                let position = trackPosition(trackObj, fallbackIndex: idx)
                guard position > 0 else { continue }

                let recording = trackObj["recording"] as? [String: Any]
                let title = ((trackObj["title"] as? String) ?? (recording?["title"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    result.trackTitles[position] = title
                }

                let trackArtist = formatArtistCredit(trackObj["artist-credit"] as? [[String: Any]])
                    ?? formatArtistCredit(recording?["artist-credit"] as? [[String: Any]])
                if let trackArtist, !trackArtist.isEmpty {
                    result.trackArtists[position] = trackArtist
                }
            }
        }

        return result
    }

    private static func trackPosition(_ trackObj: [String: Any], fallbackIndex: Int) -> Int {
        if let pos = trackObj["position"] as? Int, pos > 0 {
            return pos
        }
        if let numStr = trackObj["number"] as? String, let num = Int(numStr), num > 0 {
            return num
        }
        return fallbackIndex + 1
    }

    private static func formatArtistCredit(_ credits: [[String: Any]]?) -> String? {
        guard let credits, !credits.isEmpty else { return nil }
        var combined = ""
        for entry in credits {
            let name = (entry["name"] as? String)
                ?? ((entry["artist"] as? [String: Any])?["name"] as? String)
                ?? ""
            let join = (entry["joinphrase"] as? String) ?? ""
            combined += name + join
        }
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractTopGenre(from release: [String: Any]) -> String? {
        let releaseGenres = release["genres"] as? [[String: Any]]
        let rgGenres = (release["release-group"] as? [String: Any])?["genres"] as? [[String: Any]]
        let genres = (releaseGenres?.isEmpty == false) ? releaseGenres : rgGenres
        guard let genres, !genres.isEmpty else { return nil }

        let ranked = genres.compactMap { entry -> (name: String, count: Int)? in
            guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return nil
            }
            let count = (entry["count"] as? Int) ?? 0
            return (name, count)
        }.sorted { $0.count > $1.count }

        return ranked.first?.name
    }

    // MARK: - High-Resolution Artwork Fetchers

    /// Fetches front cover artwork directly from Cover Art Archive for an MBID.
    private func fetchCoverArtArchive(mbid: String) async -> Data? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(mbid)/front") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 307),
              data.count > 1000 else {
            return nil
        }
        return data
    }

    /// Searches Apple iTunes Store API for ultra-high-resolution (1400x1400) front cover artwork.
    private func fetchiTunesArtwork(artist: String, album: String) async -> (data: Data, url: URL)? {
        let term = "\(artist) \(album)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty,
              let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encodedTerm)&entity=album&limit=3") else {
            return nil
        }

        var req = URLRequest(url: searchURL)
        req.timeoutInterval = 6.0
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let art100 = first["artworkUrl100"] as? String else {
            return nil
        }

        // Replace 100x100 with 1400x1400 for high-resolution artwork
        let highResString = art100.replacingOccurrences(of: "100x100bb.jpg", with: "1400x1400bb.jpg")
            .replacingOccurrences(of: "100x100bb.png", with: "1400x1400bb.png")

        guard let artURL = URL(string: highResString),
              let (artData, artResp) = try? await URLSession.shared.data(from: artURL),
              let artHTTP = artResp as? HTTPURLResponse, artHTTP.statusCode == 200,
              artData.count > 1000 else {
            return nil
        }

        return (artData, artURL)
    }
}
