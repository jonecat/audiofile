import Foundation

public struct LRCLine: Identifiable, Equatable, Sendable {
    public var id: TimeInterval { timestamp }
    public let timestamp: TimeInterval
    public let text: String
    public let isInstrumental: Bool

    public init(timestamp: TimeInterval, text: String, isInstrumental: Bool = false) {
        self.timestamp = timestamp
        self.text = text
        self.isInstrumental = isInstrumental
    }

    public var formattedTimestamp: String {
        let totalSeconds = Int(timestamp)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

public struct LyricsWindow: Equatable, Sendable {
    public let prev2: LRCLine?
    public let prev1: LRCLine?
    public let curr: LRCLine?
    public let next1: LRCLine?
    public let next2: LRCLine?
    public let isInstrumentalGap: Bool

    public init(
        prev2: LRCLine? = nil,
        prev1: LRCLine? = nil,
        curr: LRCLine? = nil,
        next1: LRCLine? = nil,
        next2: LRCLine? = nil,
        isInstrumentalGap: Bool = false
    ) {
        self.prev2 = prev2
        self.prev1 = prev1
        self.curr = curr
        self.next1 = next1
        self.next2 = next2
        self.isInstrumentalGap = isInstrumentalGap
    }
}

public struct SyncedLyrics: Equatable, Sendable {
    public let lines: [LRCLine]

    public init(lines: [LRCLine]) {
        self.lines = lines
    }

    public static func parse(content: String, duration: TimeInterval = 0) -> SyncedLyrics? {
        var parsedLines: [LRCLine] = []
        var plainLines: [String] = []
        var offsetMs: Double = 0

        let rawLines = content.components(separatedBy: .newlines)
        for raw in rawLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Check for offset tag: [offset:+/-ms]
            if line.hasPrefix("[offset:") && line.hasSuffix("]") {
                let start = line.index(line.startIndex, offsetBy: 8)
                let end = line.index(line.endIndex, offsetBy: -1)
                let valStr = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
                if let ms = Double(valStr) {
                    offsetMs = ms
                }
                continue
            }

            // Skip metadata tags: [ti:], [ar:], [al:], etc.
            if isMetadataTag(line) {
                continue
            }

            // Parse timestamps: [mm:ss.xx][mm:ss.xx] Lyrics Text
            var timestamps: [TimeInterval] = []
            var textStartIndex = line.startIndex

            var searchIndex = line.startIndex
            while searchIndex < line.endIndex {
                if line[searchIndex] == "[" {
                    if let closeBracket = line[searchIndex...].firstIndex(of: "]") {
                        let tagStart = line.index(after: searchIndex)
                        let tag = String(line[tagStart..<closeBracket])
                        if let ts = parseTimestamp(tag: tag) {
                            timestamps.append(ts)
                            searchIndex = line.index(after: closeBracket)
                            textStartIndex = searchIndex
                            continue
                        }
                    }
                }
                break
            }

            if timestamps.isEmpty {
                plainLines.append(line)
                continue
            }

            let lyricText = String(line[textStartIndex...]).trimmingCharacters(in: .whitespaces)
            let offsetSecs = offsetMs / 1000.0

            for ts in timestamps {
                let adjusted = max(0.0, ts + offsetSecs)
                parsedLines.append(LRCLine(timestamp: adjusted, text: lyricText))
            }
        }

        if !parsedLines.isEmpty {
            parsedLines.sort { $0.timestamp < $1.timestamp }
            let normalized = normalizeLines(parsedLines, duration: duration)
            guard !normalized.isEmpty else { return nil }
            return SyncedLyrics(lines: normalized)
        }

        // Fallback: if plain (unsynced) lyrics were returned, distribute timestamps across the track duration
        if !plainLines.isEmpty {
            let effectiveDuration = duration > 15 ? duration : Double(plainLines.count) * 4.0
            let startTime = min(5.0, effectiveDuration * 0.05)
            let span = max(10.0, effectiveDuration * 0.85 - startTime)
            let step = span / Double(max(1, plainLines.count))
            let estimated = plainLines.enumerated().map { index, text in
                LRCLine(timestamp: startTime + Double(index) * step, text: text)
            }
            return SyncedLyrics(lines: estimated)
        }

        return nil
    }

    private static func isMetadataTag(_ line: String) -> Bool {
        guard line.hasPrefix("["), let colonIdx = line.firstIndex(of: ":") else { return false }
        let tagStart = line.index(after: line.startIndex)
        let tag = String(line[tagStart..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
        let metadataTags: Set<String> = ["ti", "ar", "al", "by", "length", "author", "creator", "re", "ve", "offset"]
        return metadataTags.contains(tag)
    }

    private static func parseTimestamp(tag: String) -> TimeInterval? {
        let parts = tag.components(separatedBy: ":")
        guard parts.count == 2 else { return nil }
        guard let mins = Double(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }

        let secParts = parts[1].components(separatedBy: ".")
        guard let secs = Double(secParts[0].trimmingCharacters(in: .whitespaces)) else { return nil }

        var millis: Double = 0
        if secParts.count == 2 {
            let fracStr = secParts[1].trimmingCharacters(in: .whitespaces)
            if let frac = Double(fracStr) {
                switch fracStr.count {
                case 1: millis = frac * 100
                case 2: millis = frac * 10
                default:
                    let prefix = String(fracStr.prefix(3))
                    millis = Double(prefix) ?? 0
                }
            }
        }

        return mins * 60.0 + secs + (millis / 1000.0)
    }

    private static func isInstrumentalMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        return lower == "♪" || lower == "♫" || lower == "[instrumental]" || lower == "(instrumental)" || lower == "instrumental"
    }

    /// Converts empty timestamped lines and long vocal gaps into explicit `LRCLine` entries
    /// so instrumental intros, breaks, and outros scroll smoothly through all 5 rows
    /// (`next2` -> `next1` -> `curr` -> `prev1` -> `prev2`).
    private static func normalizeLines(_ rawLines: [LRCLine], duration: TimeInterval) -> [LRCLine] {
        let instrumentalLabel = "♪   Instrumental Break   ♪"

        // Find indices of actual vocal lines
        let vocalIndices = rawLines.indices.filter { !isInstrumentalMarker(rawLines[$0].text) }
        guard let firstVocalIdx = vocalIndices.first else {
            return []
        }

        var result: [LRCLine] = []

        // 1. Instrumental intro if the first vocal line starts after >= 5 seconds
        let firstVocal = rawLines[firstVocalIdx]
        if firstVocal.timestamp >= 5.0 {
            result.append(LRCLine(
                timestamp: 0.0,
                text: instrumentalLabel,
                isInstrumental: true
            ))
        }

        // 2. Walk through vocal lines and inspect gaps / empty markers between them
        for (pos, vocalIdx) in vocalIndices.enumerated() {
            let vocalLine = rawLines[vocalIdx]
            result.append(vocalLine)

            if pos + 1 < vocalIndices.count {
                let nextVocalIdx = vocalIndices[pos + 1]
                let nextVocal = rawLines[nextVocalIdx]

                if nextVocalIdx > vocalIdx + 1 {
                    // There is at least one empty/instrumental marker line between vocalIdx and nextVocalIdx
                    let markerLine = rawLines[vocalIdx + 1]
                    let breakDuration = nextVocal.timestamp - markerLine.timestamp
                    if breakDuration >= 4.0 {
                        result.append(LRCLine(
                            timestamp: markerLine.timestamp,
                            text: instrumentalLabel,
                            isInstrumental: true
                        ))
                    }
                } else {
                    // No explicit empty line, check if there is a long instrumental gap between vocal lines
                    let totalGap = nextVocal.timestamp - vocalLine.timestamp
                    if totalGap >= 13.0 {
                        result.append(LRCLine(
                            timestamp: vocalLine.timestamp + 5.0,
                            text: instrumentalLabel,
                            isInstrumental: true
                        ))
                    }
                }
            } else {
                // After the final vocal line: check for an instrumental outro
                if vocalIdx + 1 < rawLines.count {
                    let markerLine = rawLines[vocalIdx + 1]
                    if duration <= 0 || (duration - markerLine.timestamp) >= 5.0 {
                        result.append(LRCLine(
                            timestamp: markerLine.timestamp,
                            text: instrumentalLabel,
                            isInstrumental: true
                        ))
                    }
                } else if duration > 0 && (duration - vocalLine.timestamp) >= 16.0 {
                    result.append(LRCLine(
                        timestamp: vocalLine.timestamp + 6.0,
                        text: instrumentalLabel,
                        isInstrumental: true
                    ))
                }
            }
        }

        return result
    }

    public func window(at elapsed: TimeInterval) -> LyricsWindow {
        if lines.isEmpty {
            return LyricsWindow()
        }

        // Current line: last index where timestamp <= elapsed (or 0 if before first timestamp)
        let currIdx = lines.lastIndex(where: { $0.timestamp <= elapsed }) ?? 0

        let currLine = lines[currIdx]
        let prev1 = currIdx > 0 ? lines[currIdx - 1] : nil
        let prev2 = currIdx > 1 ? lines[currIdx - 2] : nil
        let next1 = currIdx + 1 < lines.count ? lines[currIdx + 1] : nil
        let next2 = currIdx + 2 < lines.count ? lines[currIdx + 2] : nil

        return LyricsWindow(
            prev2: prev2,
            prev1: prev1,
            curr: currLine,
            next1: next1,
            next2: next2,
            isInstrumentalGap: currLine.isInstrumental
        )
    }
}
