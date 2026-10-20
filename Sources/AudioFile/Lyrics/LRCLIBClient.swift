import Foundation

public enum LyricsFetchResult: Equatable, Sendable {
    case found(String)
    case instrumental
    case notFound
}

public actor LRCLIBClient {
    public static let shared = LRCLIBClient()

    private static let getURL = "https://lrclib.net/api/get"
    private static let searchURL = "https://lrclib.net/api/search"
    private static let userAgent = "AudioFile/1.0 (https://github.com/jonecat/audiofile)"

    private static let markerInstrumental = "[audiofile:instrumental]"
    private static let markerNotFound = "[audiofile:not_found]"

    public static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("AudioFile/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func fetchLyrics(for track: Track) async -> LyricsFetchResult {
        // 1. Check local .lrc file next to audio track
        if let localResult = checkLocalFile(for: track.path) {
            return localResult
        }

        // 2. Check local disk cache
        let cachePath = cacheURL(for: track.artist, title: track.title)
        if let cached = readCache(at: cachePath) {
            return cached
        }

        // 3. Fetch remote from LRCLIB (with retry & /api/search fallback)
        let result = await fetchRemote(
            artist: track.artist,
            title: track.title,
            album: track.album,
            duration: track.duration
        )

        // Only persist positive results (.found / .instrumental) so transient misses or newly added LRCLIB entries aren't permanently blocked
        writeCache(result, to: cachePath)
        return result
    }

    public func checkLocalFile(for path: URL) -> LyricsFetchResult? {
        let lrcURL = path.deletingPathExtension().appendingPathExtension("lrc")
        guard FileManager.default.fileExists(atPath: lrcURL.path),
              let content = try? String(contentsOf: lrcURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return .found(content)
    }

    private func cacheURL(for artist: String, title: String) -> URL {
        let safeArtist = artist.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -")).inverted).joined()
        let safeTitle = title.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -")).inverted).joined()
        let filename = "\(safeArtist.trimmingCharacters(in: .whitespaces))_\(safeTitle.trimmingCharacters(in: .whitespaces)).lrc"
        return Self.cacheDirectory.appendingPathComponent(filename.isEmpty ? "unknown.lrc" : filename)
    }

    private func readCache(at url: URL) -> LyricsFetchResult? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == Self.markerInstrumental {
            return .instrumental
        } else if trimmed == Self.markerNotFound {
            // Remove legacy negative cache markers so previously failed/503 tracks are retried
            try? FileManager.default.removeItem(at: url)
            return nil
        } else if !trimmed.isEmpty {
            return .found(content)
        }
        return nil
    }

    private func writeCache(_ result: LyricsFetchResult, to url: URL) {
        let text: String
        switch result {
        case .found(let content):
            text = content
        case .instrumental:
            text = Self.markerInstrumental
        case .notFound:
            return
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fetchRemote(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async -> LyricsFetchResult {
        let normArtist = Self.normalizeText(artist)
        let normTitle = Self.normalizeText(title)
        let normAlbum = Self.normalizeText(album)

        guard !normArtist.isEmpty || !normTitle.isEmpty else {
            return .notFound
        }

        var fallbackPlainLyrics: String?

        // Stage 1: Exact /api/get lookup
        if let getResult = await fetchFromGetEndpoint(
            artist: normArtist,
            title: normTitle,
            album: normAlbum,
            duration: duration
        ) {
            switch getResult {
            case .synced(let lrc):
                return .found(lrc)
            case .instrumental:
                return .instrumental
            case .plain(let plain):
                fallbackPlainLyrics = plain
            }
        }

        // Stage 2: /api/search with artist_name + track_name
        if let searchResult = await fetchFromSearchEndpoint(
            artist: normArtist,
            title: normTitle,
            album: normAlbum,
            duration: duration
        ) {
            switch searchResult {
            case .synced(let lrc):
                return .found(lrc)
            case .instrumental:
                return .instrumental
            case .plain(let plain):
                if fallbackPlainLyrics == nil {
                    fallbackPlainLyrics = plain
                }
            }
        }

        // Stage 3: /api/search with cleaned title & artist (stripping "[Bonus Track]", "(Remastered)", "feat.", etc.)
        let cleanedTitle = Self.stripTitleAnnotations(normTitle)
        let cleanedArtist = Self.stripArtistAnnotations(normArtist)
        if cleanedTitle.caseInsensitiveCompare(normTitle) != .orderedSame ||
           cleanedArtist.caseInsensitiveCompare(normArtist) != .orderedSame {
            if let cleanedResult = await fetchFromSearchEndpoint(
                artist: cleanedArtist,
                title: cleanedTitle,
                album: normAlbum,
                duration: duration
            ) {
                switch cleanedResult {
                case .synced(let lrc):
                    return .found(lrc)
                case .instrumental:
                    return .instrumental
                case .plain(let plain):
                    if fallbackPlainLyrics == nil {
                        fallbackPlainLyrics = plain
                    }
                }
            }
        }

        // Stage 4: General query search (?q=artist title) as final fallback
        if let qResult = await fetchFromQuerySearchEndpoint(
            artist: cleanedArtist,
            title: cleanedTitle,
            album: normAlbum,
            duration: duration
        ) {
            switch qResult {
            case .synced(let lrc):
                return .found(lrc)
            case .instrumental:
                return .instrumental
            case .plain(let plain):
                if fallbackPlainLyrics == nil {
                    fallbackPlainLyrics = plain
                }
            }
        }

        if let plain = fallbackPlainLyrics {
            return .found(plain)
        }

        return .notFound
    }

    private enum InternalCandidateResult {
        case synced(String)
        case plain(String)
        case instrumental
    }

    private func fetchFromGetEndpoint(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async -> InternalCandidateResult? {
        var components = URLComponents(string: Self.getURL)!
        var queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        if !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: "\(Int(duration.rounded()))"))
        }
        components.queryItems = queryItems

        guard let url = components.url,
              let (data, status) = await performRequest(url: url),
              status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let isInstrumental = json["instrumental"] as? Bool, isInstrumental {
            return .instrumental
        }
        if let synced = json["syncedLyrics"] as? String,
           !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .synced(synced)
        }
        if let plain = json["plainLyrics"] as? String,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .plain(plain)
        }
        return nil
    }

    private func fetchFromSearchEndpoint(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async -> InternalCandidateResult? {
        var components = URLComponents(string: Self.searchURL)!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]

        guard let url = components.url,
              let (data, status) = await performRequest(url: url),
              status == 200,
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        return selectBestCandidate(from: items, artist: artist, title: title, album: album, duration: duration)
    }

    private func fetchFromQuerySearchEndpoint(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async -> InternalCandidateResult? {
        var components = URLComponents(string: Self.searchURL)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(artist) \(title)")
        ]

        guard let url = components.url,
              let (data, status) = await performRequest(url: url),
              status == 200,
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        return selectBestCandidate(from: items, artist: artist, title: title, album: album, duration: duration)
    }

    private func selectBestCandidate(
        from items: [[String: Any]],
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) -> InternalCandidateResult? {
        guard !items.isEmpty else { return nil }

        let targetArtist = Self.comparableKey(artist)
        let targetTitle = Self.comparableKey(Self.stripTitleAnnotations(title))
        let targetAlbum = Self.comparableKey(album)

        var bestSynced: (score: Double, lyrics: String)?
        var bestPlain: (score: Double, lyrics: String)?
        var sawInstrumental = false

        for item in items {
            let candTrack = Self.comparableKey(Self.stripTitleAnnotations((item["trackName"] as? String) ?? (item["name"] as? String) ?? ""))
            let candArtist = Self.comparableKey((item["artistName"] as? String) ?? "")
            let candAlbum = Self.comparableKey((item["albumName"] as? String) ?? "")
            let candDuration = (item["duration"] as? Double) ?? Double((item["duration"] as? Int) ?? 0)

            // Verify artist and title relevance
            let titleMatches = candTrack == targetTitle || candTrack.contains(targetTitle) || targetTitle.contains(candTrack)
            let artistMatches = candArtist == targetArtist || candArtist.contains(targetArtist) || targetArtist.contains(candArtist)
            guard titleMatches && artistMatches else { continue }

            var score: Double = 100.0
            if candTrack == targetTitle { score += 30.0 }
            if candArtist == targetArtist { score += 20.0 }
            if !targetAlbum.isEmpty && (candAlbum == targetAlbum || candAlbum.contains(targetAlbum) || targetAlbum.contains(candAlbum)) {
                score += 15.0
            }
            if duration > 0 && candDuration > 0 {
                let diff = abs(duration - candDuration)
                score -= min(diff * 2.0, 60.0)
            }

            if let isInst = item["instrumental"] as? Bool, isInst {
                sawInstrumental = true
                continue
            }

            if let synced = item["syncedLyrics"] as? String,
               !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if bestSynced == nil || score > bestSynced!.score {
                    bestSynced = (score, synced)
                }
            } else if let plain = item["plainLyrics"] as? String,
                      !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if bestPlain == nil || score > bestPlain!.score {
                    bestPlain = (score, plain)
                }
            }
        }

        if let bestSynced {
            return .synced(bestSynced.lyrics)
        }
        if let bestPlain {
            return .plain(bestPlain.lyrics)
        }
        if sawInstrumental {
            return .instrumental
        }
        return nil
    }

    private func performRequest(url: URL, maxAttempts: Int = 3) async -> (Data, Int)? {
        for attempt in 0..<maxAttempts {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    return nil
                }
                let code = httpResponse.statusCode
                if code == 503 || code == 429 || code == 502 || code == 504 {
                    if attempt + 1 < maxAttempts {
                        let delayNs = UInt64(450_000_000 * (attempt + 1))
                        try? await Task.sleep(nanoseconds: delayNs)
                        continue
                    }
                    return nil
                }
                return (data, code)
            } catch {
                if attempt + 1 < maxAttempts {
                    let delayNs = UInt64(400_000_000 * (attempt + 1))
                    try? await Task.sleep(nanoseconds: delayNs)
                    continue
                }
                return nil
            }
        }
        return nil
    }

    private static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTitleAnnotations(_ title: String) -> String {
        var result = title
        let patterns = [
            #"\s*\[[^\]]*\]"#,
            #"\s*\((?:remaster|deluxe|bonus|live|mono|stereo|explicit|clean|version|edit|feat\.|ft\.)[^)]*\)"#,
            #"\s*-\s*(?:remaster|deluxe|bonus|live|mono|stereo|version|edit).*$"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripArtistAnnotations(_ artist: String) -> String {
        var result = artist
        if let regex = try? NSRegularExpression(pattern: #"\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#, options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func comparableKey(_ str: String) -> String {
        let lower = normalizeText(str).lowercased()
        let allowed = CharacterSet.alphanumerics
        return lower.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
    }

    public func clearCache() {
        let dir = Self.cacheDirectory
        let fileManager = FileManager.default
        if let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
