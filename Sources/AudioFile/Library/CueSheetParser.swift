import Foundation

/// Parses single-file and multi-file `.cue` sheets into timestamp-sliced virtual `Track` entries.
public enum CueSheetParser {
    private struct RawCueTrack {
        let trackNumber: Int
        var audioURL: URL
        var title: String?
        var artist: String?
        var index00: TimeInterval?
        var index01: TimeInterval?
        var replayGainTrackDb: Double?
        var replayGainTrackPeak: Double?
    }

    /// Parses a `.cue` file and emits virtual `Track` records for each referenced audio track.
    /// Also returns the standardized paths of all backing audio files resolved by this CUE sheet
    /// so library sync can suppress duplicate full-album unsplit entries.
    public static func parse(
        cueURL: URL,
        existingById: [String: Track],
        overriddenTrackIds: Set<String>
    ) async -> (tracks: [Track], backingFilePaths: Set<String>) {
        guard let rawContent = readText(at: cueURL) else {
            return ([], [])
        }

        let directory = cueURL.deletingLastPathComponent()
        let lines = rawContent.components(separatedBy: .newlines)

        var albumTitle: String?
        var albumArtist: String?
        var albumGenre: String?
        var albumYear: Int?
        var albumDiscNumber: Int?
        var albumReplayGainDb: Double?
        var albumReplayGainPeak: Double?

        var currentAudioURL: URL?
        var referencedFilePaths: Set<String> = []
        var rawTracks: [RawCueTrack] = []
        var activeTrackIndex: Int?

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let upper = trimmed.uppercased()

            if upper.hasPrefix("REM ") {
                let remBody = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let remUpper = remBody.uppercased()
                if remUpper.hasPrefix("GENRE ") {
                    let val = unquote(String(remBody.dropFirst(6)))
                    if !val.isEmpty { albumGenre = val }
                } else if remUpper.hasPrefix("DATE ") {
                    let val = unquote(String(remBody.dropFirst(5)))
                    if let parsedYear = extractYear(from: val) {
                        albumYear = parsedYear
                    }
                } else if remUpper.hasPrefix("DISCNUMBER ") {
                    let val = unquote(String(remBody.dropFirst(11)))
                    if let disc = Int(val) { albumDiscNumber = disc }
                } else if remUpper.hasPrefix("REPLAYGAIN_ALBUM_GAIN ") {
                    albumReplayGainDb = parseReplayGainNumber(String(remBody.dropFirst(22)))
                } else if remUpper.hasPrefix("REPLAYGAIN_ALBUM_PEAK ") {
                    albumReplayGainPeak = parseReplayGainNumber(String(remBody.dropFirst(22)))
                } else if remUpper.hasPrefix("REPLAYGAIN_TRACK_GAIN "), let idx = activeTrackIndex {
                    rawTracks[idx].replayGainTrackDb = parseReplayGainNumber(String(remBody.dropFirst(22)))
                } else if remUpper.hasPrefix("REPLAYGAIN_TRACK_PEAK "), let idx = activeTrackIndex {
                    rawTracks[idx].replayGainTrackPeak = parseReplayGainNumber(String(remBody.dropFirst(22)))
                }
                continue
            }

            if upper.hasPrefix("FILE ") {
                let spec = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let fileName = extractCueFilename(from: spec),
                   let resolved = resolveAudioFile(named: fileName, relativeTo: directory, cueURL: cueURL) {
                    let stdPath = resolved.standardizedFileURL.path
                    currentAudioURL = resolved
                    referencedFilePaths.insert(stdPath)
                    if let idx = activeTrackIndex, rawTracks[idx].index01 == nil {
                        rawTracks[idx].audioURL = resolved
                    }
                }
                continue
            }

            if upper.hasPrefix("TRACK ") {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 3,
                   parts[2].uppercased() == "AUDIO",
                   let num = Int(parts[1]),
                   let audioURL = currentAudioURL {
                    rawTracks.append(RawCueTrack(trackNumber: num, audioURL: audioURL))
                    activeTrackIndex = rawTracks.count - 1
                } else if parts.count >= 3, parts[2].uppercased() != "AUDIO" {
                    activeTrackIndex = nil
                }
                continue
            }

            if upper.hasPrefix("TITLE ") {
                let value = unquote(String(trimmed.dropFirst(6)))
                if !value.isEmpty {
                    if let idx = activeTrackIndex {
                        rawTracks[idx].title = value
                    } else {
                        albumTitle = value
                    }
                }
                continue
            }

            if upper.hasPrefix("PERFORMER ") {
                let value = unquote(String(trimmed.dropFirst(10)))
                if !value.isEmpty {
                    if let idx = activeTrackIndex {
                        rawTracks[idx].artist = value
                    } else {
                        albumArtist = value
                    }
                }
                continue
            }

            if upper.hasPrefix("INDEX "), let idx = activeTrackIndex {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 3, let time = parseCueTimestamp(String(parts[2])) {
                    if parts[1] == "01" {
                        rawTracks[idx].index01 = time
                    } else if parts[1] == "00" && rawTracks[idx].index00 == nil {
                        rawTracks[idx].index00 = time
                    }
                }
                continue
            }
        }

