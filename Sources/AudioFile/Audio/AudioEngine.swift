import Foundation
import AVFoundation
import MediaPlayer
import AppKit

public enum PlaybackState: Sendable {
    case stopped
    case playing
    case paused
}

@MainActor
public final class AudioEngine: ObservableObject {
    public static let shared = AudioEngine()

    @Published public private(set) var state: PlaybackState = .stopped
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public var volume: Float = 0.8 {
        didSet {
            updateVolume()
        }
    }
    @Published public var isMuted: Bool = false {
        didSet {
            updateVolume()
        }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let mixerNode = AVAudioMixerNode()

    private var audioFile: AVAudioFile?
    private var seekFrameOffset: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var fileSampleRate: Double = 44100
    private var playbackGeneration: UInt64 = 0

    private var playbackTimer: Timer?
    private var isSeeking = false
    private var preloadedTrack: Track?
    private var preloadedFile: AVAudioFile?

    public var onTrackCompleted: (@MainActor () -> Void)?

    public init() {
        setupAudioEngine()
        setupRemoteCommands()
    }

    private func setupAudioEngine() {
        engine.attach(playerNode)
        engine.attach(mixerNode)

        // Connect playerNode -> mixerNode -> mainMixerNode
        engine.connect(playerNode, to: mixerNode, format: nil)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: nil)

        // Install tap on mixerNode to feed the VisualizerEngine
        mixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(VisualizerEngine.fftSize), format: nil, block: Self.makeTapBlock())

