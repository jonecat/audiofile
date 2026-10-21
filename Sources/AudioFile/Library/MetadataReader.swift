import Foundation
import AVFoundation
import AppKit

public struct MetadataReader: Sendable {
    public static let supportedExtensions: Set<String> = [
        "flac", "alac", "wav", "wave", "aiff", "aif", "m4a", "aac", "mp3", "caf",
        "ape", "dsf", "dff", "dsd"
    ]

    public static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    public static func readTrack(at url: URL) async -> Track? {
        guard isAudioFile(url) else { return nil }

        let ext = url.pathExtension.lowercased()
        let formatName = formatDisplayName(for: ext)

        var title: String = ""
        var artist: String = ""
        var album: String = ""
        var albumArtist: String? = nil
        var genre: String? = nil
        var year: Int? = nil
        var releaseDate: String? = nil
        var trackNumber: Int? = nil
        var discNumber: Int? = nil
        var duration: TimeInterval = 0
        var sampleRate: Double? = nil
        var bitDepth: Int? = nil
        var bitrate: Int? = nil
        var hasCoverArt: Bool = false

        // 1. File stats
        let fileValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = fileValues?.fileSize.map { UInt64($0) }
        let modifiedDate = fileValues?.contentModificationDate

        // 2. Read technical audio properties & tags for APE / DSD formats or via AVAudioFile
        if OpenSourceDecoders.requiresCustomDecoder(url) {
            let decodedMeta = OpenSourceDecoders.readMetadata(for: url)
            title = decodedMeta.title
            artist = decodedMeta.artist
            album = decodedMeta.album
            albumArtist = decodedMeta.albumArtist
            genre = decodedMeta.genre
            year = decodedMeta.year
            trackNumber = decodedMeta.trackNumber
            discNumber = decodedMeta.discNumber
            duration = decodedMeta.duration
            sampleRate = decodedMeta.sampleRate
            bitDepth = decodedMeta.bitDepth
            bitrate = decodedMeta.bitrate
            hasCoverArt = decodedMeta.hasCoverArt
        } else if let audioFile = try? AVAudioFile(forReading: url) {
            let fileFormat = audioFile.fileFormat
            sampleRate = fileFormat.sampleRate
            duration = Double(audioFile.length) / fileFormat.sampleRate

            if let size = fileSize, duration > 0 {
                bitrate = Int((Double(size * 8) / duration) / 1000.0)
            }

            // Estimate bit depth from format settings
            let settings = fileFormat.settings
            if let depth = settings[AVLinearPCMBitDepthKey] as? Int {
                bitDepth = depth
            } else if ext == "flac" || ext == "alac" {
                // Typical lossless bit depth
                bitDepth = 16
            }
        }

        // 3. Extract metadata tags with AVURLAsset
        let asset = AVURLAsset(url: url)
        if duration == 0 {
            if let dur = try? await asset.load(.duration) {
                duration = CMTimeGetSeconds(dur)
            }
        }

        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                let idStr = (item.identifier?.rawValue ?? "").uppercased()
                let keyStr = (item.commonKey?.rawValue ?? item.key?.description ?? "").uppercased()
                if keyStr.contains("MUSICBRAINZ") || keyStr.contains("DISCID") || keyStr.contains("ACOUSTID") || keyStr.contains("VENDOR") || keyStr.contains("SORT") {
                    continue
                }

                // Check for track number (M4A/iTunes 'trkn', ID3 'TRCK', Vorbis 'TRACKNUMBER')
                let isTrackNumberTag = item.identifier == .iTunesMetadataTrackNumber
                    || item.identifier == .id3MetadataTrackNumber
                    || idStr.hasSuffix("/TRKN")
                    || idStr.hasSuffix("/TRCK")
                    || keyStr == "TRACKNUMBER"
                    || keyStr == "TRACK"
                    || keyStr == "TRKN"
                    || keyStr == "TRCK"

                if isTrackNumberTag && trackNumber == nil {
                    trackNumber = await extractMetadataIndex(from: item)
                }

                // Check for disc number (M4A/iTunes 'disk', ID3 'TPOS', Vorbis 'DISCNUMBER')
                let isDiscNumberTag = item.identifier == .iTunesMetadataDiscNumber
                    || item.identifier == .id3MetadataPartOfASet
                    || idStr.hasSuffix("/DISK")
                    || idStr.hasSuffix("/TPOS")
                    || keyStr == "DISCNUMBER"
                    || keyStr == "DISC"
                    || keyStr == "DISK"
                    || keyStr == "TPOS"

                if isDiscNumberTag && discNumber == nil {
                    discNumber = await extractMetadataIndex(from: item)
                }

                let rawVal = (try? await item.load(.stringValue)) ?? ""
                let valueStr = rawVal.trimmingCharacters(in: .whitespacesAndNewlines)

                // Skip UUIDs and empty strings for text tags
                let isId = !valueStr.isEmpty && UUID(uuidString: valueStr) != nil

                if !valueStr.isEmpty && !isId {
                    if (item.commonKey == .commonKeyTitle || keyStr == "TITLE" || keyStr == "TRACK_TITLE") && title.isEmpty {
                        title = valueStr
                    } else if (item.commonKey == .commonKeyArtist || keyStr == "ARTIST" || keyStr == "AUTHOR" || keyStr == "PERFORMER") && artist.isEmpty {
                        artist = valueStr
                    } else if (item.commonKey == .commonKeyAlbumName || keyStr == "ALBUM" || keyStr == "ALBUMNAME") && album.isEmpty {
                        album = valueStr
                    } else if (item.identifier == .iTunesMetadataAlbumArtist || item.identifier == .id3MetadataBand || keyStr == "ALBUMARTIST" || keyStr == "ALBUM ARTIST" || keyStr == "BAND" || idStr.hasSuffix("/AART")) && albumArtist == nil {
                        albumArtist = valueStr
                    } else if (item.commonKey == .commonKeyType || keyStr == "GENRE") && genre == nil {
                        genre = valueStr
                    } else if (item.commonKey == .commonKeyCreationDate || item.identifier == .iTunesMetadataReleaseDate || keyStr == "DATE" || keyStr == "YEAR" || keyStr == "ORIGINALDATE" || keyStr == "ORIGINALYEAR") && releaseDate == nil {
                        releaseDate = valueStr
                        if let y = extractYear(from: valueStr) {
                            year = y
                        }
                    }
                }

                // Check for embedded artwork
                if item.commonKey == .commonKeyArtwork || keyStr.contains("ARTWORK") || keyStr.contains("PICTURE") {
                    hasCoverArt = true
                }
            }
        }

        // Fallback track / disc number from filename prefix (e.g. "03 Blue Jeans.m4a" or "1-03 Song.m4a")
        if trackNumber == nil {
            let parsed = extractTrackAndDiscFromFilename(url)
            if let t = parsed.track {
                trackNumber = t
            }
            if discNumber == nil, let d = parsed.disc {
                discNumber = d
            }
        }

        // Fallback title from filename
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            title = url.deletingPathExtension().lastPathComponent
        }

        // Fallback artist / album from folder hierarchy if missing
        let parent = url.deletingLastPathComponent()
        if album.trimmingCharacters(in: .whitespaces).isEmpty {
            album = parent.lastPathComponent
        }
        if artist.trimmingCharacters(in: .whitespaces).isEmpty {
            let grandparent = parent.deletingLastPathComponent()
            if grandparent.path != "/" && grandparent.lastPathComponent != "Music" {
                artist = grandparent.lastPathComponent
            } else {
                artist = "Unknown Artist"
            }
        }

        // Check for folder cover art if no embedded artwork
        if !hasCoverArt {
            hasCoverArt = hasFolderArtwork(in: parent)
        }

        return Track(
            path: url,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            year: year,
            releaseDate: releaseDate,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            format: formatName,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            bitrate: bitrate,
            hasCoverArt: hasCoverArt,
            fileSize: fileSize,
            modifiedDate: modifiedDate
        )
    }

    public static func loadArtwork(for track: Track) async -> NSImage? {
        let parentDir = track.path.deletingLastPathComponent()

        // 1. Check folder artwork first (often higher resolution and faster to load)
        let commonNames = ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "front.png", "album.jpg", "album.png"]
        for name in commonNames {
            let artURL = parentDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: artURL.path),
               let image = NSImage(contentsOf: artURL) {
                return image
            }
        }

        // 2. Read embedded artwork from APEv2 / DSF / DFF custom parser if applicable
        if OpenSourceDecoders.requiresCustomDecoder(track.path) {
            let decodedMeta = OpenSourceDecoders.readMetadata(for: track.path)
            if let imgData = decodedMeta.embeddedArtwork, let img = NSImage(data: imgData) {
                return img
            }
        }

        // 3. Read embedded artwork from AVURLAsset
        let asset = AVURLAsset(url: track.path)
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                if item.commonKey == .commonKeyArtwork || (item.key?.description ?? "").uppercased().contains("ARTWORK") {
                    if let data = try? await item.load(.dataValue), let img = NSImage(data: data) {
                        return img
                    }
                }
            }
        }

        return nil
    }

    public static func hasFolderArtwork(in dir: URL) -> Bool {
        let commonNames = ["cover.jpg", "cover.png", "cover.jpeg", "folder.jpg", "folder.png", "front.jpg", "front.png", "album.jpg", "album.png"]
        for name in commonNames {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                return true
            }
        }
        return false
    }

    private static func formatDisplayName(for ext: String) -> String {
        switch ext.lowercased() {
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "wav", "wave": return "WAV"
        case "aiff", "aif": return "AIFF"
        case "m4a": return "M4A"
        case "aac": return "AAC"
        case "mp3": return "MP3"
        case "caf": return "CAF"
        case "ape": return "APE"
        case "dsf", "dff", "dsd": return "DSD"
        default: return ext.uppercased()
        }
    }

    private static func extractYear(from str: String) -> Int? {
        let components = str.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { $0.count == 4 }
        if let first = components.first, let y = Int(first) {
            return y
        }
        return nil
    }

    private static func extractNumber(from str: String) -> Int? {
        let parts = str.components(separatedBy: "/")
        if let first = parts.first?.trimmingCharacters(in: .whitespaces), let num = Int(first), num > 0 {
            return num
        }
        return nil
    }

    private static func extractMetadataIndex(from item: AVMetadataItem) async -> Int? {
        // 1. Try string value (e.g. "3" or "3/12")
        if let str = try? await item.load(.stringValue),
           let num = extractNumber(from: str) {
            return num
        }

        // 2. Try numeric value
        if let number = try? await item.load(.numberValue),
           number.intValue > 0 {
            return number.intValue
        }

        // 3. Try binary atom payload (Apple MP4/M4A 'trkn' and 'disk' atoms store UInt16 big-endian at bytes 2..3)
        if let data = try? await item.load(.dataValue), data.count >= 4 {
            let base = data.startIndex
            let index = (Int(data[base + 2]) << 8) | Int(data[base + 3])
            if index > 0 {
                return index
            }
        }

        return nil
    }

    public static func extractTrackAndDiscFromFilename(_ url: URL) -> (disc: Int?, track: Int?) {
        let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return (nil, nil) }

        // Match "1-03 Title" or "1-03. Title"
        if let regex = try? NSRegularExpression(pattern: #"^(\d{1,2})-(\d{1,3})(?:[\s.\-_]+)"#),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let discRange = Range(match.range(at: 1), in: name),
           let trackRange = Range(match.range(at: 2), in: name),
           let disc = Int(name[discRange]),
           let track = Int(name[trackRange]),
           disc > 0, track > 0 {
            return (disc, track)
        }

        // Match "03 Title", "03 - Title", "03. Title" (1 to 3 digits so 4-digit years aren't matched)
        if let regex = try? NSRegularExpression(pattern: #"^(\d{1,3})(?:[\s.\-_]+)"#),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let trackRange = Range(match.range(at: 1), in: name),
           let track = Int(name[trackRange]),
           track > 0 {
            return (nil, track)
        }

        return (nil, nil)
    }
}
