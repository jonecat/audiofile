import Foundation
import AVFoundation
import ImageIO

// MARK: - Full Track Tag Models

public struct TagFieldItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let rawKey: String
    public let displayName: String
    public let value: String
    public let detail: String?
    public let isMultiline: Bool

    public init(
        id: String,
        rawKey: String,
        displayName: String,
        value: String,
        detail: String? = nil,
        isMultiline: Bool = false
    ) {
        self.id = id
        self.rawKey = rawKey
        self.displayName = displayName
        self.value = value
        self.detail = detail
        self.isMultiline = isMultiline
    }
}

public struct TagSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let items: [TagFieldItem]

    public init(id: String, title: String, subtitle: String, items: [TagFieldItem]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }
}

public struct FullTrackTagReport: Equatable, Sendable {
    public let sections: [TagSection]

    public init(sections: [TagSection]) {
        self.sections = sections
    }

    public var totalTagCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    public var isEmpty: Bool {
        totalTagCount == 0
    }

    public func formattedPlainText(for track: Track) -> String {
        var lines: [String] = [
            "Track: \(track.displayTitle)",
            "Artist: \(track.displayArtist)",
            "Album: \(track.displayAlbum)",
            "Format: \(track.format.uppercased())",
            "File: \(track.path.path)"
        ]

        for section in sections {
            lines.append("")
            lines.append("[\(section.title)] \(section.subtitle)")
            for item in section.items {
                if let detail = item.detail, !detail.isEmpty {
                    lines.append("\(item.rawKey) | \(item.displayName): \(item.value) (\(detail))")
                } else {
                    lines.append("\(item.rawKey) | \(item.displayName): \(item.value)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Full Tag Reader

public enum FullTagReader {
    private static let maxTagReadBytes = 16 * 1024 * 1024

    public static func readAllTags(for url: URL) async -> FullTrackTagReport {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return FullTrackTagReport(sections: [])
            }

            let ext = url.pathExtension.lowercased()
            var sections: [TagSection] = []

            switch ext {
            case "mp3":
                sections.append(contentsOf: readMP3Tags(url: url))
            case "flac":
                sections.append(contentsOf: readFLACTags(url: url))
            case "wav", "wave":
                sections.append(contentsOf: readWAVTags(url: url))
            case "aiff", "aif":
                sections.append(contentsOf: readAIFFTags(url: url))
            case "dsf":
                sections.append(contentsOf: readDSFTags(url: url))
            case "dff", "dsd":
                sections.append(contentsOf: readDFFTags(url: url))
            case "ape":
                sections.append(contentsOf: readAPETags(url: url))
            case "m4a", "alac", "aac", "caf":
                sections.append(contentsOf: await readAVFoundationTags(url: url))
            default:
                break
            }

            // Fallback to AVURLAsset if native container inspection found no tag sections
            if sections.isEmpty {
                sections.append(contentsOf: await readAVFoundationTags(url: url))
            }

            return FullTrackTagReport(sections: sections)
        }.value
    }

    // MARK: - MP3 (ID3v2 + APEv2 + ID3v1/v1.1)

    private static func readMP3Tags(url: URL) -> [TagSection] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let fileSize = fileByteSize(handle: handle)
        var sections: [TagSection] = []

        // 1. ID3v2 header at offset 0
        if let head = readBytes(handle: handle, offset: 0, count: 10),
           head.count == 10,
           asciiString(head, range: 0..<3) == "ID3" {
            let tagSize = synchsafeInt(head, offset: 6)
            let hasFooter = (head[head.startIndex + 5] & 0x10) != 0
            let totalRead = min(maxTagReadBytes, 10 + tagSize + (hasFooter ? 10 : 0))
            if let id3Data = readBytes(handle: handle, offset: 0, count: totalRead),
               let section = parseID3v2Section(data: id3Data, sectionIndex: sections.count) {
                sections.append(section)
            }
        }

        // 2. ID3v1 / ID3v1.1 footer at fileSize - 128
        var hasID3v1 = false
        if fileSize >= 128,
           let v1Data = readBytes(handle: handle, offset: fileSize - 128, count: 128),
           let v1Section = parseID3v1Section(data: v1Data) {
            hasID3v1 = true
            sections.append(v1Section)
        }

        // 3. APEv2 tag before ID3v1 (or at EOF)
        var apeCandidates: [UInt64] = []
        if hasID3v1, fileSize >= 160 {
            apeCandidates.append(fileSize - 160)
        }
        if fileSize >= 32 {
            apeCandidates.append(fileSize - 32)
        }
        for candidateOffset in apeCandidates {
            if let apeSection = readAPEv2AtFooter(handle: handle, fileSize: fileSize, footerOffset: candidateOffset) {
                sections.insert(apeSection, at: hasID3v1 ? max(0, sections.count - 1) : sections.count)
                break
            }
        }

        return sections
    }

    // MARK: - FLAC (Optional prepended ID3v2 + Vorbis Comments + Pictures)

    private static func readFLACTags(url: URL) -> [TagSection] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let fileSize = fileByteSize(handle: handle)
        var sections: [TagSection] = []
        var offset: UInt64 = 0

        // Handle rare FLAC files with prepended ID3v2 tag
        if let head = readBytes(handle: handle, offset: 0, count: 10),
           head.count == 10,
           asciiString(head, range: 0..<3) == "ID3" {
            let tagSize = synchsafeInt(head, offset: 6)
            let hasFooter = (head[head.startIndex + 5] & 0x10) != 0
            let totalID3 = UInt64(10 + tagSize + (hasFooter ? 10 : 0))
            let readCount = Int(min(UInt64(maxTagReadBytes), totalID3))
            if let id3Data = readBytes(handle: handle, offset: 0, count: readCount),
               let id3Section = parseID3v2Section(data: id3Data, sectionIndex: sections.count) {
                sections.append(id3Section)
            }
            offset = totalID3
        }

        guard let marker = readBytes(handle: handle, offset: offset, count: 4),
              asciiString(marker, range: 0..<4) == "fLaC" else {
            return sections
        }
        offset += 4

        var vorbisItems: [TagFieldItem] = []
        var vorbisVendor: String?
        var pictureItems: [TagFieldItem] = []

        while offset + 4 <= fileSize {
            guard let blockHeader = readBytes(handle: handle, offset: offset, count: 4),
                  blockHeader.count == 4 else {
                break
            }
            let b0 = blockHeader[blockHeader.startIndex]
            let isLast = (b0 & 0x80) != 0
            let blockType = b0 & 0x7F
            let blockLen = Int(readUInt24BE(blockHeader, offset: 1))
            offset += 4

            guard blockLen >= 0, offset + UInt64(blockLen) <= fileSize else { break }

            if blockType == 4 && blockLen <= maxTagReadBytes {
                if let blockData = readBytes(handle: handle, offset: offset, count: blockLen) {
                    let parsed = parseVorbisCommentBlock(data: blockData)
                    vorbisVendor = parsed.vendor
                    vorbisItems.append(contentsOf: parsed.items)
                }
            } else if blockType == 6 && blockLen <= maxTagReadBytes {
                // Only need picture header bytes (MIME + description + dimensions)
                if let picData = readBytes(handle: handle, offset: offset, count: min(blockLen, 8192)),
                   let picItem = parseFLACPictureBlock(data: picData, index: pictureItems.count) {
                    pictureItems.append(picItem)
                }
            }

            offset += UInt64(blockLen)
            if isLast { break }
        }

        if !vorbisItems.isEmpty || (vorbisVendor != nil && !vorbisVendor!.isEmpty) {
            var subtitleParts = ["\(vorbisItems.count) \(vorbisItems.count == 1 ? "tag" : "tags")"]
            if let vendor = vorbisVendor, !vendor.isEmpty {
                subtitleParts.append("Vendor: \(vendor)")
            }
            sections.append(TagSection(
                id: "vorbis_flac",
                title: "Vorbis Comments (FLAC)",
                subtitle: subtitleParts.joined(separator: " • "),
                items: vorbisItems
            ))
        }

        if !pictureItems.isEmpty {
            sections.append(TagSection(
                id: "flac_pictures",
                title: "FLAC Picture Blocks",
                subtitle: "\(pictureItems.count) \(pictureItems.count == 1 ? "image" : "images")",
                items: pictureItems
            ))
        }

        return sections
    }

    private static func parseVorbisCommentBlock(data: Data) -> (vendor: String?, items: [TagFieldItem]) {
        let base = data.startIndex
        var pos = 0
        guard pos + 4 <= data.count else { return (nil, []) }

        let vendorLen = Int(readUInt32LE(data, offset: pos))
        pos += 4
        guard vendorLen >= 0, pos + vendorLen <= data.count else { return (nil, []) }
        let vendor = String(data: data[(base + pos)..<(base + pos + vendorLen)], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pos += vendorLen

        guard pos + 4 <= data.count else { return (vendor, []) }
        let commentCount = Int(readUInt32LE(data, offset: pos))
        pos += 4

        var items: [TagFieldItem] = []
        let safeCount = min(commentCount, 4096)
        for i in 0..<safeCount {
            guard pos + 4 <= data.count else { break }
            let len = Int(readUInt32LE(data, offset: pos))
            pos += 4
            guard len >= 0, pos + len <= data.count else { break }

            let rawComment = String(data: data[(base + pos)..<(base + pos + len)], encoding: .utf8) ?? ""
            pos += len

            guard let eqIdx = rawComment.firstIndex(of: "=") else { continue }
            let key = String(rawComment[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let val = String(rawComment[rawComment.index(after: eqIdx)...])
                .trimmingCharacters(in: CharacterSet.newlines)
            guard !key.isEmpty else { continue }

            let display = vorbisFieldDisplayName(key)
            let isMulti = val.contains("\n") || val.count > 140
            items.append(TagFieldItem(
                id: "vorbis_\(i)_\(key)",
                rawKey: key.uppercased(),
                displayName: display,
                value: val,
                detail: nil,
                isMultiline: isMulti
            ))
        }

        return (vendor, items)
    }

    private static func parseFLACPictureBlock(data: Data, index: Int) -> TagFieldItem? {
        let base = data.startIndex
        var pos = 0
        guard pos + 8 <= data.count else { return nil }

        let picType = UInt8(clamping: readUInt32BE(data, offset: pos))
        pos += 4

        let mimeLen = Int(readUInt32BE(data, offset: pos))
        pos += 4
        guard mimeLen >= 0, pos + mimeLen + 4 <= data.count else { return nil }
        let mime = String(data: data[(base + pos)..<(base + pos + mimeLen)], encoding: .utf8) ?? "image/*"
        pos += mimeLen

        let descLen = Int(readUInt32BE(data, offset: pos))
        pos += 4
        guard descLen >= 0, pos + descLen + 20 <= data.count else { return nil }
        let desc = String(data: data[(base + pos)..<(base + pos + descLen)], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pos += descLen

        let width = readUInt32BE(data, offset: pos)
        let height = readUInt32BE(data, offset: pos + 4)
        let depth = readUInt32BE(data, offset: pos + 8)
        let dataLen = readUInt32BE(data, offset: pos + 16)

        let typeLabel = id3PictureTypeName(picType)
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(dataLen), countStyle: .file)
        var summaryParts = [mime]
        if width > 0 && height > 0 {
            summaryParts.append("\(width)×\(height)")
        }
        if depth > 0 {
            summaryParts.append("\(depth)-bit")
        }
        summaryParts.append(sizeStr)

        let value = desc.isEmpty
            ? summaryParts.joined(separator: " • ")
            : "\"\(desc)\" — \(summaryParts.joined(separator: " • "))"

        return TagFieldItem(
            id: "flac_pic_\(index)",
            rawKey: "METADATA_BLOCK_PICTURE",
            displayName: "Picture (\(typeLabel))",
            value: value,
            detail: typeLabel,
            isMultiline: false
        )
    }

    // MARK: - WAV (RIFF INFO + id3 chunk)

    private static func readWAVTags(url: URL) -> [TagSection] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let fileSize = fileByteSize(handle: handle)
        guard fileSize >= 12,
              let head = readBytes(handle: handle, offset: 0, count: 12),
              head.count == 12,
              asciiString(head, range: 0..<4) == "RIFF",
              asciiString(head, range: 8..<12) == "WAVE" else {
            return []
        }

        var sections: [TagSection] = []
        var infoItems: [TagFieldItem] = []
        var offset: UInt64 = 12

        while offset + 8 <= fileSize {
            guard let chunkHeader = readBytes(handle: handle, offset: offset, count: 8),
                  chunkHeader.count == 8 else {
                break
            }
            let chunkID = asciiString(chunkHeader, range: 0..<4)
            let chunkSize = UInt64(readUInt32LE(chunkHeader, offset: 4))
            let dataStart = offset + 8

            if (chunkID == "id3 " || chunkID == "ID3 ") && chunkSize > 0 && chunkSize <= UInt64(maxTagReadBytes) {
                if let id3Data = readBytes(handle: handle, offset: dataStart, count: Int(chunkSize)),
                   let section = parseID3v2Section(data: id3Data, sectionIndex: sections.count) {
                    sections.append(section)
                }
            } else if chunkID == "LIST" && chunkSize >= 4 && chunkSize <= UInt64(maxTagReadBytes) {
                if let listTypeData = readBytes(handle: handle, offset: dataStart, count: 4),
                   asciiString(listTypeData, range: 0..<4) == "INFO",
                   let infoData = readBytes(handle: handle, offset: dataStart + 4, count: Int(chunkSize - 4)) {
                    infoItems.append(contentsOf: parseRIFFInfoSubchunks(data: infoData))
                }
            }

            let paddedSize = chunkSize + (chunkSize & 1)
            if paddedSize == 0 && chunkSize == 0 {
                offset = dataStart
            } else {
                offset = dataStart + paddedSize
            }
        }

        if !infoItems.isEmpty {
            sections.append(TagSection(
                id: "riff_info",
                title: "RIFF INFO",
                subtitle: "\(infoItems.count) \(infoItems.count == 1 ? "chunk" : "chunks")",
                items: infoItems
            ))
        }

        return sections
    }

    private static func parseRIFFInfoSubchunks(data: Data) -> [TagFieldItem] {
        let base = data.startIndex
        var pos = 0
        var items: [TagFieldItem] = []

        while pos + 8 <= data.count {
            let subID = asciiString(data, range: pos..<(pos + 4))
            let subSize = Int(readUInt32LE(data, offset: pos + 4))
            pos += 8
            guard subSize >= 0, pos + subSize <= data.count else { break }

            let payload = data[(base + pos)..<(base + pos + subSize)]
            let padded = subSize + (subSize & 1)
            pos += padded

            let rawText = decodeBestEffortText(Data(payload))
            if !rawText.isEmpty {
                items.append(TagFieldItem(
                    id: "riff_\(items.count)_\(subID)",
                    rawKey: subID,
                    displayName: riffInfoDisplayName(subID),
                    value: rawText,
                    detail: nil,
                    isMultiline: rawText.contains("\n") || rawText.count > 140
                ))
            }
        }

        return items
    }

    // MARK: - AIFF (ID3 chunk + NAME/AUTH/(c)/ANNO chunks)

    private static func readAIFFTags(url: URL) -> [TagSection] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let fileSize = fileByteSize(handle: handle)
        guard fileSize >= 12,
              let head = readBytes(handle: handle, offset: 0, count: 12),
              head.count == 12,
              asciiString(head, range: 0..<4) == "FORM" else {
            return []
        }
        let formType = asciiString(head, range: 8..<12)
        guard formType == "AIFF" || formType == "AIFC" else { return [] }

        var sections: [TagSection] = []
        var textItems: [TagFieldItem] = []
        var offset: UInt64 = 12

        while offset + 8 <= fileSize {
            guard let chunkHeader = readBytes(handle: handle, offset: offset, count: 8),
                  chunkHeader.count == 8 else {
                break
            }
            let chunkID = asciiString(chunkHeader, range: 0..<4)
            let chunkSize = UInt64(readUInt32BE(chunkHeader, offset: 4))
            let dataStart = offset + 8

            if (chunkID == "ID3 " || chunkID == "id3 ") && chunkSize > 0 && chunkSize <= UInt64(maxTagReadBytes) {
                if let id3Data = readBytes(handle: handle, offset: dataStart, count: Int(chunkSize)),
                   let section = parseID3v2Section(data: id3Data, sectionIndex: sections.count) {
                    sections.append(section)
                }
            } else if (chunkID == "NAME" || chunkID == "AUTH" || chunkID == "(c) " || chunkID == "ANNO"),
                      chunkSize > 0, chunkSize <= 256 * 1024 {
                if let textData = readBytes(handle: handle, offset: dataStart, count: Int(chunkSize)) {
                    let val = decodeBestEffortText(textData)
                    if !val.isEmpty {
                        let label: String
                        switch chunkID {
                        case "NAME": label = "Title (NAME)"
                        case "AUTH": label = "Author / Artist (AUTH)"
                        case "(c) ": label = "Copyright"
                        case "ANNO": label = "Annotation"
                        default: label = chunkID
                        }
                        textItems.append(TagFieldItem(
                            id: "aiff_\(textItems.count)_\(chunkID)",
                            rawKey: chunkID.trimmingCharacters(in: .whitespaces),
                            displayName: label,
                            value: val,
                            detail: nil,
                            isMultiline: val.contains("\n") || val.count > 140
                        ))
                    }
                }
            }

            let paddedSize = chunkSize + (chunkSize & 1)
            offset = dataStart + paddedSize
        }

        if !textItems.isEmpty {
            sections.append(TagSection(
                id: "aiff_meta",
                title: "AIFF Chunks",
                subtitle: "\(textItems.count) \(textItems.count == 1 ? "chunk" : "chunks")",
                items: textItems
            ))
        }

        return sections
    }

    // MARK: - DSF / DFF (Embedded ID3v2)

    private static func readDSFTags(url: URL) -> [TagSection] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let header = readBytes(handle: handle, offset: 0, count: 28),
              header.count == 28,
              asciiString(header, range: 0..<4) == "DSD " else {
            return []
        }

        let totalFileSize = readUInt64LE(header, offset: 12)
        let metadataOffset = readUInt64LE(header, offset: 20)
        let fileSize = max(totalFileSize, fileByteSize(handle: handle))

        guard metadataOffset > 0 && metadataOffset < fileSize else { return [] }
        let readCount = Int(min(fileSize - metadataOffset, UInt64(maxTagReadBytes)))
        guard let id3Data = readBytes(handle: handle, offset: metadataOffset, count: readCount),
              let section = parseID3v2Section(data: id3Data, sectionIndex: 0) else {
            return []
        }
        return [section]
    }

    private static func readDFFTags(url: URL) -> [TagSection] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let header = readBytes(handle: handle, offset: 0, count: 16),
              header.count == 16,
              asciiString(header, range: 0..<4) == "FRM8",
              asciiString(header, range: 12..<16) == "DSD " else {
            return []
        }

        let fileSize = min(readUInt64BE(header, offset: 4) + 12, fileByteSize(handle: handle))
        var offset: UInt64 = 16
        var sections: [TagSection] = []

        while offset + 12 <= fileSize {
            guard let chunkHeader = readBytes(handle: handle, offset: offset, count: 12),
                  chunkHeader.count == 12 else {
                break
            }
            let chunkID = asciiString(chunkHeader, range: 0..<4)
            let chunkSize = readUInt64BE(chunkHeader, offset: 4)
            let dataStart = offset + 12

            if (chunkID == "ID3 " || chunkID == "id3 ") && chunkSize > 0 && chunkSize <= UInt64(maxTagReadBytes) {
                if let id3Data = readBytes(handle: handle, offset: dataStart, count: Int(chunkSize)),
                   let section = parseID3v2Section(data: id3Data, sectionIndex: sections.count) {
                    sections.append(section)
                }
            }

            let padded = chunkSize &+ (chunkSize & 1)
            let (nextOffset, overflow) = dataStart.addingReportingOverflow(padded)
            if overflow || nextOffset <= offset { break }
            offset = nextOffset
        }

        return sections
    }

    // MARK: - APE / APEv2

    private static func readAPETags(url: URL) -> [TagSection] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let fileSize = fileByteSize(handle: handle)
        var sections: [TagSection] = []

        var hasID3v1 = false
        if fileSize >= 128,
           let v1Data = readBytes(handle: handle, offset: fileSize - 128, count: 128),
           let v1Section = parseID3v1Section(data: v1Data) {
            hasID3v1 = true
            sections.append(v1Section)
        }

        var apeCandidates: [UInt64] = []
        if hasID3v1, fileSize >= 160 {
            apeCandidates.append(fileSize - 160)
        }
        if fileSize >= 32 {
            apeCandidates.append(fileSize - 32)
        }
        for candidateOffset in apeCandidates {
            if let apeSection = readAPEv2AtFooter(handle: handle, fileSize: fileSize, footerOffset: candidateOffset) {
                sections.insert(apeSection, at: 0)
                break
            }
        }

        return sections
    }

