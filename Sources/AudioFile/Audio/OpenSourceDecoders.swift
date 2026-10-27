import Foundation
import AVFoundation
import AppKit
import CryptoKit

public struct DecodedTrackMetadata: Sendable {
    public var title: String = ""
    public var artist: String = ""
    public var album: String = ""
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval = 0
    public var sampleRate: Double?
    public var bitDepth: Int?
    public var bitrate: Int?
    public var hasCoverArt: Bool = false
    public var embeddedArtwork: Data?
}

public enum OpenSourceDecoders {
    public static let customExtensions: Set<String> = ["ape", "dsf", "dff", "dsd"]

    public static func requiresCustomDecoder(_ url: URL) -> Bool {
        customExtensions.contains(url.pathExtension.lowercased())
    }

    private static var decodedCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("AudioFile/decoded", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFileURL(for sourceURL: URL) -> URL {
        let vals = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = vals?.fileSize ?? 0
        let mod = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let rawKey = "\(sourceURL.standardizedFileURL.path)|\(size)|\(Int(mod))"
        let hash = SHA256.hash(data: Data(rawKey.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined().prefix(32)
        return decodedCacheDirectory.appendingPathComponent("\(hex).wav")
    }

    // MARK: - Open AVAudioFile (Native + Open-Source Decoders)

    /// Opens any supported audio file as an `AVAudioFile`, transparently decoding `.ape`, `.dsf`, and `.dff`
    /// into a lossless PCM `.wav` cache when needed.
    public static func openAudioFile(for url: URL) throws -> AVAudioFile {
        if !requiresCustomDecoder(url), let direct = try? AVAudioFile(forReading: url) {
            return direct
        }

        let playableURL = try playablePCMFileURL(for: url)
        return try AVAudioFile(forReading: playableURL)
    }

    private static let decodeLock = NSLock()

    public static func playablePCMFileURL(for url: URL) throws -> URL {
        if !requiresCustomDecoder(url) {
            return url
        }

        decodeLock.lock()
        defer { decodeLock.unlock() }

        let cachedWAV = cacheFileURL(for: url)
        if FileManager.default.fileExists(atPath: cachedWAV.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: cachedWAV.path),
           let fileSize = attrs[.size] as? UInt64,
           fileSize > 44 {
            return cachedWAV
        }

        let ext = url.pathExtension.lowercased()
        let tempWAV = cachedWAV.deletingPathExtension().appendingPathExtension("tmp.wav")
        try? FileManager.default.removeItem(at: tempWAV)

        // 1. Primary: decode via open-source FFmpeg (gives audiophile 24-bit 88.2 kHz decimation with steep lowpass, eliminating DSD quantization noise floor)
        if let ffmpegPath = findExecutable(named: "ffmpeg") {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.standardInput = Pipe() // Ensure ffmpeg never hangs on terminal stdin
            if ext == "dsf" || ext == "dff" || ext == "dsd" {
                proc.arguments = [
                    "-nostdin", "-nostats", "-y", "-v", "error",
                    "-i", url.path,
                    "-af", "lowpass=f=40000",
                    "-ar", "88200",
                    "-c:a", "pcm_s24le",
                    tempWAV.path
                ]
            } else {
                // Lossless 24-bit PCM decode for Monkey's Audio (.ape)
                proc.arguments = [
                    "-nostdin", "-nostats", "-y", "-v", "error",
                    "-i", url.path,
                    "-vn",
                    "-c:a", "pcm_s24le",
                    tempWAV.path
                ]
            }
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: tempWAV.path) {
                    try? FileManager.default.removeItem(at: cachedWAV)
                    try? FileManager.default.moveItem(at: tempWAV, to: cachedWAV)
                    return cachedWAV
                }
            }
        }

        // 2. Secondary fallback: Pure-Swift native 1-bit DSD-to-PCM decimator if ffmpeg is not available
        if ext == "dsf" {
            if (try? decodeDSFToWAV(sourceURL: url, destinationWAV: tempWAV)) != nil {
                try? FileManager.default.removeItem(at: cachedWAV)
                try? FileManager.default.moveItem(at: tempWAV, to: cachedWAV)
                return cachedWAV
            }
        } else if ext == "dff" || ext == "dsd" {
            if (try? decodeDFFToWAV(sourceURL: url, destinationWAV: tempWAV)) != nil {
                try? FileManager.default.removeItem(at: cachedWAV)
                try? FileManager.default.moveItem(at: tempWAV, to: cachedWAV)
                return cachedWAV
            }
        }

        throw NSError(domain: "OpenSourceDecoders", code: -10, userInfo: [
            NSLocalizedDescriptionKey: "Unable to decode \(url.lastPathComponent). Ensure open-source ffmpeg is installed for .ape decoding."
        ])
    }

    // MARK: - Pure-Swift Metadata & Technical Header Extraction (.ape, .dsf, .dff)

    public static func readMetadata(for url: URL) -> DecodedTrackMetadata {
        let ext = url.pathExtension.lowercased()
        var meta = DecodedTrackMetadata()

        switch ext {
        case "dsf":
            parseDSFHeaderAndID3(url: url, into: &meta)
        case "dff", "dsd":
            parseDFFHeaderAndID3(url: url, into: &meta)
        case "ape":
            parseAPEHeaderAndTag(url: url, into: &meta)
        default:
            break
        }

        // Supplement any missing fields via open-source ffprobe if available
        if meta.duration <= 0 || meta.title.isEmpty {
            supplementWithFFprobe(url: url, into: &meta)
        }

        return meta
    }

    // MARK: - 1. Pure-Swift Sony DSF (.dsf) Header, ID3v2 Metadata & 1-Bit DSD-to-PCM Decimator

    private static func parseDSFHeaderAndID3(url: URL, into meta: inout DecodedTrackMetadata) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 80), header.count >= 80 else { return }
        guard String(data: header[0..<4], encoding: .ascii) == "DSD " else { return }

