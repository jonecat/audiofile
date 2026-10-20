import Foundation
import AVFoundation
import CryptoKit

public struct WaveformData: Sendable {
    public let path: URL
    public let peaks: [Float]
    public let isComplete: Bool

    public static let defaultBins = 512

    public static func empty(for path: URL) -> WaveformData {
        WaveformData(path: path, peaks: [Float](repeating: 0.1, count: defaultBins), isComplete: false)
    }

    public static func fastEstimate(for path: URL, duration: TimeInterval) -> WaveformData {
        var peaks = [Float]()
        peaks.reserveCapacity(defaultBins)
        let n = Float(defaultBins)
        let seed = Float(duration)

        for i in 0..<defaultBins {
            let x = Float(i) / n
            let shape = sin(x * .pi)
            let chorus1 = abs(sin(x * 16.0 + seed * 0.1)) * 0.25
            let chorus2 = abs(cos(x * 32.0 + seed * 0.3)) * 0.15
            let ripple = abs(sin(x * 64.0 + seed * 0.7)) * 0.1
            let raw = shape * 0.6 + chorus1 + chorus2 + ripple + 0.1
            let val = min(0.98, max(0.06, pow(raw, 0.8)))
            peaks.append(val)
        }

        return WaveformData(path: path, peaks: peaks, isComplete: false)
    }
}

public actor WaveformEngine {
    public static let shared = WaveformEngine()

    private var memoryCache: [String: [Float]] = [:]
    private var activeTasks: [String: Task<[Float]?, Never>] = [:]

    private static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("AudioFile/waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func waveform(for track: Track) async -> WaveformData {
        let key = cacheKey(for: track.path)

        // 1. Check memory cache
        if let cached = memoryCache[key] {
            return WaveformData(path: track.path, peaks: cached, isComplete: true)
        }

        // 2. Check disk cache
        if let diskPeaks = readFromDisk(key: key) {
            memoryCache[key] = diskPeaks
            return WaveformData(path: track.path, peaks: diskPeaks, isComplete: true)
        }

        // 3. Generate fast estimate immediately
        let estimate = WaveformData.fastEstimate(for: track.path, duration: track.duration)

        // 4. Start background accurate computation if not already running
        if activeTasks[key] == nil {
            let task = Task.detached(priority: .utility) { () -> [Float]? in
                return Self.computeAccurate(path: track.path, bins: WaveformData.defaultBins)
            }
            activeTasks[key] = task

            Task {
                if let accuratePeaks = await task.value {
                    self.storePeaks(accuratePeaks, for: key)
                }
                self.clearTask(for: key)
            }
        }

        return estimate
    }

    private func storePeaks(_ peaks: [Float], for key: String) {
        memoryCache[key] = peaks
        writeToDisk(peaks: peaks, key: key)
    }

    private func clearTask(for key: String) {
        activeTasks.removeValue(forKey: key)
    }

    private func cacheKey(for path: URL) -> String {
        let pathString = path.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(pathString.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func readFromDisk(key: String) -> [Float]? {
        let file = Self.cacheDirectory.appendingPathComponent("\(key).bin")
        guard let data = try? Data(contentsOf: file),
              data.count == WaveformData.defaultBins * MemoryLayout<Float>.size else {
            return nil
        }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    private func writeToDisk(peaks: [Float], key: String) {
        let file = Self.cacheDirectory.appendingPathComponent("\(key).bin")
        let data = peaks.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: file, options: .atomic)
    }

    private static func computeAccurate(path: URL, bins: Int) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: path) else { return nil }
        let totalFrames = file.length
        guard totalFrames > 0 else { return nil }

        let framesPerBin = max(1, AVAudioFrameCount(totalFrames / Int64(bins)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesPerBin) else {
            return nil
        }

        var peaks = [Float]()
        peaks.reserveCapacity(bins)

        for _ in 0..<bins {
            do {
                file.framePosition = min(file.framePosition, totalFrames)
                try file.read(into: buffer, frameCount: framesPerBin)
                guard let channelData = buffer.floatChannelData else {
                    peaks.append(0.1)
                    continue
                }
                let frameCount = Int(buffer.frameLength)
                if frameCount == 0 {
                    peaks.append(0.1)
                    continue
                }

                var maxVal: Float = 0
                let channels = Int(buffer.format.channelCount)
                for ch in 0..<min(channels, 2) {
                    let ptr = channelData[ch]
                    for f in 0..<frameCount {
                        let val = abs(ptr[f])
                        if val > maxVal { maxVal = val }
                    }
                }
                peaks.append(min(1.0, max(0.06, maxVal)))
            } catch {
                peaks.append(0.1)
            }
        }

        // Fill remaining if any
        while peaks.count < bins {
            peaks.append(0.1)
        }

        return peaks
    }
}