    private static func readAPEv2AtFooter(handle: FileHandle, fileSize: UInt64, footerOffset: UInt64) -> TagSection? {
        guard footerOffset + 32 <= fileSize,
              let footer = readBytes(handle: handle, offset: footerOffset, count: 32),
              footer.count == 32,
              asciiString(footer, range: 0..<8) == "APETAGEX" else {
            return nil
        }

        let version = readUInt32LE(footer, offset: 8)
        let tagSize = UInt64(readUInt32LE(footer, offset: 12))
        let itemCount = Int(readUInt32LE(footer, offset: 16))
        guard tagSize >= 32, tagSize <= footerOffset + 32, tagSize <= UInt64(maxTagReadBytes) else {
            return nil
        }

        let itemsStart = (footerOffset + 32) - tagSize
        let itemsByteCount = Int(tagSize - 32)
        guard let tagData = readBytes(handle: handle, offset: itemsStart, count: itemsByteCount) else {
            return nil
        }

        let base = tagData.startIndex
        var pos = 0
        var items: [TagFieldItem] = []

        for i in 0..<min(itemCount, 4096) {
            guard pos + 8 <= tagData.count else { break }
            let valSize = Int(readUInt32LE(tagData, offset: pos))
            let flags = readUInt32LE(tagData, offset: pos + 4)
            pos += 8

            guard let nullIdx = tagData[(base + pos)...].firstIndex(of: 0) else { break }
            let keyData = tagData[(base + pos)..<nullIdx]
            let key = String(data: keyData, encoding: .utf8) ?? ""
            pos = (nullIdx - base) + 1

            guard valSize >= 0, pos + valSize <= tagData.count else { break }
            let valData = tagData[(base + pos)..<(base + pos + valSize)]
            pos += valSize

            let itemType = (flags >> 1) & 0x3
            if itemType == 1 {
                if key.lowercased().contains("cover art"),
                   let binNull = valData.firstIndex(of: 0),
                   binNull + 1 < valData.endIndex {
                    let filename = String(data: valData[valData.startIndex..<binNull], encoding: .utf8) ?? ""
                    let imgBytes = Data(valData[(binNull + 1)...])
                    let summary = describeImageData(imgBytes, labelPrefix: filename.isEmpty ? nil : filename)
                    items.append(TagFieldItem(
                        id: "ape_\(i)_\(key)",
                        rawKey: key,
                        displayName: vorbisFieldDisplayName(key),
                        value: summary,
                        detail: "Binary Artwork",
                        isMultiline: false
                    ))
                } else {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(valData.count), countStyle: .file)
                    items.append(TagFieldItem(
                        id: "ape_\(i)_\(key)",
                        rawKey: key,
                        displayName: vorbisFieldDisplayName(key),
                        value: "Binary payload (\(sizeStr)) • \(hexPreview(Data(valData), maxBytes: 16))",
                        detail: "Binary",
                        isMultiline: false
                    ))
                }
            } else {
                // Split NUL-separated multi-values
                let parts = Data(valData).split(separator: 0).compactMap {
                    String(data: Data($0), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                let joined = parts.joined(separator: " / ")
                if !joined.isEmpty {
                    items.append(TagFieldItem(
                        id: "ape_\(i)_\(key)",
                        rawKey: key,
                        displayName: vorbisFieldDisplayName(key),
                        value: joined,
                        detail: itemType == 2 ? "URL / Locator" : nil,
                        isMultiline: joined.contains("\n") || joined.count > 140
                    ))
                }
            }
        }

        guard !items.isEmpty else { return nil }
        let verName = version >= 2000 ? "APEv2" : "APEv1"
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(tagSize), countStyle: .file)
        return TagSection(
            id: "ape_\(verName)",
            title: verName,
            subtitle: "\(items.count) \(items.count == 1 ? "item" : "items") • \(sizeStr)",
            items: items
        )
    }