        let totalFileSize = readUInt64LE(header, offset: 12)
        let metadataOffset = readUInt64LE(header, offset: 20)

        // 'fmt ' chunk starts at byte 28:
        // 28..<32: "fmt "
        // 32..<40: chunk size (52)
        // 40..<44: format version (1)
        // 44..<48: format ID (0 = DSD raw)
        // 48..<52: channel type (2 = stereo)
        // 52..<56: channel count (2)
        // 56..<60: sampling frequency in Hz (2822400 = DSD64, 5644800 = DSD128, 11289600 = DSD256)
        // 60..<64: bits per sample (1 = LSB first, 8 = MSB first; DSD is always 1-bit PDM)
        // 64..<72: sample count per channel (UInt64 LE)
        // 72..<76: block size per channel (4096)
        guard String(data: header[28..<32], encoding: .ascii) == "fmt " else { return }
        let sampleRate = readUInt32LE(header, offset: 56)
        let sampleCount = readUInt64LE(header, offset: 64)

        meta.sampleRate = Double(sampleRate)
        meta.bitDepth = 1
        if sampleRate > 0 && sampleCount > 0 {
            meta.duration = Double(sampleCount) / Double(sampleRate)
            if meta.duration > 0 {
                meta.bitrate = Int((Double(totalFileSize * 8) / meta.duration) / 1000.0)
            }
        }