        do {
            try engine.start()
        } catch {
            print("Failed to start AVAudioEngine:", error)
        }
    }

    private nonisolated static func makeTapBlock() -> AVAudioNodeTapBlock {
        return { buffer, _ in
            processTapBuffer(buffer)
        }
    }

    private nonisolated static func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        if channelCount == 1 {
            let ptr = channelData[0]
            let buf = UnsafeBufferPointer(start: ptr, count: frameLength)
            VisualizerEngine.shared.pushSamples(buf)
        } else if channelCount >= 2 {
            let left = channelData[0]
            let right = channelData[1]
            var mono = [Float](repeating: 0, count: frameLength)
            for i in 0..<frameLength {
                mono[i] = (left[i] + right[i]) * 0.5
            }
            mono.withUnsafeBufferPointer { buf in
                VisualizerEngine.shared.pushSamples(buf)
            }
        }
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget(handler: Self.makeRemoteCommandHandler(engine: self) { $0.resume() })

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget(handler: Self.makeRemoteCommandHandler(engine: self) { $0.pause() })

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget(handler: Self.makeRemoteCommandHandler(engine: self) { $0.togglePlayPause() })

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget(handler: Self.makeRemoteCommandHandler(engine: self) { $0.onTrackCompleted?() })

        commandCenter.previousTrackCommand.isEnabled = true
        // Will be configured by PlayerViewModel

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget(handler: Self.makePlaybackPositionHandler(engine: self))
    }

    private nonisolated static func makeRemoteCommandHandler(
        engine: AudioEngine,
        action: @escaping @MainActor @Sendable (AudioEngine) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return { [weak engine] _ in
            Task { @MainActor in
                guard let engine = engine else { return }
                action(engine)
            }
            return .success
        }
    }

    private nonisolated static func makePlaybackPositionHandler(
        engine: AudioEngine
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return { [weak engine] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = posEvent.positionTime
            Task { @MainActor in
                engine?.seek(to: positionTime)
            }
            return .success
        }
    }

    public func play(track: Track, at position: TimeInterval = 0) {
        playbackGeneration &+= 1
        stopPlaybackTimer()
        playerNode.stop()
        state = .stopped
        currentTime = 0
        seekFrameOffset = 0

        do {
            let file = try OpenSourceDecoders.openAudioFile(for: track.path)
            self.audioFile = file
            self.currentTrack = track
            self.totalFrames = file.length
            self.fileSampleRate = file.fileFormat.sampleRate
            self.duration = track.duration > 0 ? track.duration : Double(file.length) / file.fileFormat.sampleRate

            VisualizerEngine.shared.setSampleRate(fileSampleRate)

            if !engine.isRunning {
                try engine.start()
            }

            seek(to: position, startPlaying: true)
        } catch {
            print("Failed to read audio file \(track.path):", error)
        }
    }

    public func pause() {
        guard state == .playing else { return }
        playerNode.pause()
        state = .paused
        stopPlaybackTimer()
        updateNowPlayingInfo()
    }

    public func resume() {
        guard state == .paused else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
        state = .playing
        startPlaybackTimer()
        updateNowPlayingInfo()
    }

    public func togglePlayPause() {
        if state == .playing {
            pause()
        } else if state == .paused {
            resume()
        } else if let track = currentTrack {
            play(track: track)
        }
    }

    public func stop() {
        playbackGeneration &+= 1
        stopPlaybackTimer()
        playerNode.stop()
        state = .stopped
        currentTime = 0
        seekFrameOffset = 0
        audioFile = nil
        VisualizerEngine.shared.clear()
        updateNowPlayingInfo()
    }

    public func seek(to time: TimeInterval, startPlaying: Bool = true) {
        guard let file = audioFile else { return }
        let targetTime = min(max(time, 0.0), duration)
        let frameRate = file.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition(targetTime * frameRate)

        playbackGeneration &+= 1
        let currentGen = playbackGeneration

        stopPlaybackTimer()
        playerNode.stop()

        let framesRemaining = max(0, totalFrames - targetFrame)
        guard framesRemaining > 0 else {
            return
        }

        seekFrameOffset = targetFrame
        currentTime = targetTime

        let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(UInt32.max), framesRemaining))

        playerNode.scheduleSegment(
            file,
            startingFrame: targetFrame,
            frameCount: frameCount,
            at: nil,
            completionHandler: Self.makeSegmentCompletionHandler(engine: self, generation: currentGen)
        )

        if startPlaying || state == .playing {
            if !engine.isRunning {
                try? engine.start()
            }
            playerNode.play()
            state = .playing
            startPlaybackTimer()
        }

        updateNowPlayingInfo()
    }

    public func seekRelative(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private func updateVolume() {
        let effectiveVol: Float = isMuted ? 0.0 : max(0.0, volume)
        mixerNode.volume = effectiveVol
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentTime()
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func updateCurrentTime() {
        guard state == .playing, let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              let file = audioFile else {
            return
        }

        let sampleRate = file.processingFormat.sampleRate
        let elapsedFrames = playerTime.sampleTime
        let currentTotalFrames = seekFrameOffset + elapsedFrames
        let calculatedTime = Double(currentTotalFrames) / sampleRate

        if calculatedTime >= duration && duration > 0 {
            handleTrackFinished()
        } else {
            currentTime = max(0.0, min(calculatedTime, duration))
        }
    }

    private func handleTrackFinished() {
        guard state == .playing else { return }
        // Ensure track has genuinely reached within 1.5 seconds of duration
        guard duration > 0, currentTime >= max(0.0, duration - 1.5) else { return }
        stop()
        onTrackCompleted?()
    }

    public func preloadNextTrack(_ track: Track) {
        guard preloadedTrack?.id != track.id else { return }
        preloadedTrack = track
        Task.detached(priority: .utility) {
            let file = try? OpenSourceDecoders.openAudioFile(for: track.path)
            await MainActor.run {
                self.preloadedFile = file
            }
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0
        ]

        if track.hasCoverArt {
            let coverURL = track.path.deletingLastPathComponent().appendingPathComponent("cover.jpg")
            if let artwork = Self.makeMediaArtwork(at: coverURL) {
                info[MPMediaItemPropertyArtwork] = artwork
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private nonisolated static func makeSegmentCompletionHandler(
        engine: AudioEngine,
        generation: UInt64
    ) -> @Sendable () -> Void {
        return { [weak engine] in
            Task { @MainActor in
                guard let engine = engine, engine.playbackGeneration == generation else { return }
                engine.handleTrackFinished()
            }
        }
    }

    private nonisolated static func makeMediaArtwork(at coverURL: URL) -> MPMediaItemArtwork? {
        guard let data = try? Data(contentsOf: coverURL),
              let image = NSImage(data: data) else {
            return nil
        }
        let size = image.size
        return MPMediaItemArtwork(boundsSize: size) { _ in
            NSImage(data: data) ?? NSImage(size: size)
        }
    }
}