    // MARK: - ID3v2.2 / v2.3 / v2.4 Parser

    private static func parseID3v2Section(data: Data, sectionIndex: Int) -> TagSection? {
        guard data.count >= 10,
              asciiString(data, range: 0..<3) == "ID3" else {
            return nil
        }

        let base = data.startIndex
        let versionMajor = Int(data[base + 3])
        let versionMinor = Int(data[base + 4])
        let flags = data[base + 5]
        guard versionMajor == 2 || versionMajor == 3 || versionMajor == 4 else {
            return nil
        }

        let declaredTagSize = synchsafeInt(data, offset: 6)
        let maxEnd = min(data.count, 10 + declaredTagSize)
        guard maxEnd > 10 else { return nil }

        let tagUnsync = (flags & 0x80) != 0
        let hasExtHeader = (flags & 0x40) != 0

        var body = Data(data[(base + 10)..<(base + maxEnd)])
        if tagUnsync && (versionMajor == 2 || versionMajor == 3) {
            body = removeUnsynchronization(body)
        }

        var pos = 0
        if hasExtHeader {
            if versionMajor == 3, pos + 4 <= body.count {
                let extSize = Int(readUInt32BE(body, offset: pos))
                if extSize >= 0, pos + 4 + extSize <= body.count {
                    pos += 4 + extSize
                }
            } else if versionMajor == 4, pos + 4 <= body.count {
                let extSize = synchsafeInt(body, offset: pos)
                if extSize >= 6, pos + extSize <= body.count {
                    pos += extSize
                }
            }
        }

        var items: [TagFieldItem] = []

        if versionMajor == 2 {
            while pos + 6 <= body.count {
                let firstByte = body[body.startIndex + pos]
                if firstByte == 0 { break }
                guard isValidFrameID(body, offset: pos, length: 3) else { break }

                let frameID = asciiString(body, range: pos..<(pos + 3))
                let frameSize = Int(readUInt24BE(body, offset: pos + 3))
                pos += 6
                guard frameSize > 0, pos + frameSize <= body.count else { break }

                let rawPayload = Data(body[(body.startIndex + pos)..<(body.startIndex + pos + frameSize)])
                pos += frameSize

                if let item = decodeID3Frame(
                    frameID: frameID,
                    payload: rawPayload,
                    versionMajor: 2,
                    index: items.count,
                    isCompressed: false,
                    isEncrypted: false
                ) {
                    items.append(item)
                }
            }
        } else {
            while pos + 10 <= body.count {
                let firstByte = body[body.startIndex + pos]
                if firstByte == 0 { break }
                guard isValidFrameID(body, offset: pos, length: 4) else { break }

                let frameID = asciiString(body, range: pos..<(pos + 4))
                let frameSize: Int
                if versionMajor == 4 {
                    frameSize = resolveID3v24FrameSize(body: body, frameOffset: pos)
                } else {
                    frameSize = Int(readUInt32BE(body, offset: pos + 4))
                }

                let flag1 = body[body.startIndex + pos + 9]
                pos += 10
                guard frameSize > 0, pos + frameSize <= body.count else { break }

                var payload = Data(body[(body.startIndex + pos)..<(body.startIndex + pos + frameSize)])
                pos += frameSize

                var isCompressed = false
                var isEncrypted = false

                if versionMajor == 4 {
                    let hasGrouping = (flag1 & 0x40) != 0
                    isCompressed = (flag1 & 0x08) != 0
                    isEncrypted = (flag1 & 0x04) != 0
                    let frameUnsync = (flag1 & 0x02) != 0
                    let hasDataLen = (flag1 & 0x01) != 0

                    if tagUnsync || frameUnsync {
                        payload = removeUnsynchronization(payload)
                    }
                    if hasGrouping && payload.count >= 1 {
                        payload = Data(payload.dropFirst(1))
                    }
                    if hasDataLen && payload.count >= 4 {
                        payload = Data(payload.dropFirst(4))
                    }
                } else {
                    isCompressed = (flag1 & 0x80) != 0
                    isEncrypted = (flag1 & 0x40) != 0
                    let hasGrouping = (flag1 & 0x20) != 0
                    if isCompressed && payload.count >= 4 {
                        payload = Data(payload.dropFirst(4))
                    }
                    if isEncrypted && payload.count >= 1 {
                        payload = Data(payload.dropFirst(1))
                    }
                    if hasGrouping && payload.count >= 1 {
                        payload = Data(payload.dropFirst(1))
                    }
                }

                if let item = decodeID3Frame(
                    frameID: frameID,
                    payload: payload,
                    versionMajor: versionMajor,
                    index: items.count,
                    isCompressed: isCompressed,
                    isEncrypted: isEncrypted
                ) {
                    items.append(item)
                }
            }
        }

        guard !items.isEmpty else { return nil }
        let totalSizeStr = ByteCountFormatter.string(fromByteCount: Int64(10 + declaredTagSize), countStyle: .file)
        return TagSection(
            id: "id3v2_\(sectionIndex)_\(versionMajor)_\(versionMinor)",
            title: "ID3v2.\(versionMajor).\(versionMinor)",
            subtitle: "\(items.count) \(items.count == 1 ? "frame" : "frames") • \(totalSizeStr)",
            items: items
        )
    }