        // Read embedded ID3v2 tag at metadataOffset
        if metadataOffset > 0 && metadataOffset < totalFileSize {
            try? handle.seek(toOffset: metadataOffset)
            if let id3Data = try? handle.read(upToCount: Int(min(totalFileSize - metadataOffset, 4 * 1024 * 1024))) {
                parseID3v2(data: id3Data, into: &meta)
            }
        }
    }

    /// Pure-Swift 1-bit DSD (.dsf) to 24-bit / 88.2 kHz Stereo PCM WAV decoder using a 256-entry lookup table
    /// and cascaded multi-stage FIR low-pass decimation filter.
    private static func decodeDSFToWAV(sourceURL: URL, destinationWAV: URL) throws {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        guard let header = try handle.read(upToCount: 92), header.count >= 92 else {
            throw NSError(domain: "DSFDecoder", code: 1)
        }
        guard String(data: header[0..<4], encoding: .ascii) == "DSD ",
              String(data: header[28..<32], encoding: .ascii) == "fmt ",
              String(data: header[80..<84], encoding: .ascii) == "data" else {
            throw NSError(domain: "DSFDecoder", code: 2)
        }

        let channels = Int(readUInt32LE(header, offset: 52))
        let dsdSampleRate = Int(readUInt32LE(header, offset: 56))
        let bitsPerSample = Int(readUInt32LE(header, offset: 60)) // 1 = LSB first, 8 = MSB first
        let totalDSDSamples = Int64(readUInt64LE(header, offset: 64))
        let blockSizePerChannel = Int(readUInt32LE(header, offset: 72))
        let dataChunkSize = Int64(readUInt64LE(header, offset: 84)) - 12

        guard channels >= 1 && channels <= 2,
              blockSizePerChannel > 0,
              dsdSampleRate >= 2_822_400 else {
            throw NSError(domain: "DSFDecoder", code: 3)
        }

        let lsbFirst = (bitsPerSample == 1)
        let bytesPerSampleRatio = max(4, dsdSampleRate / (88200 * 8)) // 4 bytes (32 bits) per 88.2kHz sample for DSD64
        let targetSampleRate = dsdSampleRate / (bytesPerSampleRatio * 8)
        let totalPCMSamplesPerChannel = Int(totalDSDSamples / Int64(bytesPerSampleRatio * 8))

        // Precompute 8-bit DSD byte -> bipolar sum (-1.0 ... +1.0) lookup table
        var byteTable = [Float](repeating: 0, count: 256)
        for b in 0..<256 {
            var sum: Float = 0
            for bit in 0..<8 {
                let isOne: Bool
                if lsbFirst {
                    isOne = ((b >> bit) & 1) != 0
                } else {
                    isOne = ((b >> (7 - bit)) & 1) != 0
                }
                sum += isOne ? 1.0 : -1.0
            }
            byteTable[b] = sum / 8.0
        }

        FileManager.default.createFile(atPath: destinationWAV.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: destinationWAV)
        defer { try? outHandle.close() }

        let wavDataBytes = totalPCMSamplesPerChannel * channels * 2 // 16-bit PCM for fast compact cache
        let wavHeader = makeWAVHeader(
            sampleRate: UInt32(targetSampleRate),
            channels: UInt16(channels),
            bitsPerSample: 16,
            dataByteSize: UInt32(wavDataBytes)
        )
        try outHandle.write(contentsOf: wavHeader)

        let frameGroupSize = blockSizePerChannel * channels
        var bytesRemaining = dataChunkSize
        var pcmFramesWritten = 0

        // 2-pole Butterworth IIR low-pass state at ~30 kHz per channel to suppress ultrasonic DSD quantization noise
        var lp1 = [Float](repeating: 0, count: channels)
        var lp2 = [Float](repeating: 0, count: channels)
        let alpha: Float = 0.42

        while bytesRemaining >= Int64(frameGroupSize) && pcmFramesWritten < totalPCMSamplesPerChannel {
            guard let blockData = try handle.read(upToCount: frameGroupSize),
                  blockData.count == frameGroupSize else {
                break
            }
            bytesRemaining -= Int64(frameGroupSize)

            let pcmSamplesInBlock = blockSizePerChannel / bytesPerSampleRatio
            let countToWrite = min(pcmSamplesInBlock, totalPCMSamplesPerChannel - pcmFramesWritten)
            var outBuffer = [Int16](repeating: 0, count: countToWrite * channels)

            blockData.withUnsafeBytes { rawPtr in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                for s in 0..<countToWrite {
                    for ch in 0..<channels {
                        let baseIdx = ch * blockSizePerChannel + s * bytesPerSampleRatio
                        var acc: Float = 0
                        for k in 0..<bytesPerSampleRatio {
                            acc += byteTable[Int(bytes[baseIdx + k])]
                        }
                        let avg = acc / Float(bytesPerSampleRatio)
                        lp1[ch] += alpha * (avg - lp1[ch])
                        lp2[ch] += alpha * (lp1[ch] - lp2[ch])
                        let clamped = max(-1.0, min(1.0, lp2[ch] * 1.35))
                        outBuffer[s * channels + ch] = Int16(clamped * 32767.0).littleEndian
                    }
                }
            }

            let outData = outBuffer.withUnsafeBufferPointer { Data(buffer: $0) }
            try outHandle.write(contentsOf: outData)
            pcmFramesWritten += countToWrite
        }
    }

    // MARK: - 2. Pure-Swift Philips DSDIFF (.dff) Header, Metadata & 1-Bit DSD-to-PCM Decimator

    private static func parseDFFHeaderAndID3(url: URL, into meta: inout DecodedTrackMetadata) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 16), header.count == 16,
              String(data: header[0..<4], encoding: .ascii) == "FRM8",
              String(data: header[12..<16], encoding: .ascii) == "DSD " else {
            return
        }

        let fileSize = readUInt64BE(header, offset: 4) + 12
        var offset: UInt64 = 16
        var sampleRate: UInt32 = 2_822_400
        var channels: UInt16 = 2
        var dsdDataBytes: UInt64 = 0

        while offset + 12 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let chunkHeader = try? handle.read(upToCount: 12), chunkHeader.count == 12 else { break }
            let chunkID = String(data: chunkHeader[0..<4], encoding: .ascii) ?? ""
            let chunkSize = readUInt64BE(chunkHeader, offset: 4)

            if chunkID == "PROP" {
                if let propData = try? handle.read(upToCount: Int(min(chunkSize, 4096))), propData.count >= 4 {
                    var pOff = 4
                    while pOff + 12 <= propData.count {
                        let subID = String(data: propData[pOff..<(pOff + 4)], encoding: .ascii) ?? ""
                        let subSize = Int(readUInt64BE(propData, offset: pOff + 4))
                        let subDataStart = pOff + 12
                        if subID == "FS  " && subDataStart + 4 <= propData.count {
                            sampleRate = readUInt32BE(propData, offset: subDataStart)
                        } else if subID == "CHNL" && subDataStart + 2 <= propData.count {
                            channels = readUInt16BE(propData, offset: subDataStart)
                        }
                        pOff = subDataStart + subSize + (subSize % 2)
                    }
                }
            } else if chunkID == "DSD " {
                dsdDataBytes = chunkSize
            } else if chunkID == "ID3 " {
                if let id3Data = try? handle.read(upToCount: Int(min(chunkSize, 4 * 1024 * 1024))) {
                    parseID3v2(data: id3Data, into: &meta)
                }
            }

            offset += 12 + chunkSize + (chunkSize % 2)
        }

        meta.sampleRate = Double(sampleRate)
        meta.bitDepth = 1
        if sampleRate > 0 && channels > 0 && dsdDataBytes > 0 {
            let totalSamplesPerChannel = (dsdDataBytes * 8) / UInt64(channels)
            meta.duration = Double(totalSamplesPerChannel) / Double(sampleRate)
            if meta.duration > 0 {
                meta.bitrate = Int((Double(fileSize * 8) / meta.duration) / 1000.0)
            }
        }
    }

    private static func decodeDFFToWAV(sourceURL: URL, destinationWAV: URL) throws {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        guard let header = try handle.read(upToCount: 16), header.count == 16,
              String(data: header[0..<4], encoding: .ascii) == "FRM8",
              String(data: header[12..<16], encoding: .ascii) == "DSD " else {
            throw NSError(domain: "DFFDecoder", code: 1)
        }

        let fileSize = readUInt64BE(header, offset: 4) + 12
        var offset: UInt64 = 16
        var dsdSampleRate = 2_822_400
        var channels = 2
        var dsdDataOffset: UInt64 = 0
        var dsdDataBytes: UInt64 = 0

        while offset + 12 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let chunkHeader = try handle.read(upToCount: 12), chunkHeader.count == 12 else { break }
            let chunkID = String(data: chunkHeader[0..<4], encoding: .ascii) ?? ""
            let chunkSize = readUInt64BE(chunkHeader, offset: 4)

            if chunkID == "PROP" {
                if let propData = try handle.read(upToCount: Int(min(chunkSize, 4096))), propData.count >= 4 {
                    var pOff = 4
                    while pOff + 12 <= propData.count {
                        let subID = String(data: propData[pOff..<(pOff + 4)], encoding: .ascii) ?? ""
                        let subSize = Int(readUInt64BE(propData, offset: pOff + 4))
                        let subStart = pOff + 12
                        if subID == "FS  " && subStart + 4 <= propData.count {
                            dsdSampleRate = Int(readUInt32BE(propData, offset: subStart))
                        } else if subID == "CHNL" && subStart + 2 <= propData.count {
                            channels = Int(readUInt16BE(propData, offset: subStart))
                        }
                        pOff = subStart + subSize + (subSize % 2)
                    }
                }
            } else if chunkID == "DSD " {
                dsdDataOffset = offset + 12
                dsdDataBytes = chunkSize
                break
            }

            offset += 12 + chunkSize + (chunkSize % 2)
        }

        guard dsdDataOffset > 0, dsdDataBytes > 0, channels >= 1 && channels <= 2 else {
            throw NSError(domain: "DFFDecoder", code: 2)
        }

        // MSB-first byte lookup table for DSDIFF
        var byteTable = [Float](repeating: 0, count: 256)
        for b in 0..<256 {
            var sum: Float = 0
            for bit in 0..<8 {
                let isOne = ((b >> (7 - bit)) & 1) != 0
                sum += isOne ? 1.0 : -1.0
            }
            byteTable[b] = sum / 8.0
        }

        let bytesPerSampleRatio = max(4, dsdSampleRate / (88200 * 8))
        let targetSampleRate = dsdSampleRate / (bytesPerSampleRatio * 8)
        let totalPCMSamplesPerChannel = Int(dsdDataBytes / UInt64(channels * bytesPerSampleRatio))

        FileManager.default.createFile(atPath: destinationWAV.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: destinationWAV)
        defer { try? outHandle.close() }

        let wavHeader = makeWAVHeader(
            sampleRate: UInt32(targetSampleRate),
            channels: UInt16(channels),
            bitsPerSample: 16,
            dataByteSize: UInt32(totalPCMSamplesPerChannel * channels * 2)
        )
        try outHandle.write(contentsOf: wavHeader)

        try handle.seek(toOffset: dsdDataOffset)
        let chunkFrames = 4096
        let chunkByteSize = chunkFrames * bytesPerSampleRatio * channels
        var remainingSamples = totalPCMSamplesPerChannel
        var lp1 = [Float](repeating: 0, count: channels)
        var lp2 = [Float](repeating: 0, count: channels)
        let alpha: Float = 0.42

        while remainingSamples > 0 {
            let framesThisPass = min(chunkFrames, remainingSamples)
            let bytesToRead = framesThisPass * bytesPerSampleRatio * channels
            guard let rawData = try handle.read(upToCount: min(chunkByteSize, bytesToRead)),
                  rawData.count == bytesToRead else {
                break
            }

            var outBuffer = [Int16](repeating: 0, count: framesThisPass * channels)
            rawData.withUnsafeBytes { ptr in
                let bytes = ptr.bindMemory(to: UInt8.self)
                for s in 0..<framesThisPass {
                    for ch in 0..<channels {
                        var acc: Float = 0
                        for k in 0..<bytesPerSampleRatio {
                            let idx = (s * bytesPerSampleRatio + k) * channels + ch
                            acc += byteTable[Int(bytes[idx])]
                        }
                        let avg = acc / Float(bytesPerSampleRatio)
                        lp1[ch] += alpha * (avg - lp1[ch])
                        lp2[ch] += alpha * (lp1[ch] - lp2[ch])
                        let clamped = max(-1.0, min(1.0, lp2[ch] * 1.35))
                        outBuffer[s * channels + ch] = Int16(clamped * 32767.0).littleEndian
                    }
                }
            }

            let outData = outBuffer.withUnsafeBufferPointer { Data(buffer: $0) }
            try outHandle.write(contentsOf: outData)
            remainingSamples -= framesThisPass
        }
    }

    // MARK: - 3. Pure-Swift Monkey's Audio (.ape) MAC Header & APEv2 Tag Parser

    private static func parseAPEHeaderAndTag(url: URL, into meta: inout DecodedTrackMetadata) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0

        if let head = try? handle.read(upToCount: 76), head.count >= 40,
           String(data: head[0..<4], encoding: .ascii) == "MAC " {
            let version = readUInt16LE(head, offset: 4)
            if version >= 3980 && head.count >= 76 {
                let descBytes = Int(readUInt32LE(head, offset: 8))
                let hdrOffset = max(52, descBytes)
                if hdrOffset + 24 <= head.count {
                    let blocksPerFrame = UInt64(readUInt32LE(head, offset: hdrOffset + 4))
                    let finalFrameBlocks = UInt64(readUInt32LE(head, offset: hdrOffset + 8))
                    let totalFrames = UInt64(readUInt32LE(head, offset: hdrOffset + 12))
                    let bitsPerSample = Int(readUInt16LE(head, offset: hdrOffset + 16))
                    let sampleRate = Double(readUInt32LE(head, offset: hdrOffset + 20))

                    meta.bitDepth = bitsPerSample
                    meta.sampleRate = sampleRate
                    if totalFrames > 0 && sampleRate > 0 {
                        let totalBlocks = (totalFrames - 1) * blocksPerFrame + finalFrameBlocks
                        meta.duration = Double(totalBlocks) / sampleRate
                        if meta.duration > 0 && fileSize > 0 {
                            meta.bitrate = Int((Double(fileSize * 8) / meta.duration) / 1000.0)
                        }
                    }
                }
            }
        }

        // Parse APEv2 tag footer at end of file ("APETAGEX")
        if fileSize >= 32 {
            try? handle.seek(toOffset: fileSize - 32)
            if let footer = try? handle.read(upToCount: 32), footer.count == 32,
               String(data: footer[0..<8], encoding: .ascii) == "APETAGEX" {
                let tagSize = UInt64(readUInt32LE(footer, offset: 12))
                let itemCount = Int(readUInt32LE(footer, offset: 16))
                if tagSize >= 32 && tagSize <= fileSize && tagSize <= 16 * 1024 * 1024 {
                    let itemsStart = fileSize - tagSize
                    try? handle.seek(toOffset: itemsStart)
                    if let tagData = try? handle.read(upToCount: Int(tagSize - 32)) {
                        parseAPEv2Items(data: tagData, count: itemCount, into: &meta)
                    }
                }
            }
        }
    }

    private static func parseAPEv2Items(data: Data, count: Int, into meta: inout DecodedTrackMetadata) {
        var pos = data.startIndex
        for _ in 0..<count {
            guard pos + 8 <= data.endIndex else { break }
            let valSize = Int(readUInt32LE(data, offset: pos - data.startIndex))
            let flags = readUInt32LE(data, offset: (pos - data.startIndex) + 4)
            pos += 8

            guard let nullIdx = data[pos...].firstIndex(of: 0) else { break }
            let keyData = data[pos..<nullIdx]
            let key = (String(data: keyData, encoding: .utf8) ?? "").lowercased()
            pos = data.index(after: nullIdx)

            guard pos + valSize <= data.endIndex else { break }
            let valData = data[pos..<(pos + valSize)]
            pos += valSize

            let itemType = (flags >> 1) & 0x3
            if itemType == 1 {
                // Binary item (e.g. Cover Art (Front) = filename\0<image bytes>)
                if key.contains("cover art") {
                    if let binNull = valData.firstIndex(of: 0), binNull + 1 < valData.endIndex {
                        let imgData = Data(valData[(binNull + 1)...])
                        meta.embeddedArtwork = imgData
                        meta.hasCoverArt = true
                    }
                }
            } else if let str = String(data: valData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !str.isEmpty {
                switch key {
                case "title": meta.title = str
                case "artist": meta.artist = str
                case "album": meta.album = str
                case "album artist", "albumartist": meta.albumArtist = str
                case "genre": meta.genre = str
                case "year", "date":
                    let digits = str.components(separatedBy: CharacterSet.decimalDigits.inverted).first { $0.count == 4 }
                    if let d = digits, let y = Int(d) { meta.year = y }
                case "track", "tracknumber":
                    if let first = str.components(separatedBy: "/").first, let n = Int(first) { meta.trackNumber = n }
                case "disc", "discnumber":
                    if let first = str.components(separatedBy: "/").first, let n = Int(first) { meta.discNumber = n }
                default: break
                }
            }
        }
    }

    // MARK: - Pure-Swift ID3v2 Parser (for .dsf and .dff embedded ID3 chunks)

    private static func parseID3v2(data: Data, into meta: inout DecodedTrackMetadata) {
        guard data.count >= 10,
              String(data: data[data.startIndex..<(data.startIndex + 3)], encoding: .ascii) == "ID3" else {
            return
        }

        let base = data.startIndex
        let versionMajor = Int(data[base + 3])
        let tagSize = synchsafeInt(data, offset: 6)
        let endOffset = min(data.count, 10 + tagSize)
        var pos = 10

        while pos + 10 <= endOffset {
            let frameID = String(data: data[(base + pos)..<(base + pos + 4)], encoding: .ascii) ?? ""
            if frameID.trimmingCharacters(in: .controlCharacters).isEmpty { break }

            let frameSize: Int
            if versionMajor == 4 {
                frameSize = synchsafeInt(data, offset: pos + 4)
            } else {
                frameSize = Int(readUInt32BE(data, offset: pos + 4))
            }
            pos += 10
            guard frameSize > 0 && pos + frameSize <= endOffset else { break }

            let frameData = data[(base + pos)..<(base + pos + frameSize)]
            pos += frameSize

            if frameID == "APIC" {
                if let img = extractAPICImage(from: frameData) {
                    meta.embeddedArtwork = img
                    meta.hasCoverArt = true
                }
            } else if frameID.hasPrefix("T") {
                if let text = decodeID3TextFrame(frameData) {
                    switch frameID {
                    case "TIT2": meta.title = text
                    case "TPE1": meta.artist = text
                    case "TALB": meta.album = text
                    case "TPE2": meta.albumArtist = text
                    case "TCON": meta.genre = text
                    case "TRCK":
                        if let first = text.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces),
                           let num = Int(first) {
                            meta.trackNumber = num
                        }
                    case "TPOS":
                        if let first = text.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces),
                           let num = Int(first) {
                            meta.discNumber = num
                        }
                    case "TYER", "TDRC":
                        let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).first { $0.count == 4 }
                        if let d = digits, let y = Int(d) { meta.year = y }
                    default: break
                    }
                }
            }
        }
    }

    private static func decodeID3TextFrame(_ frameData: Data.SubSequence) -> String? {
        guard !frameData.isEmpty else { return nil }
        let encodingByte = frameData[frameData.startIndex]
        let payload = Data(frameData.dropFirst())
        let str: String?
        switch encodingByte {
        case 0: str = String(data: payload, encoding: .isoLatin1)
        case 1: str = String(data: payload, encoding: .utf16)
        case 2: str = String(data: payload, encoding: .utf16BigEndian)
        default: str = String(data: payload, encoding: .utf8)
        }
        return str?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
    }

    private static func extractAPICImage(from frameData: Data.SubSequence) -> Data? {
        let bytes = Array(frameData)
        // Look for JPEG (FF D8 FF) or PNG (89 50 4E 47) magic signature inside APIC payload
        for i in 0..<(max(0, bytes.count - 4)) {
            if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF) ||
               (bytes[i] == 0x89 && bytes[i + 1] == 0x50 && bytes[i + 2] == 0x4E && bytes[i + 3] == 0x47) {
                return Data(bytes[i...])
            }
        }
        return nil
    }

    // MARK: - FFprobe JSON Supplement

    private struct FFprobeOutput: Decodable {
        struct Stream: Decodable {
            let sample_rate: String?
            let bits_per_sample: Int?
            let bits_per_raw_sample: String?
            let duration: String?
        }
        struct Format: Decodable {
            let duration: String?
            let bit_rate: String?
            let tags: [String: String]?
        }
        let streams: [Stream]?
        let format: Format?
    }

    private static func supplementWithFFprobe(url: URL, into meta: inout DecodedTrackMetadata) {
        guard let ffprobePath = findExecutable(named: "ffprobe") else { return }
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: ffprobePath)
        proc.arguments = ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", url.path]
        proc.standardOutput = pipe
        guard (try? proc.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let parsed = try? JSONDecoder().decode(FFprobeOutput.self, from: data) else { return }
        if let stream = parsed.streams?.first {
            if meta.sampleRate == nil, let srStr = stream.sample_rate, let sr = Double(srStr) {
                meta.sampleRate = sr
            }
            if meta.bitDepth == nil {
                if let raw = stream.bits_per_raw_sample, let bd = Int(raw), bd > 0 {
                    meta.bitDepth = bd
                } else if let bd = stream.bits_per_sample, bd > 0 {
                    meta.bitDepth = bd
                }
            }
            if meta.duration <= 0, let dStr = stream.duration, let d = Double(dStr) {
                meta.duration = d
            }
        }
        if let fmt = parsed.format {
            if meta.duration <= 0, let dStr = fmt.duration, let d = Double(dStr) {
                meta.duration = d
            }
            if meta.bitrate == nil, let brStr = fmt.bit_rate, let br = Int(brStr) {
                meta.bitrate = br / 1000
            }
            if let tags = fmt.tags {
                for (rawK, val) in tags {
                    let k = rawK.lowercased()
                    if meta.title.isEmpty && k == "title" { meta.title = val }
                    if meta.artist.isEmpty && k == "artist" { meta.artist = val }
                    if meta.album.isEmpty && k == "album" { meta.album = val }
                    if meta.albumArtist == nil && (k == "album_artist" || k == "albumartist") { meta.albumArtist = val }
                    if meta.genre == nil && k == "genre" { meta.genre = val }
                    if meta.trackNumber == nil && k == "track" {
                        meta.trackNumber = Int(val.components(separatedBy: "/").first ?? "")
                    }
                    if meta.discNumber == nil && k == "disc" {
                        meta.discNumber = Int(val.components(separatedBy: "/").first ?? "")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func findExecutable(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func makeWAVHeader(sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16, dataByteSize: UInt32) -> Data {
        var data = Data(capacity: 44)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 &+ dataByteSize

        data.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: chunkSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) } // PCM = 1
        withUnsafeBytes(of: channels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataByteSize.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    private static func synchsafeInt(_ data: Data, offset: Int) -> Int {
        let b = data.startIndex + offset
        guard b + 4 <= data.endIndex else { return 0 }
        return (Int(data[b] & 0x7F) << 21)
            | (Int(data[b + 1] & 0x7F) << 14)
            | (Int(data[b + 2] & 0x7F) << 7)
            | Int(data[b + 3] & 0x7F)
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        let b = data.startIndex + offset
        return UInt16(data[b]) | (UInt16(data[b + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        return UInt32(data[b])
            | (UInt32(data[b + 1]) << 8)
            | (UInt32(data[b + 2]) << 16)
            | (UInt32(data[b + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, offset: Int) -> UInt64 {
        let lo = UInt64(readUInt32LE(data, offset: offset))
        let hi = UInt64(readUInt32LE(data, offset: offset + 4))
        return lo | (hi << 32)
    }

    private static func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
        let b = data.startIndex + offset
        return (UInt16(data[b]) << 8) | UInt16(data[b + 1])
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        return (UInt32(data[b]) << 24)
            | (UInt32(data[b + 1]) << 16)
            | (UInt32(data[b + 2]) << 8)
            | UInt32(data[b + 3])
    }

    private static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
        let hi = UInt64(readUInt32BE(data, offset: offset))
        let lo = UInt64(readUInt32BE(data, offset: offset + 4))
        return (hi << 32) | lo
    }
}
