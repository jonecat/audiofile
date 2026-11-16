import Foundation
import AVFoundation
import AppKit
import ImageIO

private struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

private final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let lock = NSLock()
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()
    private var negativeTrackIds = Set<String>()
    private var folderCoverURLs: [String: URL?] = [:]

    func image(forKey key: String) -> NSImage? {
        imageCache.object(forKey: key as NSString)
    }

    func setImage(_ image: NSImage, forKey key: String) {
        imageCache.setObject(image, forKey: key as NSString)
    }

    func isNegative(trackId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return negativeTrackIds.contains(trackId)
    }

    func markNegative(trackId: String) {
        lock.lock()
        defer { lock.unlock() }
        if negativeTrackIds.count > 5000 {
            negativeTrackIds.removeAll()
        }
        negativeTrackIds.insert(trackId)
    }

    func cachedFolderCoverURL(for folderPath: String) -> URL?? {
        lock.lock()
        defer { lock.unlock() }
        return folderCoverURLs[folderPath]
    }

    func setFolderCoverURL(_ url: URL?, for folderPath: String) {
        lock.lock()
        defer { lock.unlock() }
        folderCoverURLs.updateValue(url, forKey: folderPath)
    }

    func clear() {
        imageCache.removeAllObjects()
        lock.lock()
        negativeTrackIds.removeAll()
        folderCoverURLs.removeAll()
        lock.unlock()
    }
}