    private static func resolveID3v24FrameSize(body: Data, frameOffset: Int) -> Int {
        let ss = synchsafeInt(body, offset: frameOffset + 4)
        let be = Int(readUInt32BE(body, offset: frameOffset + 4))
        if ss == be { return ss }

        func landsCleanly(_ size: Int) -> Bool {
            guard size > 0 else { return false }
            let nextOffset = frameOffset + 10 + size
            guard nextOffset <= body.count else { return false }
            if nextOffset == body.count { return true }
            if body[body.startIndex + nextOffset] == 0 { return true }
            return isValidFrameID(body, offset: nextOffset, length: 4)
        }

        if landsCleanly(ss) { return ss }
        if landsCleanly(be) { return be }
        return ss
    }

    private static func isValidFrameID(_ data: Data, offset: Int, length: Int) -> Bool {
        let base = data.startIndex
        guard offset + length <= data.count else { return false }
        for i in 0..<length {
            let b = data[base + offset + i]
            let isUpper = b >= 0x41 && b <= 0x5A
            let isDigit = b >= 0x30 && b <= 0x39
            if !isUpper && !isDigit {
                return false
            }
        }
        return true
    }

    private static func removeUnsynchronization(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        let bytes = Array(data)
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0x00 {
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    private static func decodeID3Frame(
        frameID: String,
        payload: Data,
        versionMajor: Int,
        index: Int,
        isCompressed: Bool,
        isEncrypted: Bool
    ) -> TagFieldItem? {
        let itemID = "id3v2_\(index)_\(frameID)"

        if isCompressed || isEncrypted {
            let kind = isEncrypted ? "Encrypted" : "Compressed"
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .file)
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: id3FrameDisplayName(frameID),
                value: "[\(kind) frame payload • \(sizeStr)]",
                detail: kind,
                isMultiline: false
            )
        }

        // User-defined text (TXXX / TXX)
        if frameID == "TXXX" || frameID == "TXX" {
            guard !payload.isEmpty else { return nil }
            let enc = payload[payload.startIndex]
            let rest = Data(payload.dropFirst())
            let split = splitID3NullTerminated(rest, encoding: enc)
            let desc = decodeID3String(split.first, encoding: enc)
            let valParts = splitID3MultiStrings(split.rest, encoding: enc)
            let val = valParts.isEmpty ? desc : valParts.joined(separator: " / ")
            let label = (desc.isEmpty || valParts.isEmpty) ? "User Text" : "User Text: \(desc)"
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: label,
                value: val.isEmpty ? "(Empty)" : val,
                detail: id3EncodingLabel(enc),
                isMultiline: val.contains("\n") || val.count > 140
            )
        }