        // Only emit virtual CUE tracks for true single-file album images (exactly 1 FILE and 2+ tracks).
        // Multi-file CUE sheets created by CD rippers alongside individual track files must be ignored so the
        // actual split audio files retain their embedded tags and canonical track IDs.
        guard referencedFilePaths.count == 1, rawTracks.count >= 2 else {
            return ([], [])
        }
        let multiTrackEntries = rawTracks
        let backingFilePaths = referencedFilePaths

        var baseTrackCache: [String: Track] = [:]
        var result: [Track] = []
        result.reserveCapacity(multiTrackEntries.count)

        for (i, entry) in multiTrackEntries.enumerated() {
            let audioURL = entry.audioURL
            let standardizedPath = audioURL.standardizedFileURL.path
            let baseId = Track.generateId(for: audioURL)
            let cueTrackId = "\(baseId)_cue_\(entry.trackNumber)"

            let fileValues = try? audioURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let curSize = fileValues?.fileSize.map { UInt64($0) }
            let curDate = fileValues?.contentModificationDate

            // Reuse cached virtual track when backing file is unmodified and not overridden by tag fixes.
            if let existing = existingById[cueTrackId],
               existing.fileSize == curSize,
               existing.modifiedDate == curDate,
               !overriddenTrackIds.contains(cueTrackId),
               existing.duration > 0 {
                result.append(existing)
                continue
            }

            let baseTrack: Track
            if let cached = baseTrackCache[standardizedPath] {
                baseTrack = cached
            } else {
                guard let readBase = await MetadataReader.readTrack(at: audioURL) else { continue }
                baseTrackCache[standardizedPath] = readBase
                baseTrack = readBase
            }

            let startTime = entry.index01 ?? entry.index00 ?? 0.0
            let nextSameFileStart: TimeInterval? = {
                if i + 1 < multiTrackEntries.count,
                   multiTrackEntries[i + 1].audioURL.standardizedFileURL.path == standardizedPath {
                    return multiTrackEntries[i + 1].index01 ?? multiTrackEntries[i + 1].index00
                }
                return nil
            }()

            let effectiveEnd: TimeInterval
            if let nextStart = nextSameFileStart, nextStart > startTime {
                effectiveEnd = nextStart
            } else {
                effectiveEnd = max(startTime, baseTrack.duration)
            }

            let sliceDuration = max(0.0, effectiveEnd - startTime)
            guard sliceDuration > 0.1 else { continue }

            let existingTrack = existingById[cueTrackId]
            let virtualTrack = Track(
                id: cueTrackId,
                path: audioURL,
                title: entry.title ?? "Track \(entry.trackNumber)",
                artist: entry.artist ?? albumArtist ?? baseTrack.artist,
                album: albumTitle ?? baseTrack.album,
                albumArtist: albumArtist ?? baseTrack.albumArtist,
                genre: albumGenre ?? baseTrack.genre,
                year: albumYear ?? baseTrack.year,
                releaseDate: baseTrack.releaseDate,
                trackNumber: entry.trackNumber,
                discNumber: albumDiscNumber ?? baseTrack.discNumber,
                duration: sliceDuration,
                format: baseTrack.format,
                sampleRate: baseTrack.sampleRate,
                bitDepth: baseTrack.bitDepth,
                bitrate: baseTrack.bitrate,
                hasCoverArt: baseTrack.hasCoverArt,
                fileSize: baseTrack.fileSize,
                modifiedDate: baseTrack.modifiedDate,
                dynamicRange: existingTrack?.dynamicRange,
                playCount: existingTrack?.playCount,
                startTimeOffset: startTime,
                endTimeOffset: effectiveEnd,
                replayGainTrackDb: entry.replayGainTrackDb ?? baseTrack.replayGainTrackDb,
                replayGainAlbumDb: albumReplayGainDb ?? baseTrack.replayGainAlbumDb,
                replayGainPeak: entry.replayGainTrackPeak ?? albumReplayGainPeak ?? baseTrack.replayGainPeak
            )
            result.append(virtualTrack)
        }

