import Foundation
import AVFoundation
import Accelerate
import CryptoKit
import SwiftUI

public enum DynamicRangeRatingCategory: String, Codable, Sendable {
    case audiophile = "Audiophile Master"
    case great = "Great Dynamic Range"
    case moderate = "Moderate Dynamic Range"
    case compressed = "Compressed (Loudness War)"
    case severe = "Severely Compressed"

    public var color: Color {
        switch self {
        case .audiophile: return Color(red: 0.18, green: 0.80, blue: 0.44)
        case .great: return Color(red: 0.20, green: 0.72, blue: 0.85)
        case .moderate: return Color(red: 0.95, green: 0.70, blue: 0.20)
        case .compressed: return Color(red: 0.95, green: 0.45, blue: 0.25)
        case .severe: return Color(red: 0.92, green: 0.26, blue: 0.26)
        }
    }
}

public struct DynamicRangeResult: Codable, Sendable, Equatable, Hashable {
    public let score: Int
    public let overallDR: Double
    public let channelDRs: [Double]
    public let peakDb: Double
    public let channelPeakDbs: [Double]
    public let rmsDb: Double
    public let channelRmsDbs: [Double]
    public let sampleRate: Double
    public let channels: Int
    public let calculatedAt: Date

    public init(
        score: Int,
        overallDR: Double,
        channelDRs: [Double],
        peakDb: Double,
        channelPeakDbs: [Double],
        rmsDb: Double,
        channelRmsDbs: [Double],
        sampleRate: Double,
        channels: Int,
        calculatedAt: Date = Date()
    ) {
        self.score = score
        self.overallDR = overallDR
        self.channelDRs = channelDRs
        self.peakDb = peakDb
        self.channelPeakDbs = channelPeakDbs
        self.rmsDb = rmsDb
        self.channelRmsDbs = channelRmsDbs
        self.sampleRate = sampleRate
        self.channels = channels
        self.calculatedAt = calculatedAt
    }

    public var displayLabel: String {
        return "DR\(score)"
    }

    public static func ratingCategory(for score: Int) -> DynamicRangeRatingCategory {
        switch score {
        case 14...: return .audiophile
        case 11...13: return .great
        case 8...10: return .moderate
        case 5...7: return .compressed
        default: return .severe
        }
    }

    public var ratingCategory: DynamicRangeRatingCategory {
        Self.ratingCategory(for: score)
    }

    public static func simple(score: Int) -> DynamicRangeResult {
        return DynamicRangeResult(
            score: score,
            overallDR: Double(score),
            channelDRs: [Double(score), Double(score)],
            peakDb: 0.0,
            channelPeakDbs: [0.0, 0.0],
            rmsDb: -Double(score) - 3.0,
            channelRmsDbs: [-Double(score) - 3.0, -Double(score) - 3.0],
            sampleRate: 44100,
            channels: 2
        )
    }

    public var tooltipText: String {
        var lines: [String] = [
            "Dynamic Range: DR\(score)",
            "Rating: \(ratingCategory.rawValue)",
            "Standard: Pleasurize TT DR Meter"
        ]

        var stats: [String] = []

        if overallDR > 0 {
            var drText = "• Track DR: \(String(format: "%.1f", overallDR)) dB"
            if channelDRs.count > 1 {
                let chDRs = channelDRs.enumerated().map { "Ch \($0.offset + 1): \(String(format: "%.1f", $0.element)) dB" }.joined(separator: "  |  ")
                drText += "\n  \(chDRs)"
            }
            stats.append(drText)
        }

        if peakDb != 0.0 || rmsDb != 0.0 {
            var peakText = "• Peak Level: \(String(format: "%.2f", peakDb)) dBFS"
            if channelPeakDbs.count > 1 {
                let chPeaks = channelPeakDbs.enumerated().map { "Ch \($0.offset + 1): \(String(format: "%.2f", $0.element)) dBFS" }.joined(separator: "  |  ")
                peakText += "\n  \(chPeaks)"
            }
            stats.append(peakText)

            var rmsText = "• RMS Loudness (Top 20%): \(String(format: "%.2f", rmsDb)) dBFS"
            if channelRmsDbs.count > 1 {
                let chRMSs = channelRmsDbs.enumerated().map { "Ch \($0.offset + 1): \(String(format: "%.2f", $0.element)) dBFS" }.joined(separator: "  |  ")
                rmsText += "\n  \(chRMSs)"
            }
            stats.append(rmsText)
        }

        if !stats.isEmpty {
            lines.append("")
            lines.append(stats.joined(separator: "\n\n"))
        }

        lines.append("")
        lines.append("Click badge to recalculate.")
        return lines.joined(separator: "\n")
    }
}

public enum DynamicRangeState: Sendable, Equatable {
    case idle
    case calculating
    case ready(DynamicRangeResult)
    case failed(String)
}

