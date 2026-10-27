import Foundation
import CryptoKit

public struct Track: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let path: URL
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var releaseDate: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval
    public var format: String
    public var sampleRate: Double?
    public var bitDepth: Int?
    public var bitrate: Int?
    public var hasCoverArt: Bool
    public var fileSize: UInt64?
    public var modifiedDate: Date?
    public var dynamicRange: Int?

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
        dynamicRange: Int? = nil
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
    }

    public static func generateId(for path: URL) -> String {
        let pathString = path.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(pathString.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return path.deletingPathExtension().lastPathComponent
    }

    public var displayArtist: String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown Artist" : trimmed
    }

    public var formattedYear: String? {
        year.map { String($0) }
    }

    public var displayAlbumArtist: String {
        if let aa = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
           !aa.isEmpty,
           UUID(uuidString: aa) == nil {
            return aa
        }
        return displayArtist
    }

    public var displayAlbum: String {
        let trimmed = album.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown Album" : trimmed
    }

    public var formattedDuration: String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var isLossless: Bool {
        let upper = format.uppercased()
        return upper == "FLAC" || upper == "ALAC" || upper == "WAV" || upper == "AIFF" || upper == "AIF" || upper == "APE" || upper == "DSD"
    }

    public var dsdTierLabel: String? {
        guard format.uppercased() == "DSD", let rate = sampleRate, rate >= 2_000_000 else {
            return nil
        }
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

    public var formattedSampleRate: String? {
        guard let rate = sampleRate, rate > 0 else { return nil }
        if rate >= 1_000_000.0 {
            let mhz = rate / 1_000_000.0
            if let tier = dsdTierLabel {
                return String(format: "%.2f MHz (%@)", mhz, tier)
            }
            return String(format: "%.2f MHz", mhz)
        } else if rate >= 1000.0 {
            let khz = rate / 1000.0
            if khz == khz.rounded() {
                return String(format: "%.0f kHz", khz)
            } else {
                return String(format: "%.1f kHz", khz)
            }
        } else {
            return "\(Int(rate)) Hz"
        }
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
        return title.lowercased().contains(q)
            || artist.lowercased().contains(q)
            || album.lowercased().contains(q)
            || (genre?.lowercased().contains(q) ?? false)
            || path.path.lowercased().contains(q)
    }
}