        return (result, backingFilePaths)
    }

    // MARK: - Helpers

    private static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for encoding in [String.Encoding.utf8, .isoLatin1, .windowsCP1252] {
            if var str = String(data: data, encoding: encoding) {
                if str.hasPrefix("\u{FEFF}") {
                    str.removeFirst()
                }
                return str
            }
        }
        return nil
    }

    private static func unquote(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            s.removeFirst()
            s.removeLast()
        }
        return s.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func extractCueFilename(from spec: String) -> String? {
        if spec.hasPrefix("\"") {
            let afterOpen = spec.dropFirst()
            if let closeIdx = afterOpen.firstIndex(of: "\"") {
                return String(afterOpen[..<closeIdx])
            }
        }
        let parts = spec.split(whereSeparator: { $0.isWhitespace })
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 {
            return String(parts[0])
        }
        // Drop trailing CUE file-type keyword (WAVE, MP3, AIFF, BINARY, MOTOROLA)
        return parts.dropLast().joined(separator: " ")
    }

    private static func resolveAudioFile(named fileName: String, relativeTo directory: URL, cueURL: URL) -> URL? {
        let fm = FileManager.default
        let normalizedName = fileName.replacingOccurrences(of: "\\", with: "/")
        let baseComponent = URL(fileURLWithPath: normalizedName).lastPathComponent

        let direct = directory.appendingPathComponent(baseComponent)
        if fm.fileExists(atPath: direct.path) && MetadataReader.isAudioFile(direct) {
            return direct
        }

        let dirContents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let targetLower = baseComponent.lowercased()
        if let caseMatch = dirContents.first(where: { $0.lastPathComponent.lowercased() == targetLower && MetadataReader.isAudioFile($0) }) {
            return caseMatch
        }

        // Common CUE mismatch: FILE header still says ".wav" even though the image was encoded to .flac/.ape/.wv/.m4a
        let fileStem = URL(fileURLWithPath: baseComponent).deletingPathExtension().lastPathComponent.lowercased()
        let cueStem = cueURL.deletingPathExtension().lastPathComponent.lowercased()
        let candidateExts = ["flac", "ape", "wav", "aiff", "aif", "wv", "m4a", "mp3", "ogg", "opus"]

        for stem in [fileStem, cueStem] where !stem.isEmpty {
            for ext in candidateExts {
                if let match = dirContents.first(where: {
                    $0.deletingPathExtension().lastPathComponent.lowercased() == stem &&
                    $0.pathExtension.lowercased() == ext
                }) {
                    return match
                }
            }
        }

        return nil
    }

    /// Parses CUE `MM:SS:FF` timestamps where `FF` is CD frames (75 frames per second).
    private static func parseCueTimestamp(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.split(separator: ":")
        guard parts.count == 3,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]),
              let frames = Double(parts[2]) else {
            return nil
        }
        return (minutes * 60.0) + seconds + (frames / 75.0)
    }

    private static func extractYear(from text: String) -> Int? {
        let digits = text.prefix(4)
        if digits.count == 4, let year = Int(digits), year >= 1900 && year <= 2100 {
            return year
        }
        return nil
    }

    private static func parseReplayGainNumber(_ text: String) -> Double? {
        let cleaned = unquote(text)
            .lowercased()
            .replacingOccurrences(of: "db", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }
}