public struct MetadataReader: Sendable {
    private static let discTrackFilenameRegex = try! NSRegularExpression(pattern: #"^(\d{1,2})-(\d{1,3})(?:[\s.\-_]+)"#)
    private static let trackFilenameRegex = try! NSRegularExpression(pattern: #"^(\d{1,3})(?:[\s.\-_]+)"#)
    private static let folderArtworkNames = [
        "cover.jpg", "cover.png", "cover.jpeg",
        "folder.jpg", "folder.png",
        "front.jpg", "front.png",
        "album.jpg", "album.png"
    ]

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
        var formatName = formatDisplayName(for: ext)

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
        var replayGainTrackDb: Double? = nil
        var replayGainAlbumDb: Double? = nil
        var replayGainPeak: Double? = nil

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
            let formatID = fileFormat.streamDescription.pointee.mFormatID
            if formatID == kAudioFormatAppleLossless {
                formatName = "ALAC"
                let bits = Int(fileFormat.streamDescription.pointee.mBitsPerChannel)
                bitDepth = bits > 0 ? bits : 16
            } else if let depth = settings[AVLinearPCMBitDepthKey] as? Int {
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

        if bitrate == nil, duration > 0, let size = fileSize {
            bitrate = Int((Double(size * 8) / duration) / 1000.0)
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

                let extraInfoKey = ((try? await item.load(.extraAttributes))?[.info] as? String ?? "").uppercased()
                let tagName = [keyStr, idStr, extraInfoKey].joined(separator: " ")

                if tagName.contains("REPLAYGAIN_TRACK_GAIN"), replayGainTrackDb == nil, let db = parseReplayGainValue(valueStr) {
                    replayGainTrackDb = db
                } else if tagName.contains("REPLAYGAIN_ALBUM_GAIN"), replayGainAlbumDb == nil, let db = parseReplayGainValue(valueStr) {
                    replayGainAlbumDb = db
                } else if (tagName.contains("REPLAYGAIN_TRACK_PEAK") || tagName.contains("REPLAYGAIN_ALBUM_PEAK")), replayGainPeak == nil, let peak = parseReplayGainValue(valueStr), peak > 0 {
                    replayGainPeak = peak
                }

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
            modifiedDate: modifiedDate,
            replayGainTrackDb: replayGainTrackDb,
            replayGainAlbumDb: replayGainAlbumDb,
            replayGainPeak: replayGainPeak
        )
    }

    private static func parseReplayGainValue(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "dB", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    public static func clearArtworkCache() {
        ArtworkCache.shared.clear()
    }

    public static func isArtworkKnownMissing(for track: Track) -> Bool {
        ArtworkCache.shared.isNegative(trackId: track.id)
    }

    public static func cachedArtwork(for track: Track, maxPixelSize: Int? = 128) -> NSImage? {
        let cache = ArtworkCache.shared
        if cache.isNegative(trackId: track.id) {
            return nil
        }

        let sizeTag = maxPixelSize.map { String($0) } ?? "full"
        if let img = cache.image(forKey: "trk|\(track.id)|\(sizeTag)") {
            return img
        }

        let folderPath = track.path.deletingLastPathComponent().standardizedFileURL.path
        if let img = cache.image(forKey: "dir|\(folderPath)|\(sizeTag)") {
            return img
        }

        return nil
    }

    public static func loadArtwork(for track: Track, maxPixelSize: Int? = nil) async -> NSImage? {
        if let cached = cachedArtwork(for: track, maxPixelSize: maxPixelSize) {
            return cached
        }
        if ArtworkCache.shared.isNegative(trackId: track.id) {
            return nil
        }

        let sizeTag = maxPixelSize.map { String($0) } ?? "full"

        // 0. If this is an optical disc track, load the disc artwork
        if track.id.hasPrefix("optical_") || track.format == "CDDA" {
            let discArtData = await MainActor.run {
                OpticalDiscManager.shared.detectedDisc?.artworkData
            }
            if let data = discArtData {
                let boxed = await Task.detached(priority: .utility) { () -> SendableImage? in
                    guard let img = decodeImage(from: data, maxPixelSize: maxPixelSize) else {
                        return nil
                    }
                    ArtworkCache.shared.setImage(img, forKey: "trk|\(track.id)|\(sizeTag)")
                    return SendableImage(image: img)
                }.value
                if let img = boxed?.image {
                    return img
                }
            }
        }

        let parentDir = track.path.deletingLastPathComponent()
        let folderPath = parentDir.standardizedFileURL.path
        let isOptical = track.id.hasPrefix("optical_") || track.format == "CDDA"

        let boxed = await Task.detached(priority: .utility) { () -> SendableImage? in
            let cache = ArtworkCache.shared

            // 1. Check folder artwork first (cached folder lookup, faster and higher resolution)
            if let artURL = findFolderArtworkURL(in: parentDir),
               let img = decodeImage(at: artURL, maxPixelSize: maxPixelSize) {
                cache.setImage(img, forKey: "dir|\(folderPath)|\(sizeTag)")
                cache.setImage(img, forKey: "trk|\(track.id)|\(sizeTag)")
                return SendableImage(image: img)
            }

            if !track.hasCoverArt && !isOptical {
                cache.markNegative(trackId: track.id)
                return nil
            }

            // 2. Read embedded artwork from APEv2 / DSF / DFF custom parser if applicable
            if OpenSourceDecoders.requiresCustomDecoder(track.path) {
                let decodedMeta = OpenSourceDecoders.readMetadata(for: track.path)
                if let imgData = decodedMeta.embeddedArtwork,
                   let img = decodeImage(from: imgData, maxPixelSize: maxPixelSize) {
                    cache.setImage(img, forKey: "trk|\(track.id)|\(sizeTag)")
                    return SendableImage(image: img)
                }
            }

            // 3. Read embedded artwork from AVURLAsset
            let asset = AVURLAsset(url: track.path)
            if let metadata = try? await asset.load(.metadata) {
                for item in metadata {
                    if item.commonKey == .commonKeyArtwork || (item.key?.description ?? "").uppercased().contains("ARTWORK") {
                        if let data = try? await item.load(.dataValue),
                           let img = decodeImage(from: data, maxPixelSize: maxPixelSize) {
                            cache.setImage(img, forKey: "trk|\(track.id)|\(sizeTag)")
                            return SendableImage(image: img)
                        }
                    }
                }
            }

            cache.markNegative(trackId: track.id)
            return nil
        }.value

        return boxed?.image
    }

    public static func hasFolderArtwork(in dir: URL) -> Bool {
        findFolderArtworkURL(in: dir) != nil
    }

    private static func findFolderArtworkURL(in dir: URL) -> URL? {
        let folderPath = dir.standardizedFileURL.path
        if let cached = ArtworkCache.shared.cachedFolderCoverURL(for: folderPath) {
            return cached
        }

        let fm = FileManager.default
        var found: URL? = nil
        for name in folderArtworkNames {
            let candidate = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
        }
        ArtworkCache.shared.setFolderCoverURL(found, for: folderPath)
        return found
    }

    private static func decodeImage(at url: URL, maxPixelSize: Int?) -> NSImage? {
        guard let maxPx = maxPixelSize else {
            return NSImage(contentsOf: url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        return createThumbnail(from: source, maxPixelSize: maxPx) ?? NSImage(contentsOf: url)
    }

    private static func decodeImage(from data: Data, maxPixelSize: Int?) -> NSImage? {
        guard let maxPx = maxPixelSize else {
            return NSImage(data: data)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }
        return createThumbnail(from: source, maxPixelSize: maxPx) ?? NSImage(data: data)
    }

    private static func createThumbnail(from source: CGImageSource, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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

        let range = NSRange(name.startIndex..., in: name)

        // Match "1-03 Title" or "1-03. Title"
        if let match = discTrackFilenameRegex.firstMatch(in: name, range: range),
           let discRange = Range(match.range(at: 1), in: name),
           let trackRange = Range(match.range(at: 2), in: name),
           let disc = Int(name[discRange]),
           let track = Int(name[trackRange]),
           disc > 0, track > 0 {
            return (disc, track)
        }

        // Match "03 Title", "03 - Title", "03. Title" (1 to 3 digits so 4-digit years aren't matched)
        if let match = trackFilenameRegex.firstMatch(in: name, range: range),
           let trackRange = Range(match.range(at: 1), in: name),
           let track = Int(name[trackRange]),
           track > 0 {
            return (nil, track)
        }

        return (nil, nil)
    }
}
