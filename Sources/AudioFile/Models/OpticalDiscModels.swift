import Foundation
import AppKit

public enum RipFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case flac = "FLAC"
    case alac = "ALAC"
    case opus = "Opus"
    case vorbis = "Ogg Vorbis"
    case wav = "WAV"
    case wavpack = "WavPack"
    case mp3 = "MP3"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .flac: return "flac"
        case .alac: return "m4a"
        case .opus: return "opus"
        case .vorbis: return "ogg"
        case .wav: return "wav"
        case .wavpack: return "wv"
        case .mp3: return "mp3"
        }
    }

    public var displayName: String {
        switch self {
        case .flac: return "FLAC (Free Lossless Audio Codec)"
        case .alac: return "ALAC (Apple Lossless M4A)"
        case .opus: return "Opus (Modern High-Efficiency)"
        case .vorbis: return "Ogg Vorbis (Open-Source Lossy)"
        case .wav: return "WAV (Uncompressed Lossless PCM)"
        case .wavpack: return "WavPack (Lossless Audio)"
        case .mp3: return "MP3 (LAME High Quality 320k)"
        }
    }

    public var isLossless: Bool {
        switch self {
        case .flac, .alac, .wav, .wavpack:
            return true
        case .opus, .vorbis, .mp3:
            return false
        }
    }

    public var description: String {
        switch self {
        case .flac: return "Bit-perfect open-source lossless compression. Maximum fidelity, recommended for archiving."
        case .alac: return "Lossless format natively supported across Apple ecosystem in an .m4a container."
        case .opus: return "State-of-the-art open lossy codec delivering pristine transparency at 256 kbps."
        case .vorbis: return "Classic patent-free open-source lossy audio format (quality level 8, ~256 kbps)."
        case .wav: return "Uncompressed bit-for-bit 16-bit 44.1 kHz PCM audio in standard RIFF container."
        case .wavpack: return "Advanced open-source audio compression format with unique hybrid capabilities."
        case .mp3: return "Universal compatibility encoded at 320 kbps constant bitrate via open-source LAME."
        }
    }

    public var ffmpegAudioCodec: String {
        switch self {
        case .flac: return "flac"
        case .alac: return "alac"
        case .opus: return "libopus"
        case .vorbis: return "libvorbis"
        case .wav: return "pcm_s16le"
        case .wavpack: return "wavpack"
        case .mp3: return "libmp3lame"
        }
    }
}

public enum RipTrackState: Hashable, Equatable, Sendable {
    case idle
    case reading(progress: Double, pass: Int)
    case verifying(progress: Double)
    case encoding(progress: Double)
    case completed(crc: UInt32, accurateRipMatch: Bool?, message: String)
    case failed(error: String)

    public var isActive: Bool {
        switch self {
        case .reading, .verifying, .encoding:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    public var progress: Double {
        switch self {
        case .idle: return 0.0
        case .reading(let p, _): return p * 0.45
        case .verifying(let p): return 0.45 + (p * 0.25)
        case .encoding(let p): return 0.70 + (p * 0.30)
        case .completed: return 1.0
        case .failed: return 0.0
        }
    }

    public var statusDescription: String {
        switch self {
        case .idle:
            return "Ready"
        case .reading(let p, let pass):
            let pct = Int(p * 100)
            return pass > 1 ? "Re-reading pass \(pass) (\(pct)%)" : "Reading disc audio (\(pct)%)"
        case .verifying(let p):
            let pct = Int(p * 100)
            return "Verifying CRC accuracy (\(pct)%)"
        case .encoding(let p):
            let pct = Int(p * 100)
            return "Encoding audio (\(pct)%)"
        case .completed(let crc, let match, let msg):
            let crcHex = String(format: "%08X", crc)
            if match == true {
                return "AccurateRip Verified [CRC: \(crcHex)]"
            } else if !msg.isEmpty {
                return "\(msg) [CRC: \(crcHex)]"
            } else {
                return "Verified [CRC: \(crcHex)]"
            }
        case .failed(let err):
            return "Error: \(err)"
        }
    }
}

public struct OpticalTrack: Identifiable, Hashable, Equatable, Sendable {
    public let id: String
    public var trackNumber: Int
    public var title: String
    public var artist: String
    public var composer: String?
    public var duration: TimeInterval
    public var sectorStart: Int
    public var sectorCount: Int
    public var sourceURL: URL
    public var isrc: String?
    public var crc32: UInt32?
    public var accurateRipCRC: UInt32?
    public var ripState: RipTrackState = .idle

    public init(
        id: String? = nil,
        trackNumber: Int,
        title: String,
        artist: String,
        composer: String? = nil,
        duration: TimeInterval,
        sectorStart: Int = 0,
        sectorCount: Int = 0,
        sourceURL: URL,
        isrc: String? = nil,
        crc32: UInt32? = nil,
        accurateRipCRC: UInt32? = nil,
        ripState: RipTrackState = .idle
    ) {
        self.id = id ?? "optical_track_\(trackNumber)"
        self.trackNumber = trackNumber
        self.title = title
        self.artist = artist
        self.composer = composer
        self.duration = duration
        self.sectorStart = sectorStart
        self.sectorCount = sectorCount
        self.sourceURL = sourceURL
        self.isrc = isrc
        self.crc32 = crc32
        self.accurateRipCRC = accurateRipCRC
        self.ripState = ripState
    }

    public var formattedDuration: String {
        let total = Int(duration)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

public struct OpticalDisc: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var genre: String?
    public var mbid: String?
    public var barcode: String?
    public var artworkURL: URL?
    public var artworkData: Data?
    public var tracks: [OpticalTrack]
    public var volumeURL: URL?
    public var deviceName: String
    public var isSimulated: Bool
    public var accurateripDiscId: String?

    public init(
        id: String,
        title: String = "Audio CD",
        artist: String = "Unknown Artist",
        year: Int? = nil,
        genre: String? = nil,
        mbid: String? = nil,
        barcode: String? = nil,
        artworkURL: URL? = nil,
        artworkData: Data? = nil,
        tracks: [OpticalTrack] = [],
        volumeURL: URL? = nil,
        deviceName: String = "Optical Drive",
        isSimulated: Bool = false,
        accurateripDiscId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.genre = genre
        self.mbid = mbid
        self.barcode = barcode
        self.artworkURL = artworkURL
        self.artworkData = artworkData
        self.tracks = tracks
        self.volumeURL = volumeURL
        self.deviceName = deviceName
        self.isSimulated = isSimulated
        self.accurateripDiscId = accurateripDiscId
    }

    public var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    public var formattedTotalDuration: String {
        let total = Int(totalDuration)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d hr %d min", hours, mins)
        } else {
            return String(format: "%d min %d sec", mins, secs)
        }
    }
}
