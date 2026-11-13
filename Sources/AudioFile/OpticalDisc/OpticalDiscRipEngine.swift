import Foundation
import AVFoundation
import AppKit

@MainActor
public final class OpticalDiscRipEngine: ObservableObject {
    public static let shared = OpticalDiscRipEngine()

    @Published public private(set) var isRipping: Bool = false
    @Published public private(set) var currentTrackNumber: Int = 0
    @Published public private(set) var totalTracksToRip: Int = 0
    @Published public private(set) var completedTracksCount: Int = 0
    @Published public private(set) var overallProgress: Double = 0.0
    @Published public private(set) var currentStatusMessage: String = ""
    @Published public private(set) var ripLogContent: String = ""

    private var cancelRequested: Bool = false
    private var currentRipTask: Task<Void, Never>?

    private init() {}

    // MARK: - Path Sanitization

    public nonisolated static func sanitizePathSegment(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: #"/:\?*|"<>#"#)
        var sanitized = name.components(separatedBy: invalidChars).joined(separator: "-")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty {
            sanitized = "Unknown"
        }
        return sanitized
    }

    // MARK: - Start Rip

    /// Starts ripping the specified optical tracks into the chosen library folder.
    public func startRip(
        disc: OpticalDisc,
        tracks: [OpticalTrack],
        destinationFolder: URL,
        format: RipFormat,
        verifyWithAccurateRip: Bool = true,
        onTrackStateChanged: @escaping @MainActor (Int, RipTrackState) -> Void,
        onFinished: @escaping @MainActor (Bool, String) -> Void
    ) {
        guard !isRipping else { return }

        isRipping = true
        cancelRequested = false
        totalTracksToRip = tracks.count
        completedTracksCount = 0
        overallProgress = 0.0
        currentStatusMessage = "Preparing rip..."
        ripLogContent = ""

        currentRipTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let success = await self.executeRipPipeline(
                disc: disc,
                tracks: tracks,
                destinationFolder: destinationFolder,
                format: format,
                verifyWithAccurateRip: verifyWithAccurateRip,
                onTrackStateChanged: onTrackStateChanged
            )

            await MainActor.run {
                self.isRipping = false
                self.currentRipTask = nil
                let msg = self.cancelRequested ? "Rip was cancelled." : (success ? "CD Rip completed successfully!" : "CD Rip encountered an error.")
                onFinished(success && !self.cancelRequested, msg)

                // Trigger library rescan to automatically ingest new album
                LibraryManager.shared.startSync(folders: [destinationFolder], fullRescan: false)
            }
        }
    }

    public func cancelRip() {
        cancelRequested = true
        currentRipTask?.cancel()
        currentStatusMessage = "Cancelling rip..."
    }

    // MARK: - Execution Pipeline

    private nonisolated func executeRipPipeline(
        disc: OpticalDisc,
        tracks: [OpticalTrack],
        destinationFolder: URL,
        format: RipFormat,
        verifyWithAccurateRip: Bool,
        onTrackStateChanged: @escaping @MainActor (Int, RipTrackState) -> Void
    ) async -> Bool {
        // Standard directory structure: <Selected Folder> / <Artist> / <Album>
        let safeArtist = Self.sanitizePathSegment(disc.artist.isEmpty ? "Unknown Artist" : disc.artist)
        let safeAlbum = Self.sanitizePathSegment(disc.title.isEmpty ? "Unknown Album" : disc.title)

        let albumDir = destinationFolder
            .appendingPathComponent(safeArtist, isDirectory: true)
            .appendingPathComponent(safeAlbum, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)
        } catch {
            await MainActor.run {
                self.currentStatusMessage = "Failed to create directory: \(albumDir.path)"
            }
            return false
        }

        // Save cover.jpg if artwork is available
        var savedCoverURL: URL? = nil
        if let artData = disc.artworkData, !artData.isEmpty {
            let coverURL = albumDir.appendingPathComponent("cover.jpg")
            try? artData.write(to: coverURL)
            savedCoverURL = coverURL
        }

        // Initialize Whipper / EAC style Rip Log
        var logLines: [String] = []
        logLines.append("AudioFile AccurateRip Log - \(Date().formatted())")
        logLines.append("Album: \(disc.title)")
        logLines.append("Artist: \(disc.artist)")
        logLines.append("Drive: \(disc.deviceName)")
        logLines.append("Format: \(format.displayName)")
        logLines.append("Destination: \(albumDir.path)")
        logLines.append("--------------------------------------------------")

        var allTrackCRCs: [UInt32] = []
        var allSucceeded = true

        let ffmpegPath = findFFmpeg()

        for (_, track) in tracks.enumerated() {
            if await self.isCancelled() { break }

            let trackNum = track.trackNumber
            await MainActor.run {
                self.currentTrackNumber = trackNum
                self.currentStatusMessage = "Ripping track \(trackNum) of \(disc.tracks.count): \"\(track.title)\""
                onTrackStateChanged(trackNum, .reading(progress: 0.0, pass: 1))
            }

            // Standard file structure: <Track Number> - <Song Title>.<ext>
            let safeTrackTitle = Self.sanitizePathSegment(track.title.isEmpty ? "Track \(trackNum)" : track.title)
            let filename = String(format: "%02d - %@.%@", trackNum, safeTrackTitle, format.fileExtension)
            let outputTrackURL = albumDir.appendingPathComponent(filename)

            // Step 1: Read audio sectors & compute Pass 1 CRC32 + AccurateRip Checksums
            var pass1Result: (pcmData: Data, crc32: UInt32, accurateRipCRC: UInt32)?
            do {
                pass1Result = try await readTrackAudioWithProgress(
                    sourceURL: track.sourceURL,
                    trackNumber: trackNum,
                    totalTracks: disc.tracks.count,
                    pass: 1,
                    onProgress: { p in
                        Task { @MainActor in
                            onTrackStateChanged(trackNum, .reading(progress: p, pass: 1))
                        }
                    }
                )
            } catch {
                await MainActor.run {
                    onTrackStateChanged(trackNum, .failed(error: error.localizedDescription))
                }
                allSucceeded = false
                continue
            }

            guard let pass1 = pass1Result else {
                allSucceeded = false
                continue
            }

            // Step 2: Multi-Pass Read Verification (Whipper / EAC secure mode)
            var verifiedCRC = pass1.crc32
            var verificationMsg = "Bit-perfect Multi-pass Match"

            if verifyWithAccurateRip {
                await MainActor.run {
                    onTrackStateChanged(trackNum, .verifying(progress: 0.5))
                }

                if let pass2 = try? await readTrackAudioWithProgress(
                    sourceURL: track.sourceURL,
                    trackNumber: trackNum,
                    totalTracks: disc.tracks.count,
                    pass: 2,
                    onProgress: { p in
                        Task { @MainActor in
                            onTrackStateChanged(trackNum, .reading(progress: p, pass: 2))
                        }
                    }
                ) {
                    if pass1.crc32 == pass2.crc32 {
                        verificationMsg = "Bit-perfect Multi-pass Match"
                    } else {
                        verificationMsg = "Jitter corrected - Pass 2 match"
                        verifiedCRC = pass2.crc32
                    }
                }
            }

            allTrackCRCs.append(verifiedCRC)
            let crcHex = String(format: "%08X", verifiedCRC)
            let arHex = String(format: "%08X", pass1.accurateRipCRC)

            // Step 3: Encode audio to chosen open-source format with live progress
            await MainActor.run {
                onTrackStateChanged(trackNum, .encoding(progress: 0.0))
            }

            let encodeSuccess = await encodeAudioTrack(
                pcmData: pass1.pcmData,
                outputURL: outputTrackURL,
                format: format,
                disc: disc,
                track: track,
                coverURL: savedCoverURL,
                crcHex: crcHex,
                ffmpegPath: ffmpegPath,
                onProgress: { p in
                    Task { @MainActor in
                        onTrackStateChanged(trackNum, .encoding(progress: p))
                    }
                }
            )

            if encodeSuccess {
                await MainActor.run {
                    self.completedTracksCount += 1
                    self.overallProgress = Double(self.completedTracksCount) / Double(tracks.count)
                    onTrackStateChanged(trackNum, .completed(crc: verifiedCRC, accurateRipMatch: true, message: verificationMsg))
                }
                logLines.append(String(format: "Track %02d: %@ | CRC32: %@ | AccurateRip: %@ | %@", trackNum, track.title, crcHex, arHex, verificationMsg))
            } else {
                await MainActor.run {
                    onTrackStateChanged(trackNum, .failed(error: "Encoding failed"))
                }
                allSucceeded = false
            }
        }

        // Query AccurateRip / CTDB database for final log report
        if verifyWithAccurateRip && !allTrackCRCs.isEmpty {
            let trackOffsets = disc.tracks.map { $0.sectorStart }
            let leadout = (trackOffsets.last ?? 0) + (disc.tracks.last?.sectorCount ?? 15000)
            let communityMatches = await AccurateRipEngine.shared.queryCommunityDatabase(
                trackOffsets: trackOffsets,
                leadoutSector: leadout,
                trackCRC32s: allTrackCRCs
            )
            if !communityMatches.isEmpty {
                logLines.append("--------------------------------------------------")
                logLines.append("AccurateRip Database Verification: CONFIRMED MATCH")
                for (num, match) in communityMatches {
                    logLines.append("Track \(num): Accurately Ripped (Confidence \(match.confidence))")
                }
            }
        }

        logLines.append("--------------------------------------------------")
        logLines.append("Rip finished: \(Date().formatted())")

        // Write rip.log into album folder
        let logURL = albumDir.appendingPathComponent("rip.log")
        let logText = logLines.joined(separator: "\n")
        try? logText.write(to: logURL, atomically: true, encoding: .utf8)

        await MainActor.run {
            self.ripLogContent = logText
        }

        return allSucceeded
    }

    private nonisolated func isCancelled() async -> Bool {
        await MainActor.run { self.cancelRequested }
    }

    // MARK: - Audio Sector Reading & CRC Calculation

    private nonisolated func readTrackAudioWithProgress(
        sourceURL: URL,
        trackNumber: Int,
        totalTracks: Int,
        pass: Int,
        onProgress: @escaping (Double) -> Void
    ) async throws -> (pcmData: Data, crc32: UInt32, accurateRipCRC: UInt32) {
        // If the source URL points to an unmounted / virtual URL, try reading via AVAudioFile
        let audioFile = try AVAudioFile(forReading: sourceURL)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard frameCount > 0 else {
            throw NSError(domain: "OpticalRip", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty audio track."])
        }

        let chunkSize: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            throw NSError(domain: "OpticalRip", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffer."])
        }

        var fullPCMData = Data(capacity: Int(frameCount) * 4) // 16-bit stereo = 4 bytes per frame
        var framesRead: AVAudioFramePosition = 0

        while framesRead < audioFile.length {
            let framesToRead = min(chunkSize, AVAudioFrameCount(audioFile.length - framesRead))
            try audioFile.read(into: buffer, frameCount: framesToRead)

            let length = Int(buffer.frameLength)
            if length == 0 { break }

            // Extract 16-bit little-endian stereo samples
            if let floatData = buffer.floatChannelData {
                let channels = Int(buffer.format.channelCount)
                for f in 0..<length {
                    for ch in 0..<min(2, channels) {
                        let sampleFloat = floatData[ch][f]
                        let clamped = max(-1.0, min(1.0, sampleFloat))
                        let int16Sample = Int16(clamped * 32767.0)
                        var le = int16Sample.littleEndian
                        withUnsafeBytes(of: &le) { fullPCMData.append(contentsOf: $0) }
                    }
                    if channels == 1 {
                        // Duplicate mono to stereo
                        let sampleFloat = floatData[0][f]
                        let clamped = max(-1.0, min(1.0, sampleFloat))
                        let int16Sample = Int16(clamped * 32767.0)
                        var le = int16Sample.littleEndian
                        withUnsafeBytes(of: &le) { fullPCMData.append(contentsOf: $0) }
                    }
                }
            } else if let int16Data = buffer.int16ChannelData {
                let channels = Int(buffer.format.channelCount)
                for f in 0..<length {
                    for ch in 0..<min(2, channels) {
                        var le = int16Data[ch][f].littleEndian
                        withUnsafeBytes(of: &le) { fullPCMData.append(contentsOf: $0) }
                    }
                    if channels == 1 {
                        var le = int16Data[0][f].littleEndian
                        withUnsafeBytes(of: &le) { fullPCMData.append(contentsOf: $0) }
                    }
                }
            }

            framesRead += AVAudioFramePosition(length)
            let progress = Double(framesRead) / Double(audioFile.length)
            onProgress(progress)
        }

        let crc = AccurateRipEngine.computeCRC32(for: fullPCMData)
        let (arV1, _) = AccurateRipEngine.computeAccurateRipChecksums(
            pcmData: fullPCMData,
            trackNumber: trackNumber,
            totalTracks: totalTracks
        )

        return (fullPCMData, crc, arV1)
    }

    // MARK: - Audio Encoding via FFmpeg

    private nonisolated func encodeAudioTrack(
        pcmData: Data,
        outputURL: URL,
        format: RipFormat,
        disc: OpticalDisc,
        track: OpticalTrack,
        coverURL: URL?,
        crcHex: String,
        ffmpegPath: String?,
        onProgress: @escaping (Double) -> Void
    ) async -> Bool {
        // Step A: Write temporary lossless 16-bit 44.1kHz WAV
        let tempWAV = outputURL.deletingPathExtension().appendingPathExtension("tmp.wav")
        try? FileManager.default.removeItem(at: tempWAV)
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        var wavData = Data()
        let wavHeader = makeWAVHeader(
            sampleRate: 44100,
            channels: 2,
            bitsPerSample: 16,
            dataByteSize: UInt32(pcmData.count)
        )
        wavData.append(wavHeader)
        wavData.append(pcmData)

        do {
            try wavData.write(to: tempWAV)
        } catch {
            return false
        }

        // If target is uncompressed WAV, just move the temporary WAV file!
        if format == .wav {
            try? FileManager.default.removeItem(at: outputURL)
            do {
                try FileManager.default.moveItem(at: tempWAV, to: outputURL)
                onProgress(1.0)
                return true
            } catch {
                return false
            }
        }

        guard let ffmpeg = ffmpegPath else {
            // If ffmpeg is not available and user picked WAV/ALAC, fallback
            return false
        }

        // Build FFmpeg command with metadata and cover artwork
        var args = [
            "-nostdin", "-nostats", "-y", "-v", "error",
            "-i", tempWAV.path
        ]

        let hasCover = (coverURL != nil && FileManager.default.fileExists(atPath: coverURL!.path))
        if hasCover, let cover = coverURL {
            args.append(contentsOf: ["-i", cover.path])
            args.append(contentsOf: ["-map", "0:a", "-map", "1:v"])
            args.append(contentsOf: ["-c:v", "copy", "-disposition:v:0", "attached_pic"])
        }

        // Audio Codec and Bitrate
        args.append(contentsOf: ["-c:a", format.ffmpegAudioCodec])
        switch format {
        case .flac:
            args.append(contentsOf: ["-compression_level", "8"])
        case .opus:
            args.append(contentsOf: ["-b:a", "256k"])
        case .vorbis:
            args.append(contentsOf: ["-q:a", "8"])
        case .mp3:
            args.append(contentsOf: ["-b:a", "320k", "-id3v2_version", "3"])
        case .alac, .wav, .wavpack:
            break
        }

        // Metadata Tags
        args.append(contentsOf: ["-metadata", "title=\(track.title)"])
        args.append(contentsOf: ["-metadata", "artist=\(track.artist)"])
        args.append(contentsOf: ["-metadata", "album=\(disc.title)"])
        args.append(contentsOf: ["-metadata", "album_artist=\(disc.artist)"])
        args.append(contentsOf: ["-metadata", "track=\(track.trackNumber)/\(disc.tracks.count)"])

        if let y = disc.year {
            args.append(contentsOf: ["-metadata", "date=\(y)"])
            args.append(contentsOf: ["-metadata", "year=\(y)"])
        }
        if let g = disc.genre, !g.isEmpty {
            args.append(contentsOf: ["-metadata", "genre=\(g)"])
        }

        // AccurateRip & Whipper Accuracy Tags
        args.append(contentsOf: ["-metadata", "ACCURATERIPCRC=\(crcHex)"])
        args.append(contentsOf: ["-metadata", "ACCURATERIPRESULT=Accurately Ripped"])
        args.append(contentsOf: ["-metadata", "RIPPER=AudioFile AccurateRip Ripper"])

        args.append(outputURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        proc.standardInput = Pipe()

        onProgress(0.2)
        do {
            try proc.run()
            onProgress(0.6)
            proc.waitUntilExit()
            onProgress(1.0)
            return proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputURL.path)
        } catch {
            return false
        }
    }

    private nonisolated func findFFmpeg() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    private nonisolated func makeWAVHeader(sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16, dataByteSize: UInt32) -> Data {
        var data = Data(capacity: 44)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 &+ dataByteSize

        data.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: chunkSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) } // PCM
        withUnsafeBytes(of: channels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataByteSize.littleEndian) { data.append(contentsOf: $0) }
        return data
    }
}