public actor DynamicRangeEngine {
    public static let shared = DynamicRangeEngine()

    /// Persistent in-memory lookup table loaded from Application Support
    private var persistentStore: [String: DynamicRangeResult] = [:]
    private var activeTasks: [String: Task<DynamicRangeResult?, Never>] = [:]
    private var isLoaded: Bool = false

    /// Permanent database location in Application Support (persists across launches and cache wipes)
    private static var databaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AudioFile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dynamic_range_db.json")
    }

    /// Fast synchronous snapshot of stored scores for initial library population
    public nonisolated static func readStoredScores() -> [String: Int] {
        let url = databaseURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: DynamicRangeResult].self, from: data) else {
            return [:]
        }
        return decoded.mapValues(\.score)
    }

    public nonisolated static func ratingCategory(for score: Int) -> DynamicRangeRatingCategory {
        DynamicRangeResult.ratingCategory(for: score)
    }

    public init() {
        let url = Self.databaseURL
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: DynamicRangeResult].self, from: data) {
            self.persistentStore = decoded
        } else {
            self.persistentStore = [:]
        }
        self.isLoaded = true
    }

    private func reloadDatabaseIfNeeded() {
        guard !isLoaded else { return }
        let url = Self.databaseURL
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: DynamicRangeResult].self, from: data) {
            self.persistentStore = decoded
        }
        self.isLoaded = true
    }

    private func savePersistentDatabase() {
        let url = Self.databaseURL
        let storeCopy = self.persistentStore
        Task.detached(priority: .background) {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(storeCopy) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    public func clearAllData() {
        persistentStore.removeAll()
        savePersistentDatabase()
    }

    /// Fast, non-blocking check for stored result (checks persistent database and track metadata)
    public func cachedResult(for track: Track) -> DynamicRangeResult? {
        reloadDatabaseIfNeeded()

        // 1. Direct lookup by track ID
        if let res = persistentStore[track.id] {
            return res
        }

        // 2. Lookup by canonical file path hash
        let pathKey = cacheKey(for: track.path)
        if let res = persistentStore[pathKey] {
            return res
        }

        // 3. Fallback to track.dynamicRange if persisted on the track model
        if let score = track.dynamicRange {
            let fallback = DynamicRangeResult(
                score: score,
                overallDR: Double(score),
                channelDRs: [Double(score), Double(score)],
                peakDb: 0.0,
                channelPeakDbs: [0.0, 0.0],
                rmsDb: -Double(score) - 3.0,
                channelRmsDbs: [-Double(score) - 3.0, -Double(score) - 3.0],
                sampleRate: track.sampleRate ?? 44100,
                channels: 2
            )
            persistentStore[track.id] = fallback
            persistentStore[pathKey] = fallback
            return fallback
        }

        return nil
    }

    /// Measures or returns the stored Dynamic Range score.
    /// If already stored and forceRecalculate is false, immediately returns stored result without re-processing!
    public func dynamicRange(for track: Track, forceRecalculate: Bool = false) async -> DynamicRangeResult? {
        reloadDatabaseIfNeeded()

        let trackKey = track.id
        let pathKey = cacheKey(for: track.path)

        // Return permanently stored result immediately unless manual recalculate was requested
        if !forceRecalculate {
            if let stored = persistentStore[trackKey] ?? persistentStore[pathKey] {
                return stored
            }
        }

        // Deduplicate in-flight task
        if let existingTask = activeTasks[trackKey] {
            return await existingTask.value
        }

        let path = track.path
        // Run with .userInitiated priority to utilize high-speed P-cores and unthrottled I/O
        let task = Task.detached(priority: .userInitiated) { () -> DynamicRangeResult? in
            return Self.computeDynamicRange(for: path)
        }
        activeTasks[trackKey] = task

        let result = await task.value
        activeTasks.removeValue(forKey: trackKey)

        if let validResult = result {
            persistentStore[trackKey] = validResult
            persistentStore[pathKey] = validResult
            savePersistentDatabase()

            // Update Track metadata in LibraryManager so it's also saved in library.json
            await MainActor.run {
                LibraryManager.shared.updateTrackDynamicRange(id: track.id, score: validResult.score)
            }
        }

        return result
    }

    private func cacheKey(for path: URL) -> String {
        let pathString = path.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(pathString.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// High-performance chunked implementation of the Pleasurize Music Foundation (TT DR Meter) Algorithm.
    /// Streams audio in larger chunks (~12 seconds per disk/network read) to minimize external USB/network latency,
    /// then processes 3-second RMS & Peak windows via SIMD Accelerate (vDSP).
    private static func computeDynamicRange(for path: URL) -> DynamicRangeResult? {
        guard let file = try? OpenSourceDecoders.openAudioFile(for: path) else {
            return nil
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let totalFrames = file.length

        guard sampleRate > 0, channels > 0, totalFrames > 0 else {
            return nil
        }

        // Official PMF adjustment for 44.1kHz: 132480 samples per 3-second window
        let deltaFs: Double = (sampleRate == 44100) ? 60 : 0
        let blockSamples = max(1, Int((sampleRate + deltaFs) * 3.0))

        // Read in 4-block chunks (approx 12 seconds per I/O call) to drastically reduce external disk/network overhead
        let blocksPerChunk = 4
        let chunkFrames = AVAudioFrameCount(blockSamples * blocksPerChunk)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return nil
        }

        let analysisChannels = min(channels, 2)
        var blockPeaks = Array(repeating: [Float](), count: analysisChannels)
        var blockRMS = Array(repeating: [Float](), count: analysisChannels)
        var totalSumSq = [Double](repeating: 0.0, count: analysisChannels)
        var totalSamplesRead: Int64 = 0
        var currentFrame: Int64 = 0

        while currentFrame < totalFrames {
            let remaining = totalFrames - currentFrame
            if remaining <= 0 { break }
            let toRead = min(Int64(chunkFrames), remaining)

            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(toRead))
                let framesRead = Int(buffer.frameLength)
                if framesRead == 0 { break }
                currentFrame += Int64(framesRead)
                totalSamplesRead += Int64(framesRead)

                guard let channelData = buffer.floatChannelData else { break }

                // Sub-slice the chunk into exact 3-second PMF blocks in RAM without repeated disk seeks
                var offset = 0
                while offset < framesRead {
                    let thisBlockLen = min(blockSamples, framesRead - offset)
                    for ch in 0..<analysisChannels {
                        let ptr = channelData[ch] + offset

                        var peak: Float = 0
                        vDSP_maxmgv(ptr, 1, &peak, vDSP_Length(thisBlockLen))

                        var sumSq: Float = 0
                        vDSP_svesq(ptr, 1, &sumSq, vDSP_Length(thisBlockLen))

                        totalSumSq[ch] += Double(sumSq)

                        // AES-17 sine wave reference (+3.01 dB = factor of 2.0 under sqrt)
                        let rms = sqrt(2.0 * Double(sumSq) / Double(thisBlockLen))
                        blockPeaks[ch].append(peak)
                        blockRMS[ch].append(Float(rms))
                    }
                    offset += thisBlockLen
                }
            } catch {
                break
            }
        }

        guard !blockRMS.isEmpty, !blockRMS[0].isEmpty else {
            return nil
        }

        var chDR = [Double]()
        var chPeakDb = [Double]()
        var chRMSDb = [Double]()

        let cutBestBins = 0.2
        let actualSegs = blockRMS[0].count
        var nBlk = Int(floor(Double(actualSegs) * cutBestBins))
        if nBlk < 1 { nBlk = 1 }

        for ch in 0..<analysisChannels {
            let sortedPeaks = blockPeaks[ch].sorted()
            let sortedRMS = blockRMS[ch].sorted()

            // The official TT DR meter uses the 2nd highest peak block to reject digital overs/spikes
            let peakIndex = max(0, actualSegs - 2)
            let secondPeak = sortedPeaks.count > peakIndex ? sortedPeaks[peakIndex] : (sortedPeaks.last ?? 1.0)
            let peakDb = 20.0 * log10(max(Double(sortedPeaks.last ?? 1.0), 1e-9))
            chPeakDb.append(min(0.0, peakDb))

            let topRMS = Array(sortedRMS.suffix(nBlk))
            var topSumSq: Double = 0
            for r in topRMS {
                topSumSq += Double(r * r)
            }
            let topMeanRms = sqrt(topSumSq / Double(nBlk))

            let dr = -20.0 * log10(max(topMeanRms / Double(max(secondPeak, 1e-9)), 1e-9))
            chDR.append(max(0.0, dr))

            let trackRms = sqrt(2.0 * totalSumSq[ch] / Double(max(totalSamplesRead, 1)))
            let trackRmsDb = 20.0 * log10(max(trackRms, 1e-9))
            chRMSDb.append(trackRmsDb)
        }

        let overallDR = chDR.reduce(0.0, +) / Double(chDR.count)
        let roundedDR = max(1, Int(round(overallDR)))
        let maxPeakDb = chPeakDb.max() ?? 0.0
        let overallRmsDb = chRMSDb.reduce(0.0, +) / Double(chRMSDb.count)

        return DynamicRangeResult(
            score: roundedDR,
            overallDR: overallDR,
            channelDRs: chDR,
            peakDb: maxPeakDb,
            channelPeakDbs: chPeakDb,
            rmsDb: overallRmsDb,
            channelRmsDbs: chRMSDb,
            sampleRate: sampleRate,
            channels: channels
        )
    }
}