        // Involved People / Musician Credits (v2.3 IPLS / v2.2 IPL / v2.4 TIPL & TMCL)
        if frameID == "IPLS" || frameID == "IPL" || frameID == "TIPL" || frameID == "TMCL" {
            guard !payload.isEmpty else { return nil }
            let enc = payload[payload.startIndex]
            let parts = splitID3MultiStrings(Data(payload.dropFirst()), encoding: enc)
            var pairs: [String] = []
            var idx = 0
            while idx < parts.count {
                if idx + 1 < parts.count {
                    pairs.append("\(parts[idx]): \(parts[idx + 1])")
                    idx += 2
                } else {
                    pairs.append(parts[idx])
                    idx += 1
                }
            }
            let joined = pairs.joined(separator: "; ")
            guard !joined.isEmpty else { return nil }
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: id3FrameDisplayName(frameID),
                value: joined,
                detail: id3EncodingLabel(enc),
                isMultiline: joined.count > 140
            )
        }

        // Standard Text frames (T***)
        if frameID.hasPrefix("T") {
            guard !payload.isEmpty else { return nil }
            let enc = payload[payload.startIndex]
            let rest = Data(payload.dropFirst())
            let parts = splitID3MultiStrings(rest, encoding: enc)
            var value = parts.joined(separator: " / ")
            if value.isEmpty { return nil }

            if frameID == "TCON" || frameID == "TCO" {
                value = resolveID3GenreString(value)
            } else if (frameID == "TLEN" || frameID == "TLE"), let ms = Int(value), ms > 0 {
                let totalSec = ms / 1000
                value = String(format: "%d ms (%d:%02d)", ms, totalSec / 60, totalSec % 60)
            } else if frameID == "TCMP" || frameID == "TCP" {
                if value == "1" { value = "1 (Part of a compilation)" }
                else if value == "0" { value = "0 (No)" }
            }

            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: id3FrameDisplayName(frameID),
                value: value,
                detail: id3EncodingLabel(enc),
                isMultiline: value.contains("\n") || value.count > 140
            )
        }

        // User-defined URL (WXXX / WXX)
        if frameID == "WXXX" || frameID == "WXX" {
            guard !payload.isEmpty else { return nil }
            let enc = payload[payload.startIndex]
            let rest = Data(payload.dropFirst())
            let split = splitID3NullTerminated(rest, encoding: enc)
            let desc = decodeID3String(split.first, encoding: enc)
            let urlStr = decodeID3String(split.rest, encoding: 0)
            let val = urlStr.isEmpty ? desc : urlStr
            let label = (desc.isEmpty || urlStr.isEmpty) ? "User URL" : "User URL: \(desc)"
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: label,
                value: val,
                detail: "URL",
                isMultiline: false
            )
        }

        // Standard URL frames (W***)
        if frameID.hasPrefix("W") {
            let urlStr = decodeID3String(payload, encoding: 0)
            guard !urlStr.isEmpty else { return nil }
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: id3FrameDisplayName(frameID),
                value: urlStr,
                detail: "URL",
                isMultiline: false
            )
        }

        // Comments (COMM / COM)
        if frameID == "COMM" || frameID == "COM" {
            guard payload.count >= 4 else { return nil }
            let enc = payload[payload.startIndex]
            let lang = decodeLanguageCode(payload, offset: 1)
            let afterLang = Data(payload.dropFirst(4))
            let split = splitID3NullTerminated(afterLang, encoding: enc)
            let desc = decodeID3String(split.first, encoding: enc)
            let bodyText = decodeID3String(split.rest, encoding: enc)
            let value = bodyText.isEmpty ? desc : bodyText
            guard !value.isEmpty else { return nil }

            var contextParts: [String] = []
            if !lang.isEmpty { contextParts.append(lang) }
            if !desc.isEmpty && !bodyText.isEmpty { contextParts.append(desc) }
            let label = contextParts.isEmpty ? "Comment" : "Comment (\(contextParts.joined(separator: ": ")))"

            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: label,
                value: value,
                detail: id3EncodingLabel(enc),
                isMultiline: value.contains("\n") || value.count > 140
            )
        }

        // Unsynchronized Lyrics (USLT / ULT)
        if frameID == "USLT" || frameID == "ULT" {
            guard payload.count >= 4 else { return nil }
            let enc = payload[payload.startIndex]
            let lang = decodeLanguageCode(payload, offset: 1)
            let afterLang = Data(payload.dropFirst(4))
            let split = splitID3NullTerminated(afterLang, encoding: enc)
            let desc = decodeID3String(split.first, encoding: enc)
            let lyrics = decodeID3String(split.rest, encoding: enc)
            guard !lyrics.isEmpty else { return nil }

            var contextParts: [String] = []
            if !lang.isEmpty { contextParts.append(lang) }
            if !desc.isEmpty { contextParts.append(desc) }
            let label = contextParts.isEmpty ? "Unsynchronized Lyrics" : "Lyrics (\(contextParts.joined(separator: ": ")))"

            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: label,
                value: lyrics,
                detail: "\(id3EncodingLabel(enc)) • \(lyrics.components(separatedBy: .newlines).count) lines",
                isMultiline: true
            )
        }

        // Synchronized Lyrics (SYLT / SLT)
        if frameID == "SYLT" || frameID == "SLT" {
            return decodeSYLTFrame(frameID: frameID, payload: payload, itemID: itemID)
        }

        // Attached Picture (APIC / PIC)
        if frameID == "APIC" || frameID == "PIC" {
            return decodeAPICFrame(frameID: frameID, payload: payload, versionMajor: versionMajor, itemID: itemID)
        }

        // Popularimeter (POPM / POP)
        if frameID == "POPM" || frameID == "POP" {
            let split = splitID3NullTerminated(payload, encoding: 0)
            let email = decodeID3String(split.first, encoding: 0)
            let tail = split.rest
            guard !tail.isEmpty else { return nil }
            let rating = Int(tail[tail.startIndex])
            let counterBytes = Data(tail.dropFirst())
            let playCount = decodeUnsignedBE(counterBytes)

            var parts: [String] = []
            if rating == 0 {
                parts.append("Unrated (0/255)")
            } else {
                let stars = max(1, min(5, Int((Double(rating) / 255.0 * 5.0).rounded())))
                parts.append("Rating \(rating)/255 (\(stars)★)")
            }
            if let pc = playCount, pc > 0 {
                parts.append("Play Count: \(pc)")
            }
            if !email.isEmpty {
                parts.append("Owner: \(email)")
            }

            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: "Popularimeter",
                value: parts.joined(separator: " • "),
                detail: nil,
                isMultiline: false
            )
        }

        // Unique File Identifier (UFID / UFI)
        if frameID == "UFID" || frameID == "UFI" {
            let split = splitID3NullTerminated(payload, encoding: 0)
            let owner = decodeID3String(split.first, encoding: 0)
            let idData = split.rest
            let idText = decodePrintableASCIIOrHex(idData, maxHexBytes: 32)
            let label = owner.isEmpty ? "Unique File ID" : "Unique File ID (\(owner))"
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: label,
                value: idText,
                detail: "\(idData.count) B",
                isMultiline: false
            )
        }

        // Private Frame (PRIV)
        if frameID == "PRIV" {
            let split = splitID3NullTerminated(payload, encoding: 0)
            let owner = decodeID3String(split.first, encoding: 0)
            let privData = split.rest
            let valueStr = decodePrintableASCIIOrHex(privData, maxHexBytes: 24)
            let label = owner.isEmpty ? "Private Data" : "Private (\(owner))"
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: label,
                value: valueStr,
                detail: "\(privData.count) B",
                isMultiline: false
            )
        }

        // Play Counter (PCNT / CNT)
        if frameID == "PCNT" || frameID == "CNT" {
            if let count = decodeUnsignedBE(payload) {
                return TagFieldItem(
                    id: itemID,
                    rawKey: frameID,
                    displayName: "Play Counter",
                    value: "\(count)",
                    detail: nil,
                    isMultiline: false
                )
            }
        }

        // Relative Volume Adjustment (RVA2)
        if frameID == "RVA2" {
            let split = splitID3NullTerminated(payload, encoding: 0)
            let ident = decodeID3String(split.first, encoding: 0)
            let summary = decodeRVA2Channels(split.rest)
            let label = ident.isEmpty ? "Relative Volume Adjustment" : "Volume Adj (\(ident))"
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: label,
                value: summary.isEmpty ? hexPreview(payload, maxBytes: 16) : summary,
                detail: nil,
                isMultiline: false
            )
        }

        // General Encapsulated Object (GEOB / GEO)
        if frameID == "GEOB" || frameID == "GEO" {
            guard !payload.isEmpty else { return nil }
            let enc = payload[payload.startIndex]
            let s1 = splitID3NullTerminated(Data(payload.dropFirst()), encoding: 0)
            let mime = decodeID3String(s1.first, encoding: 0)
            let s2 = splitID3NullTerminated(s1.rest, encoding: enc)
            let filename = decodeID3String(s2.first, encoding: enc)
            let s3 = splitID3NullTerminated(s2.rest, encoding: enc)
            let desc = decodeID3String(s3.first, encoding: enc)
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(s3.rest.count), countStyle: .file)
            let parts = [mime, filename, desc, sizeStr].filter { !$0.isEmpty }
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: "Encapsulated Object",
                value: parts.joined(separator: " • "),
                detail: "\(s3.rest.count) B",
                isMultiline: false
            )
        }

        // Music CD Identifier (MCDI / MCI)
        if frameID == "MCDI" || frameID == "MCI" {
            return TagFieldItem(
                id: itemID,
                rawKey: frameID,
                displayName: "CD Table of Contents",
                value: "\(payload.count) bytes • \(hexPreview(payload, maxBytes: 24))",
                detail: "Binary TOC",
                isMultiline: false
            )
        }

        // Fallback for any other valid ID3 frame
        let fallbackVal = decodePrintableASCIIOrHex(payload, maxHexBytes: 24)
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .file)
        return TagFieldItem(
            id: itemID,
            rawKey: frameID,
            displayName: id3FrameDisplayName(frameID),
            value: fallbackVal.isEmpty ? "(\(sizeStr))" : fallbackVal,
            detail: sizeStr,
            isMultiline: fallbackVal.contains("\n") || fallbackVal.count > 140
        )
    }

    private static func decodeAPICFrame(frameID: String, payload: Data, versionMajor: Int, itemID: String) -> TagFieldItem? {
        guard payload.count >= 4 else { return nil }
        let enc = payload[payload.startIndex]
        let rest = Data(payload.dropFirst())

        let mime: String
        let afterMime: Data
        if versionMajor == 2 || frameID == "PIC" {
            guard rest.count >= 3 else { return nil }
            let fmt = asciiString(rest, range: 0..<3).lowercased()
            mime = fmt == "jpg" ? "image/jpeg" : (fmt == "png" ? "image/png" : "image/\(fmt)")
            afterMime = Data(rest.dropFirst(3))
        } else {
            let splitMime = splitID3NullTerminated(rest, encoding: 0)
            let m = decodeID3String(splitMime.first, encoding: 0)
            mime = m.isEmpty ? "image/*" : m
            afterMime = splitMime.rest
        }

        guard !afterMime.isEmpty else { return nil }
        let picType = afterMime[afterMime.startIndex]
        let afterType = Data(afterMime.dropFirst())
        let splitDesc = splitID3NullTerminated(afterType, encoding: enc)
        let desc = decodeID3String(splitDesc.first, encoding: enc)
        let imageBytes = splitDesc.rest

        let typeLabel = id3PictureTypeName(picType)
        let summary = describeImageData(imageBytes, mimeOverride: mime, labelPrefix: desc.isEmpty ? nil : desc)

        return TagFieldItem(
            id: itemID,
            rawKey: frameID,
            displayName: "Picture (\(typeLabel))",
            value: summary,
            detail: typeLabel,
            isMultiline: false
        )
    }

    private static func decodeSYLTFrame(frameID: String, payload: Data, itemID: String) -> TagFieldItem? {
        guard payload.count >= 6 else { return nil }
        let enc = payload[payload.startIndex]
        let lang = decodeLanguageCode(payload, offset: 1)
        let afterHeader = Data(payload.dropFirst(6))
        let splitDesc = splitID3NullTerminated(afterHeader, encoding: enc)
        let desc = decodeID3String(splitDesc.first, encoding: enc)

        var cursor = splitDesc.rest
        var lines: [String] = []
        while !cursor.isEmpty {
            let splitText = splitID3NullTerminated(cursor, encoding: enc)
            let text = decodeID3String(splitText.first, encoding: enc)
            guard splitText.rest.count >= 4 else {
                if !text.isEmpty { lines.append(text) }
                break
            }
            let ts = readUInt32BE(splitText.rest, offset: 0)
            let mins = ts / 60000
            let secs = (ts % 60000) / 1000
            let hundredths = (ts % 1000) / 10
            let stamp = String(format: "[%02d:%02d.%02d]", mins, secs, hundredths)
            lines.append("\(stamp) \(text)")
            cursor = Data(splitText.rest.dropFirst(4))
        }

        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        var ctx: [String] = []
        if !lang.isEmpty { ctx.append(lang) }
        if !desc.isEmpty { ctx.append(desc) }
        let label = ctx.isEmpty ? "Synchronized Lyrics" : "Sync Lyrics (\(ctx.joined(separator: ": ")))"

        return TagFieldItem(
            id: itemID,
            rawKey: frameID,
            displayName: label,
            value: joined,
            detail: "\(lines.count) timed lines",
            isMultiline: true
        )
    }

    private static func decodeRVA2Channels(_ data: Data) -> String {
        let base = data.startIndex
        var pos = 0
        var parts: [String] = []
        let channelNames = [
            "Other", "Master", "Front Right", "Front Left",
            "Back Right", "Back Left", "Front Center", "Back Center", "Subwoofer"
        ]

        while pos + 4 <= data.count {
            let ch = Int(data[base + pos])
            let rawAdj = Int16(bitPattern: UInt16(data[base + pos + 1]) << 8 | UInt16(data[base + pos + 2]))
            let db = Double(rawAdj) / 512.0
            let peakBits = Int(data[base + pos + 3])
            let peakBytes = (peakBits + 7) / 8
            pos += 4 + peakBytes

            let chName = ch < channelNames.count ? channelNames[ch] : "Ch \(ch)"
            parts.append(String(format: "%@: %+.2f dB", chName, db))
        }

        return parts.joined(separator: " • ")
    }

    // MARK: - ID3v1 / ID3v1.1 Footer Parser

    private static func parseID3v1Section(data: Data) -> TagSection? {
        guard data.count == 128,
              asciiString(data, range: 0..<3) == "TAG" else {
            return nil
        }

        let base = data.startIndex
        let title = decodeID3v1Field(data[(base + 3)..<(base + 33)])
        let artist = decodeID3v1Field(data[(base + 33)..<(base + 63)])
        let album = decodeID3v1Field(data[(base + 63)..<(base + 93)])
        let year = decodeID3v1Field(data[(base + 93)..<(base + 97)])

        let isV11 = (data[base + 125] == 0 && data[base + 126] != 0)
        let commentEnd = isV11 ? (base + 125) : (base + 127)
        let comment = decodeID3v1Field(data[(base + 97)..<commentEnd])
        let trackNum: Int? = isV11 ? Int(data[base + 126]) : nil
        let genreByte = Int(data[base + 127])
        let genreName = genreByte < id3v1Genres.count ? id3v1Genres[genreByte] : nil

        var items: [TagFieldItem] = []
        if !title.isEmpty {
            items.append(TagFieldItem(id: "id3v1_title", rawKey: "Title", displayName: "Title", value: title))
        }
        if !artist.isEmpty {
            items.append(TagFieldItem(id: "id3v1_artist", rawKey: "Artist", displayName: "Artist", value: artist))
        }
        if !album.isEmpty {
            items.append(TagFieldItem(id: "id3v1_album", rawKey: "Album", displayName: "Album", value: album))
        }
        if !year.isEmpty {
            items.append(TagFieldItem(id: "id3v1_year", rawKey: "Year", displayName: "Year", value: year))
        }
        if let trk = trackNum {
            items.append(TagFieldItem(id: "id3v1_track", rawKey: "Track", displayName: "Track Number", value: "\(trk)"))
        }
        if !comment.isEmpty {
            items.append(TagFieldItem(id: "id3v1_comment", rawKey: "Comment", displayName: "Comment", value: comment))
        }
        if let g = genreName {
            items.append(TagFieldItem(id: "id3v1_genre", rawKey: "Genre", displayName: "Genre", value: "\(g) (#\(genreByte))"))
        }

        guard !items.isEmpty else { return nil }
        let versionTitle = isV11 ? "ID3v1.1" : "ID3v1"
        return TagSection(
            id: "id3v1",
            title: versionTitle,
            subtitle: "\(items.count) \(items.count == 1 ? "field" : "fields") • 128-byte footer",
            items: items
        )
    }

    private static func decodeID3v1Field(_ slice: Data.SubSequence) -> String {
        let trimmedBytes = Data(slice.prefix { $0 != 0 })
        let str = String(data: trimmedBytes, encoding: .utf8)
            ?? String(data: trimmedBytes, encoding: .isoLatin1)
            ?? ""
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AVURLAsset Full Metadata (MP4 / iTunes / QuickTime / Fallback)

    private static func readAVFoundationTags(url: URL) async -> [TagSection] {
        let asset = AVURLAsset(url: url)
        var sections: [TagSection] = []

        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        if !formats.isEmpty {
            for (fmtIdx, format) in formats.enumerated() {
                guard let metadata = try? await asset.loadMetadata(for: format), !metadata.isEmpty else {
                    continue
                }
                let items = await convertAVMetadataItems(metadata, prefix: "av_\(fmtIdx)")
                if !items.isEmpty {
                    let title = displayTitle(forMetadataFormat: format)
                    sections.append(TagSection(
                        id: "avformat_\(fmtIdx)_\(format.rawValue)",
                        title: title,
                        subtitle: "\(items.count) \(items.count == 1 ? "tag" : "tags")",
                        items: items
                    ))
                }
            }
        } else if let metadata = try? await asset.load(.metadata), !metadata.isEmpty {
            let items = await convertAVMetadataItems(metadata, prefix: "av_common")
            if !items.isEmpty {
                sections.append(TagSection(
                    id: "av_embedded",
                    title: "Embedded Metadata",
                    subtitle: "\(items.count) \(items.count == 1 ? "tag" : "tags")",
                    items: items
                ))
            }
        }

        return sections
    }

    private static func convertAVMetadataItems(_ metadata: [AVMetadataItem], prefix: String) async -> [TagFieldItem] {
        var items: [TagFieldItem] = []

        for (idx, item) in metadata.enumerated() {
            let extraAttrs = try? await item.load(.extraAttributes)
            let extraInfo = (extraAttrs?[.info] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            var rawKey = extractAVKeyString(item)
            if rawKey == "----", let info = extraInfo, !info.isEmpty {
                rawKey = "----:\(info)"
            }

            let isArtwork = item.commonKey == .commonKeyArtwork
                || rawKey.lowercased() == "covr"
                || (item.identifier?.rawValue.uppercased().contains("ARTWORK") ?? false)

            if isArtwork {
                if let artData = try? await item.load(.dataValue), !artData.isEmpty {
                    let summary = describeImageData(artData)
                    items.append(TagFieldItem(
                        id: "\(prefix)_\(idx)_\(rawKey)",
                        rawKey: rawKey,
                        displayName: "Cover Artwork",
                        value: summary,
                        detail: "Embedded Image",
                        isMultiline: false
                    ))
                }
                continue
            }

            var valueStr = ""
            var detail: String? = nil

            // Handle MP4/iTunes binary 'trkn' / 'disk' tuples (0, 0, index, total, ...)
            if (rawKey == "trkn" || rawKey == "disk"),
               let dataVal = try? await item.load(.dataValue),
               dataVal.count >= 4 {
                let base = dataVal.startIndex
                let current = (Int(dataVal[base + 2]) << 8) | Int(dataVal[base + 3])
                let total = dataVal.count >= 6 ? ((Int(dataVal[base + 4]) << 8) | Int(dataVal[base + 5])) : 0
                if current > 0 {
                    valueStr = total > 0 ? "\(current) / \(total)" : "\(current)"
                }
            }

            if valueStr.isEmpty, let str = try? await item.load(.stringValue) {
                valueStr = str.trimmingCharacters(in: CharacterSet.newlines.union(.controlCharacters))
            }
            if valueStr.isEmpty, let num = try? await item.load(.numberValue) {
                valueStr = num.stringValue
            }
            if valueStr.isEmpty, let date = try? await item.load(.dateValue) {
                valueStr = date.formatted(date: .abbreviated, time: .shortened)
            }
            if valueStr.isEmpty, let dataVal = try? await item.load(.dataValue), !dataVal.isEmpty {
                valueStr = decodePrintableASCIIOrHex(dataVal, maxHexBytes: 24)
                detail = "\(dataVal.count) B"
            }

            guard !valueStr.isEmpty else { continue }

            if rawKey == "cpil" || rawKey == "pgap" {
                if valueStr == "1" { valueStr = "1 (Yes)" }
                else if valueStr == "0" { valueStr = "0 (No)" }
            }

            let displayName = avMetadataDisplayName(rawKey: rawKey, item: item, extraInfo: extraInfo)
            items.append(TagFieldItem(
                id: "\(prefix)_\(idx)_\(rawKey)",
                rawKey: rawKey,
                displayName: displayName,
                value: valueStr,
                detail: detail,
                isMultiline: valueStr.contains("\n") || valueStr.count > 140
            ))
        }

        return items
    }

    private static func extractAVKeyString(_ item: AVMetadataItem) -> String {
        if let num = item.key as? NSNumber {
            let code = num.uint32Value
            let bytes: [UInt8] = [
                UInt8((code >> 24) & 0xFF),
                UInt8((code >> 16) & 0xFF),
                UInt8((code >> 8) & 0xFF),
                UInt8(code & 0xFF)
            ]
            if let fourCC = String(bytes: bytes, encoding: .macOSRoman), !fourCC.isEmpty {
                return fourCC
            }
        }
        if let str = item.key as? String, !str.isEmpty {
            return str
        }
        if let idStr = item.identifier?.rawValue, !idStr.isEmpty {
            if let slashIdx = idStr.lastIndex(of: "/") {
                let tail = String(idStr[idStr.index(after: slashIdx)...])
                return tail.removingPercentEncoding ?? tail
            }
            return idStr
        }
        return item.commonKey?.rawValue ?? "TAG"
    }

    private static func displayTitle(forMetadataFormat format: AVMetadataFormat) -> String {
        switch format {
        case .iTunesMetadata: return "MP4 / iTunes Metadata"
        case .quickTimeMetadata: return "QuickTime Metadata"
        case .quickTimeUserData: return "QuickTime User Data"
        case .id3Metadata: return "ID3 Metadata"
        case .isoUserData: return "ISO User Data"
        default: return format.rawValue
        }
    }

    // MARK: - Text, Image & Binary Utilities

    private static func splitID3NullTerminated(_ data: Data, encoding: UInt8) -> (first: Data, rest: Data) {
        let base = data.startIndex
        let count = data.count

        if encoding == 1 || encoding == 2 {
            var i = 0
            while i + 1 < count {
                if data[base + i] == 0 && data[base + i + 1] == 0 {
                    let first = Data(data[base..<(base + i)])
                    let restStart = base + i + 2
                    let rest = restStart < data.endIndex ? Data(data[restStart..<data.endIndex]) : Data()
                    return (first, rest)
                }
                i += 2
            }
            return (data, Data())
        } else {
            if let idx = data.firstIndex(of: 0) {
                let first = Data(data[base..<idx])
                let nextIdx = data.index(after: idx)
                let rest = nextIdx < data.endIndex ? Data(data[nextIdx..<data.endIndex]) : Data()
                return (first, rest)
            }
            return (data, Data())
        }
    }

    private static func splitID3MultiStrings(_ data: Data, encoding: UInt8) -> [String] {
        var remaining = data
        var results: [String] = []

        while !remaining.isEmpty {
            let split = splitID3NullTerminated(remaining, encoding: encoding)
            let decoded = decodeID3String(split.first, encoding: encoding)
            if !decoded.isEmpty {
                results.append(decoded)
            }
            if split.rest.count == remaining.count {
                break
            }
            remaining = split.rest
        }

        return results
    }

    private static func decodeID3String(_ data: Data, encoding: UInt8) -> String {
        guard !data.isEmpty else { return "" }
        let raw: String?
        switch encoding {
        case 0:
            raw = String(data: data, encoding: .isoLatin1)
        case 1:
            if data.count >= 2 {
                let b0 = data[data.startIndex]
                let b1 = data[data.startIndex + 1]
                if b0 == 0xFF && b1 == 0xFE {
                    raw = String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian)
                } else if b0 == 0xFE && b1 == 0xFF {
                    raw = String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian)
                } else {
                    raw = String(data: data, encoding: .utf16) ?? String(data: data, encoding: .utf16LittleEndian)
                }
            } else {
                raw = nil
            }
        case 2:
            raw = String(data: data, encoding: .utf16BigEndian)
        default:
            raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }

        return (raw ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
    }

    private static func id3EncodingLabel(_ encoding: UInt8) -> String {
        switch encoding {
        case 0: return "ISO-8859-1"
        case 1: return "UTF-16"
        case 2: return "UTF-16BE"
        case 3: return "UTF-8"
        default: return "Encoding \(encoding)"
        }
    }

    private static func decodeLanguageCode(_ data: Data, offset: Int) -> String {
        let base = data.startIndex
        guard offset + 3 <= data.count else { return "" }
        let slice = Data(data[(base + offset)..<(base + offset + 3)])
        let str = (String(data: slice, encoding: .ascii) ?? "")
            .trimmingCharacters(in: CharacterSet.controlCharacters.union(.whitespaces))
        if str.isEmpty || str.lowercased() == "xxx" { return "" }
        return str
    }

    private static func describeImageData(_ data: Data, mimeOverride: String? = nil, labelPrefix: String? = nil) -> String {
        var parts: [String] = []
        if let prefix = labelPrefix, !prefix.isEmpty {
            parts.append("\"\(prefix)\"")
        }

        var detectedMime = mimeOverride
        var dimensions: String? = nil

        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            if detectedMime == nil, let uti = CGImageSourceGetType(source) as String? {
                if uti.contains("jpeg") { detectedMime = "image/jpeg" }
                else if uti.contains("png") { detectedMime = "image/png" }
                else { detectedMime = uti }
            }
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int,
               w > 0, h > 0 {
                dimensions = "\(w)×\(h)"
            }
        }

        if let mime = detectedMime, !mime.isEmpty {
            parts.append(mime)
        }
        if let dims = dimensions {
            parts.append(dims)
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
        return parts.joined(separator: " • ")
    }

    private static func decodeBestEffortText(_ data: Data) -> String {
        let trimmed = Data(data.prefix { $0 != 0 })
        let str = String(data: trimmed, encoding: .utf8)
            ?? String(data: trimmed, encoding: .isoLatin1)
            ?? ""
        return str.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
    }

    private static func decodePrintableASCIIOrHex(_ data: Data, maxHexBytes: Int) -> String {
        guard !data.isEmpty else { return "" }
        let trimmed = Data(data.prefix { $0 != 0 })
        if !trimmed.isEmpty,
           let str = String(data: trimmed, encoding: .utf8) ?? String(data: trimmed, encoding: .isoLatin1) {
            let scalars = str.unicodeScalars
            let printable = scalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }.count
            if !scalars.isEmpty && Double(printable) / Double(scalars.count) >= 0.85 {
                let cleaned = str.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return hexPreview(data, maxBytes: maxHexBytes)
    }

    private static func hexPreview(_ data: Data, maxBytes: Int) -> String {
        let prefix = data.prefix(maxBytes)
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > maxBytes ? "\(hex) …" : hex
    }

    private static func decodeUnsignedBE(_ data: Data) -> UInt64? {
        guard !data.isEmpty, data.count <= 8 else { return nil }
        var val: UInt64 = 0
        for byte in data {
            val = (val << 8) | UInt64(byte)
        }
        return val
    }

    private static func fileByteSize(handle: FileHandle) -> UInt64 {
        (try? handle.seekToEnd()) ?? 0
    }

    private static func readBytes(handle: FileHandle, offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return nil }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    private static func asciiString(_ data: Data, range: Range<Int>) -> String {
        let base = data.startIndex
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return "" }
        return String(data: data[(base + range.lowerBound)..<(base + range.upperBound)], encoding: .ascii) ?? ""
    }

    private static func synchsafeInt(_ data: Data, offset: Int) -> Int {
        let b = data.startIndex + offset
        guard b + 4 <= data.endIndex else { return 0 }
        return (Int(data[b] & 0x7F) << 21)
            | (Int(data[b + 1] & 0x7F) << 14)
            | (Int(data[b + 2] & 0x7F) << 7)
            | Int(data[b + 3] & 0x7F)
    }

    private static func readUInt24BE(_ data: Data, offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        guard b + 3 <= data.endIndex else { return 0 }
        return (UInt32(data[b]) << 16) | (UInt32(data[b + 1]) << 8) | UInt32(data[b + 2])
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        guard b + 4 <= data.endIndex else { return 0 }
        return (UInt32(data[b]) << 24)
            | (UInt32(data[b + 1]) << 16)
            | (UInt32(data[b + 2]) << 8)
            | UInt32(data[b + 3])
    }

    private static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
        let b = data.startIndex + offset
        guard b + 8 <= data.endIndex else { return 0 }
        var val: UInt64 = 0
        for i in 0..<8 {
            val = (val << 8) | UInt64(data[b + i])
        }
        return val
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        guard b + 4 <= data.endIndex else { return 0 }
        return UInt32(data[b])
            | (UInt32(data[b + 1]) << 8)
            | (UInt32(data[b + 2]) << 16)
            | (UInt32(data[b + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, offset: Int) -> UInt64 {
        let b = data.startIndex + offset
        guard b + 8 <= data.endIndex else { return 0 }
        var val: UInt64 = 0
        for i in 0..<8 {
            val |= UInt64(data[b + i]) << (8 * i)
        }
        return val
    }

    // MARK: - Human-Readable Name & Genre Lookup Tables

    private static func resolveID3GenreString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pure numeric genre like "17"
        if let num = Int(trimmed), num >= 0, num < id3v1Genres.count {
            return id3v1Genres[num]
        }

        // Handle "(17)", "(17)Rock", "(RX)", "(CR)"
        var result = ""
        var i = trimmed.startIndex
        while i < trimmed.endIndex {
            if trimmed[i] == "(" {
                let next = trimmed.index(after: i)
                if next < trimmed.endIndex && trimmed[next] == "(" {
                    result.append("(")
                    i = trimmed.index(after: next)
                    continue
                }
                if let close = trimmed[next...].firstIndex(of: ")") {
                    let token = String(trimmed[next..<close])
                    if token == "RX" {
                        result += (result.isEmpty ? "" : " / ") + "Remix"
                    } else if token == "CR" {
                        result += (result.isEmpty ? "" : " / ") + "Cover"
                    } else if let idx = Int(token), idx >= 0, idx < id3v1Genres.count {
                        let resolved = id3v1Genres[idx]
                        if !result.contains(resolved) {
                            result += (result.isEmpty ? "" : " / ") + resolved
                        }
                    } else {
                        result += "(\(token))"
                    }
                    i = trimmed.index(after: close)
                    continue
                }
            }
            let remaining = String(trimmed[i...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty && !result.localizedCaseInsensitiveContains(remaining) {
                result += (result.isEmpty ? "" : " / ") + remaining
            }
            break
        }

        return result.isEmpty ? trimmed : result
    }

    private static func id3PictureTypeName(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "Other"
        case 0x01: return "32×32 File Icon"
        case 0x02: return "Other File Icon"
        case 0x03: return "Front Cover"
        case 0x04: return "Back Cover"
        case 0x05: return "Leaflet Page"
        case 0x06: return "Media"
        case 0x07: return "Lead Artist"
        case 0x08: return "Artist / Performer"
        case 0x09: return "Conductor"
        case 0x0A: return "Band / Orchestra"
        case 0x0B: return "Composer"
        case 0x0C: return "Lyricist"
        case 0x0D: return "Recording Location"
        case 0x0E: return "During Recording"
        case 0x0F: return "During Performance"
        case 0x10: return "Video Screen Capture"
        case 0x11: return "Bright Coloured Fish"
        case 0x12: return "Illustration"
        case 0x13: return "Band Logotype"
        case 0x14: return "Publisher Logotype"
        default: return "Type 0x\(String(format: "%02X", code))"
        }
    }

    private static func id3FrameDisplayName(_ frameID: String) -> String {
        switch frameID {
        // ID3v2.3 / ID3v2.4
        case "TIT1": return "Content Group / Work"
        case "TIT2": return "Title"
        case "TIT3": return "Subtitle / Description"
        case "TPE1": return "Lead Artist"
        case "TPE2": return "Album Artist / Band"
        case "TPE3": return "Conductor"
        case "TPE4": return "Remixer / Modified By"
        case "TALB": return "Album"
        case "TCOM": return "Composer"
        case "TCON": return "Genre"
        case "TRCK": return "Track Number"
        case "TPOS": return "Disc / Part of Set"
        case "TYER": return "Year"
        case "TDAT": return "Date"
        case "TIME": return "Time"
        case "TDRC": return "Recording Time"
        case "TDOR": return "Original Release Time"
        case "TDRL": return "Release Time"
        case "TDTG": return "Tagging Time"
        case "TDEN": return "Encoding Time"
        case "TORY": return "Original Release Year"
        case "TRDA": return "Recording Dates"
        case "TPUB": return "Publisher / Label"
        case "TCOP": return "Copyright"
        case "TPRO": return "Produced Notice"
        case "TBPM": return "BPM"
        case "TKEY": return "Initial Key"
        case "TSRC": return "ISRC"
        case "TLAN": return "Language"
        case "TLEN": return "Length"
        case "TENC": return "Encoded By"
        case "TSSE": return "Encoder Settings"
        case "TOAL": return "Original Album"
        case "TOPE": return "Original Artist"
        case "TOLY": return "Original Lyricist"
        case "TOFN": return "Original Filename"
        case "TEXT": return "Lyricist / Text Writer"
        case "TMED": return "Media Type"
        case "TCMP": return "Compilation"
        case "TSOA": return "Album Sort Order"
        case "TSOP": return "Performer Sort Order"
        case "TSOT": return "Title Sort Order"
        case "TSO2": return "Album Artist Sort Order"
        case "TSOC": return "Composer Sort Order"
        case "TSST": return "Set Subtitle"
        case "TMOO": return "Mood"
        case "TIPL": return "Involved People"
        case "TMCL": return "Musician Credits"
        case "IPLS": return "Involved People"
        case "TDLY": return "Playlist Delay"
        case "TFLT": return "File Type"
        case "TOWN": return "File Owner / Licensee"
        case "TRSN": return "Internet Radio Station"
        case "TRSO": return "Internet Radio Owner"
        case "TXXX": return "User Defined Text"
        case "GRP1": return "Grouping"
        case "MVNM": return "Movement Name"
        case "MVIN": return "Movement Number"
        case "PCST": return "Podcast"
        case "TCAT": return "Podcast Category"
        case "TDES": return "Podcast Description"
        case "TGID": return "Podcast ID"
        case "TKWD": return "Podcast Keywords"
        case "WFED": return "Podcast Feed URL"
        case "COMM": return "Comment"
        case "USLT": return "Unsynchronized Lyrics"
        case "SYLT": return "Synchronized Lyrics"
        case "APIC": return "Attached Picture"
        case "UFID": return "Unique File Identifier"
        case "PRIV": return "Private Frame"
        case "POPM": return "Popularimeter"
        case "PCNT": return "Play Counter"
        case "RVA2": return "Relative Volume Adjustment"
        case "RVAD": return "Relative Volume Adjustment"
        case "GEOB": return "General Encapsulated Object"
        case "MCDI": return "Music CD Identifier"
        case "WOAR": return "Official Artist URL"
        case "WOAF": return "Official Audio File URL"
        case "WOAS": return "Official Audio Source URL"
        case "WCOM": return "Commercial Info URL"
        case "WCOP": return "Copyright Info URL"
        case "WPUB": return "Publisher URL"
        case "WORS": return "Internet Radio Station URL"
        case "WPAY": return "Payment URL"
        case "WXXX": return "User Defined URL"
        // ID3v2.2 3-character frames
        case "TT1": return "Content Group / Work"
        case "TT2": return "Title"
        case "TT3": return "Subtitle / Description"
        case "TP1": return "Lead Artist"
        case "TP2": return "Album Artist / Band"
        case "TP3": return "Conductor"
        case "TP4": return "Remixer / Modified By"
        case "TAL": return "Album"
        case "TCM": return "Composer"
        case "TCO": return "Genre"
        case "TRK": return "Track Number"
        case "TPA": return "Disc / Part of Set"
        case "TYE": return "Year"
        case "TDA": return "Date"
        case "TIM": return "Time"
        case "TOR": return "Original Release Year"
        case "TRD": return "Recording Dates"
        case "TPB": return "Publisher / Label"
        case "TCR": return "Copyright"
        case "TBP": return "BPM"
        case "TKE": return "Initial Key"
        case "TRC": return "ISRC"
        case "TLA": return "Language"
        case "TLE": return "Length"
        case "TEN": return "Encoded By"
        case "TSS": return "Encoder Settings"
        case "TOT": return "Original Album"
        case "TOA": return "Original Artist"
        case "TOL": return "Original Lyricist"
        case "TOF": return "Original Filename"
        case "TXT": return "Lyricist"
        case "TMT": return "Media Type"
        case "TCP": return "Compilation"
        case "TSA": return "Album Sort Order"
        case "TSP": return "Performer Sort Order"
        case "TST": return "Title Sort Order"
        case "TS2": return "Album Artist Sort Order"
        case "TSC": return "Composer Sort Order"
        case "IPL": return "Involved People"
        case "TXX": return "User Defined Text"
        case "COM": return "Comment"
        case "ULT": return "Unsynchronized Lyrics"
        case "SLT": return "Synchronized Lyrics"
        case "PIC": return "Attached Picture"
        case "UFI": return "Unique File Identifier"
        case "POP": return "Popularimeter"
        case "CNT": return "Play Counter"
        case "GEO": return "General Encapsulated Object"
        case "MCI": return "Music CD Identifier"
        case "WAR": return "Official Artist URL"
        case "WAF": return "Official Audio File URL"
        case "WAS": return "Official Audio Source URL"
        case "WCM": return "Commercial Info URL"
        case "WCP": return "Copyright Info URL"
        case "WPB": return "Publisher URL"
        case "WXX": return "User Defined URL"
        default: return "Frame \(frameID)"
        }
    }

    private static func vorbisFieldDisplayName(_ key: String) -> String {
        switch key.uppercased() {
        case "TITLE": return "Title"
        case "ARTIST": return "Artist"
        case "ALBUM": return "Album"
        case "ALBUMARTIST", "ALBUM ARTIST": return "Album Artist"
        case "GENRE": return "Genre"
        case "DATE", "YEAR": return "Date / Year"
        case "ORIGINALDATE", "ORIGINALYEAR": return "Original Date"
        case "TRACKNUMBER", "TRACK": return "Track Number"
        case "TRACKTOTAL", "TOTALTRACKS": return "Total Tracks"
        case "DISCNUMBER", "DISC": return "Disc Number"
        case "DISCTOTAL", "TOTALDISCS": return "Total Discs"
        case "COMPOSER": return "Composer"
        case "CONDUCTOR": return "Conductor"
        case "PERFORMER": return "Performer"
        case "COMMENT", "DESCRIPTION": return "Comment"
        case "LYRICS", "UNSYNCEDLYRICS": return "Lyrics"
        case "LABEL", "ORGANIZATION", "PUBLISHER": return "Publisher / Label"
        case "COPYRIGHT": return "Copyright"
        case "ISRC": return "ISRC"
        case "BARCODE", "UPC", "EAN": return "Barcode"
        case "CATALOGNUMBER": return "Catalog Number"
        case "MEDIA": return "Media"
        case "BPM": return "BPM"
        case "COMPILATION": return "Compilation"
        case "ENCODER": return "Encoder"
        case "REPLAYGAIN_TRACK_GAIN": return "ReplayGain Track Gain"
        case "REPLAYGAIN_TRACK_PEAK": return "ReplayGain Track Peak"
        case "REPLAYGAIN_ALBUM_GAIN": return "ReplayGain Album Gain"
        case "REPLAYGAIN_ALBUM_PEAK": return "ReplayGain Album Peak"
        case "ACCURATERIPCRC": return "AccurateRip CRC"
        case "ACCURATERIPRESULT": return "AccurateRip Result"
        case "RIPPER": return "Ripper"
        case "MUSICBRAINZ_TRACKID": return "MusicBrainz Recording ID"
        case "MUSICBRAINZ_ALBUMID": return "MusicBrainz Release ID"
        case "MUSICBRAINZ_ARTISTID": return "MusicBrainz Artist ID"
        case "MUSICBRAINZ_ALBUMARTISTID": return "MusicBrainz Album Artist ID"
        case "MUSICBRAINZ_RELEASEGROUPID": return "MusicBrainz Release Group ID"
        case "ACOUSTID_ID": return "AcoustID"
        default:
            return key
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private static func riffInfoDisplayName(_ id: String) -> String {
        switch id {
        case "INAM": return "Title"
        case "IART": return "Artist"
        case "IPRD": return "Album / Product"
        case "ICRD": return "Creation Date"
        case "IGNR": return "Genre"
        case "ICMT": return "Comment"
        case "ITRK": return "Track Number"
        case "ICOP": return "Copyright"
        case "ISFT": return "Software / Encoder"
        case "IENG": return "Engineer"
        case "ITCH": return "Technician"
        case "ISRC": return "Source"
        case "ISBJ": return "Subject"
        case "IMED": return "Medium"
        case "ICMS": return "Commissioned"
        case "IKEY": return "Keywords"
        default: return "RIFF \(id)"
        }
    }

    private static func avMetadataDisplayName(rawKey: String, item: AVMetadataItem, extraInfo: String?) -> String {
        switch rawKey {
        case "©nam": return "Title"
        case "©ART": return "Artist"
        case "©alb": return "Album"
        case "aART": return "Album Artist"
        case "©gen", "gnre": return "Genre"
        case "©day": return "Release Date"
        case "trkn": return "Track Number"
        case "disk": return "Disc Number"
        case "©wrt": return "Composer"
        case "©cmt": return "Comment"
        case "©lyr": return "Lyrics"
        case "tmpo": return "BPM / Tempo"
        case "cpil": return "Compilation"
        case "pgap": return "Gapless Playback"
        case "rtng": return "Content Rating"
        case "cprt": return "Copyright"
        case "©too": return "Encoding Tool"
        case "soal": return "Album Sort"
        case "soaa": return "Album Artist Sort"
        case "soar": return "Artist Sort"
        case "soco": return "Composer Sort"
        case "sonm": return "Title Sort"
        case "covr": return "Cover Artwork"
        case "©grp": return "Grouping"
        case "catg": return "Category"
        case "desc": return "Description"
        case "ldes": return "Long Description"
        case "purd": return "Purchase Date"
        case "apID": return "Apple Account ID"
        case "cnID": return "Apple Catalog ID"
        case "atID": return "Apple Artist ID"
        case "plID": return "Apple Album ID"
        case "geID": return "Apple Genre ID"
        case "sfID": return "Storefront ID"
        case "akID": return "Account Type"
        default:
            if rawKey.hasPrefix("----:"), let info = extraInfo, !info.isEmpty {
                let short = info.components(separatedBy: ":").last ?? info
                return vorbisFieldDisplayName(short)
            }
            if id3FrameDisplayName(rawKey) != "Frame \(rawKey)" {
                return id3FrameDisplayName(rawKey)
            }
            if let ck = item.commonKey?.rawValue, !ck.isEmpty {
                return ck.capitalized
            }
            return rawKey
        }
    }

    // Standard 192 ID3v1 / Winamp genre list
    private static let id3v1Genres: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap",
        "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance",
        "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
        "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native US", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi",
        "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival",
        "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock",
        "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera",
        "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam",
        "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A capella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass",
        "Club-House", "Hardcore Techno", "Terror", "Indie", "BritPop", "Negerpunk", "Polsk Punk", "Beat",
        "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover", "Contemporary Christian", "Christian Rock", "Merengue", "Salsa",
        "Thrash Metal", "Anime", "Jpop", "Synthpop", "Abstract", "Art Rock", "Baroque", "Bhangra",
        "Big Beat", "Breakbeat", "Chillout", "Downtempo", "Dub", "EBM", "Eclectic", "Electro",
        "Electroclash", "Emo", "Experimental", "Garage", "Global", "IDM", "Illbient", "Industro-Goth",
        "Jam Band", "Krautrock", "Leftfield", "Lounge", "Math Rock", "New Romantic", "Nu-Breakz", "Post-Punk",
        "Post-Rock", "Psytrance", "Shoegaze", "Space Rock", "Trop Rock", "World Music", "Neoclassical", "Audiobook",
        "Audio Theatre", "Neue Deutsche Welle", "Podcast", "Indie Rock", "G-Funk", "Dubstep", "Garage Rock", "Psybient"
    ]
}
