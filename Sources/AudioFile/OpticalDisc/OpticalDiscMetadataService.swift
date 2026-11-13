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
        public var genre: String?
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
        trackOffsets: [Int],
        leadoutSector: Int,
        fallbackTitle: String? = nil,
        fallbackArtist: String? = nil
    ) async -> DiscMetadataResult {
        var result = DiscMetadataResult()

        // 1. Check CD-Text first
        let cdText = await readCDText()
        if let cdTitle = cdText.albumTitle, !cdTitle.isEmpty {
            result.title = cdTitle
        }
        if let cdArtist = cdText.albumArtist, !cdArtist.isEmpty {
            result.artist = cdArtist
        }
        for (num, title) in cdText.trackTitles {
            result.trackTitles[num] = title
        }

        // 2. Query MusicBrainz by DiscID
        let mbResult = await queryMusicBrainz(discID: discID, trackOffsets: trackOffsets, leadoutSector: leadoutSector)
        if let mb = mbResult {
            if !mb.title.isEmpty { result.title = mb.title }
            if !mb.artist.isEmpty { result.artist = mb.artist }
            if mb.year != nil { result.year = mb.year }
            if mb.genre != nil { result.genre = mb.genre }
            if mb.mbid != nil { result.mbid = mb.mbid }
            if mb.barcode != nil { result.barcode = mb.barcode }
            for (num, title) in mb.trackTitles {
                result.trackTitles[num] = title
            }
            for (num, art) in mb.trackArtists {
                result.trackArtists[num] = art
            }
        }

        // 3. Fallbacks if still untitled
        if result.title.isEmpty, let fTitle = fallbackTitle, !fTitle.isEmpty {
            result.title = fTitle
        }
        if result.artist.isEmpty, let fArtist = fallbackArtist, !fArtist.isEmpty {
            result.artist = fArtist
        }

        // 4. Fetch High-Resolution Album Artwork
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
        trackOffsets: [Int],
        leadoutSector: Int
    ) async -> DiscMetadataResult? {
        // Step 1: Query exact MusicBrainz DiscID
        var releaseID: String? = nil
        let discIDURL = "https://musicbrainz.org/ws/2/discid/\(discID)?fmt=json"
        releaseID = await fetchReleaseID(urlString: discIDURL)

        // Step 2: Fallback to fuzzy TOC query if exact DiscID did not match
        if releaseID == nil && !trackOffsets.isEmpty {
            var tocParts = ["1", "\(trackOffsets.count)", "\(leadoutSector)"]
            for off in trackOffsets { tocParts.append("\(off)") }
            let tocString = tocParts.joined(separator: "+")
            let fuzzyURL = "https://musicbrainz.org/ws/2/discid/-?toc=\(tocString)&fmt=json"
            releaseID = await fetchReleaseID(urlString: fuzzyURL)
        }

        guard let relID = releaseID else { return nil }

        // Step 3: Fetch full release details with recordings, track titles, artist, genres
        let releaseURL = "https://musicbrainz.org/ws/2/release/\(relID)?inc=artist-credits+recordings+genres&fmt=json"
        return await fetchReleaseDetails(urlString: releaseURL)
    }

    private func fetchReleaseID(urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8.0
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = json["releases"] as? [[String: Any]],
              let firstRelease = releases.first,
              let relID = firstRelease["id"] as? String else {
            return nil
        }
        return relID
    }

    private func fetchReleaseDetails(urlString: String) async -> DiscMetadataResult? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var result = DiscMetadataResult()
        result.mbid = json["id"] as? String
        result.title = json["title"] as? String ?? ""
        result.barcode = json["barcode"] as? String

        if let dateStr = json["date"] as? String {
            let yearStr = String(dateStr.prefix(4))
            result.year = Int(yearStr)
        }

        // Artist Credit
        if let artistCredits = json["artist-credit"] as? [[String: Any]], let first = artistCredits.first {
            result.artist = first["name"] as? String ?? ""
        }

        // Genres
        if let genres = json["genres"] as? [[String: Any]], let firstG = genres.first {
            result.genre = firstG["name"] as? String
        }

        // Media & Tracklist
        if let mediaList = json["media"] as? [[String: Any]], let firstMedia = mediaList.first,
           let tracks = firstMedia["tracks"] as? [[String: Any]] {
            for trackObj in tracks {
                let position = trackObj["position"] as? Int ?? ((trackObj["number"] as? String).flatMap { Int($0) } ?? 0)
                let title = trackObj["title"] as? String ?? ""
                if position > 0 && !title.isEmpty {
                    result.trackTitles[position] = title
                }
                if let artistCredits = trackObj["artist-credit"] as? [[String: Any]], let firstAC = artistCredits.first {
                    if let trackArtist = firstAC["name"] as? String {
                        result.trackArtists[position] = trackArtist
                    }
                }
            }
        }

        return result
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

    // MARK: - CD-Text Reader

    public struct CDTextData: Sendable {
        public var albumTitle: String?
        public var albumArtist: String?
        public var trackTitles: [Int: String] = [:]
    }

    private func readCDText() async -> CDTextData {
        var data = CDTextData()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
        proc.arguments = ["cdtext"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: outputData, encoding: .utf8), !text.isEmpty else {
                return data
            }

            var currentTrackNum: Int? = nil
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Title:") {
                    let val = trimmed.dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
                    if let track = currentTrackNum {
                        data.trackTitles[track] = val
                    } else if data.albumTitle == nil {
                        data.albumTitle = val
                    }
                } else if trimmed.hasPrefix("Performer:") {
                    let val = trimmed.dropFirst("Performer:".count).trimmingCharacters(in: .whitespaces)
                    if currentTrackNum == nil && data.albumArtist == nil {
                        data.albumArtist = val
                    }
                } else if trimmed.hasPrefix("Track") {
                    let parts = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
                    if let first = parts.first, let num = Int(first) {
                        currentTrackNum = num
                    }
                }
            }
        } catch {
            // Ignore if drutil cdtext is unavailable or unsupported
        }

        return data
    }
}
