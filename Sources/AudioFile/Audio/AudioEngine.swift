import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import MediaPlayer
import AppKit

public enum PlaybackState: Sendable {
    case stopped
    case playing
    case paused
}

private final class CrossfeedRenderState: @unchecked Sendable {
    var level: Float = 0.25
    var sampleRate: Double = 44_100
    var lpB0: Float = 0.095
    var lpA1: Float = 0.905
    var lpL: Float = 0
    var lpR: Float = 0
    var delaySamples: Int = 11
    var writeIdx: Int = 0
    var delayL = [Float](repeating: 0, count: 512)
    var delayR = [Float](repeating: 0, count: 512)

    func configure(sampleRate: Double) {
        self.sampleRate = max(8000, sampleRate)
        let x = Float(exp(-2.0 * Double.pi * 700.0 / self.sampleRate))
        lpB0 = 1.0 - x
        lpA1 = x
        delaySamples = max(1, min(256, Int((0.00026 * self.sampleRate).rounded())))
        reset()
    }

    func reset() {
        lpL = 0
        lpR = 0
        writeIdx = 0
        for i in delayL.indices {
            delayL[i] = 0
            delayR[i] = 0
        }
    }
}

private final class CrossfeedAudioUnit: AUAudioUnit, @unchecked Sendable {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x78666564, // 'xfed'
        componentManufacturer: 0x4175466c, // 'AuFl'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static let registerOnce: Void = {
        AUAudioUnit.registerSubclass(
            CrossfeedAudioUnit.self,
            as: componentDescription,
            name: "AudioFile Crossfeed",
            version: 1
        )
    }()

    static func ensureRegistered() {
        _ = registerOnce
    }

    let renderState = CrossfeedRenderState()
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        self.inputBus = try AUAudioUnitBus(format: format)
        self.outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        self._inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        self._outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        self.maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        renderState.configure(sampleRate: outputBus.format.sampleRate)
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        renderState.reset()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = self.renderState
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pull = pullInputBlock else { return noErr }
            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let status = pull(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            let crossGain = min(0.7, max(0.0, state.level))
            if crossGain <= 0.001 { return noErr }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 2,
                  let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            let frames = Int(frameCount)
            let b0 = state.lpB0
            let a1 = state.lpA1
            let mask = 511
            let delay = state.delaySamples
            let norm = 1.0 / (1.0 + crossGain * 0.5)
            var lpL = state.lpL
            var lpR = state.lpR
            var w = state.writeIdx

            state.delayL.withUnsafeMutableBufferPointer { bufL in
                state.delayR.withUnsafeMutableBufferPointer { bufR in
                    guard let dLBase = bufL.baseAddress, let dRBase = bufR.baseAddress else { return }
                    for i in 0..<frames {
                        let inL = leftPtr[i]
                        let inR = rightPtr[i]
                        lpL = b0 * inL + a1 * lpL
                        lpR = b0 * inR + a1 * lpR
                        dLBase[w] = lpL
                        dRBase[w] = lpR
                        let readIdx = (w - delay) & mask
                        let crossR = dRBase[readIdx]
                        let crossL = dLBase[readIdx]
                        leftPtr[i] = norm * (inL + crossGain * crossR)
                        rightPtr[i] = norm * (inR + crossGain * crossL)
                        w = (w + 1) & mask
                    }
                }
            }

            state.lpL = lpL
            state.lpR = lpR
            state.writeIdx = w
            return noErr
        }
    }
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

    @Published public private(set) var availableDevices: [AudioOutputDevice] = []
    @Published public private(set) var activeOutputDevice: AudioOutputDevice?
    @Published public private(set) var hardwareSampleRate: Double = 44_100
    @Published public private(set) var isHogModeActive: Bool = false
    @Published public private(set) var activeReplayGainDb: Double = 0
    @Published public private(set) var isGaplessNextScheduled: Bool = false

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 10)
    private let crossfeedNode: AVAudioUnitEffect
    private let mixerNode = AVAudioMixerNode()

    private var audioFile: AVAudioFile?
    private var trackStartFrame: AVAudioFramePosition = 0
    private var trackEndFrame: AVAudioFramePosition = 0
    private var seekFrameOffset: AVAudioFramePosition = 0
    private var playbackSampleTimeBase: AVAudioFramePosition = 0
    private var currentScheduledSegmentFrames: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var fileSampleRate: Double = 44_100
    private var playbackGeneration: UInt64 = 0
    private var segmentCounter: UInt64 = 0
    private var activeSegmentId: UInt64 = 0
    private var nextScheduledSegmentId: UInt64 = 0

    private var playbackTimer: Timer?
    private var preloadedTrack: Track?
    private var preloadedFile: AVAudioFile?
    private var preloadGeneration: UInt64 = 0

    private var gaplessScheduledTrack: Track?
    private var gaplessScheduledFile: AVAudioFile?
    private var gaplessScheduledStartFrame: AVAudioFramePosition = 0
    private var gaplessScheduledEndFrame: AVAudioFramePosition = 0
    private var gaplessScheduledFrameCount: AVAudioFramePosition = 0

    private var currentConfig: AppConfig = AppConfig.load()
    private var hoggedDeviceID: AudioDeviceID?
    private var currentGraphFormat: AVAudioFormat?
    private var isRebuildingGraph: Bool = false
    private var configChangeObserver: NSObjectProtocol?

    public var onTrackCompleted: (@MainActor () -> Void)?
    public var onPreviousTrackRequested: (@MainActor () -> Void)?
    public var onGaplessTrackAdvanced: (@MainActor (Track) -> Void)?

    public init() {
        CrossfeedAudioUnit.ensureRegistered()
        self.crossfeedNode = AVAudioUnitEffect(audioComponentDescription: CrossfeedAudioUnit.componentDescription)
        setupAudioEngine()
        setupRemoteCommands()
        refreshOutputDevices()
        applyAudioConfig(currentConfig)
    }

    private func setupAudioEngine() {
        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(crossfeedNode)
        engine.attach(mixerNode)

        connectGraph()
        mixerNode.installTap(onBus: 0, bufferSize: 512, format: nil, block: Self.makeTapBlock())
        configChangeObserver = Self.makeConfigurationChangeObserver(engine: self, audioEngine: engine)

        do {
            try engine.start()
        } catch {
            print("Failed to start AVAudioEngine:", error)
        }
    }

    private func connectGraph(format: AVAudioFormat? = nil) {
        let nodeFormat = format ?? audioFile?.processingFormat
        currentGraphFormat = nodeFormat
        engine.connect(playerNode, to: eqNode, format: nodeFormat)
        engine.connect(eqNode, to: crossfeedNode, format: nodeFormat)
        engine.connect(crossfeedNode, to: mixerNode, format: nodeFormat)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: nil)
    }

    private func rebuildGraphForHardwareFormatChange(format: AVAudioFormat? = nil) {
        guard !isRebuildingGraph else { return }
        isRebuildingGraph = true
        defer { isRebuildingGraph = false }

        let targetFormat = format ?? audioFile?.processingFormat
        let wasRunning = engine.isRunning
        playerNode.stop()
        if wasRunning {
            engine.stop()
        }
        mixerNode.removeTap(onBus: 0)
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(eqNode)
        engine.disconnectNodeOutput(crossfeedNode)
        engine.disconnectNodeOutput(mixerNode)

        connectGraph(format: targetFormat)
        mixerNode.installTap(onBus: 0, bufferSize: 512, format: nil, block: Self.makeTapBlock())
        engine.prepare()

        if wasRunning {
            try? engine.start()
        }
    }

    private func handleEngineConfigurationChange() {
        guard !isRebuildingGraph else { return }
        if let dev = activeOutputDevice,
           let actualRate = CoreAudioDeviceManager.nominalSampleRate(for: dev.deviceID) {
            hardwareSampleRate = actualRate
        }
        guard let file = audioFile else {
            rebuildGraphForHardwareFormatChange(format: nil)
            return
        }
        let wasPlaying = (state == .playing)
        let resumePosition = currentTime
        rebuildGraphForHardwareFormatChange(format: file.processingFormat)
        if wasPlaying {
            seek(to: resumePosition, startPlaying: true)
        }
    }

    public func refreshOutputDevices() {
        availableDevices = CoreAudioDeviceManager.outputDevices()
    }

    public func applyAudioConfig(_ config: AppConfig) {
        let deviceChanged = config.selectedOutputDeviceUID != currentConfig.selectedOutputDeviceUID || activeOutputDevice == nil
        let hogChanged = config.exclusiveHogMode != currentConfig.exclusiveHogMode
        currentConfig = config

        // 1. Configure 10-band Parametric EQ
        eqNode.bypass = !config.eqEnabled
        eqNode.globalGain = config.eqPreampDb
        for idx in 0..<min(eqNode.bands.count, config.eqBands.count) {
            let bandCfg = config.eqBands[idx]
            let eqBand = eqNode.bands[idx]
            switch bandCfg.filterType {
            case .parametric:
                eqBand.filterType = .parametric
            case .lowShelf:
                eqBand.filterType = .lowShelf
            case .highShelf:
                eqBand.filterType = .highShelf
            }
            eqBand.frequency = Float(max(20.0, min(20_000.0, bandCfg.frequency)))
            eqBand.gain = max(-24.0, min(24.0, bandCfg.gainDb))
            eqBand.bandwidth = Float(max(0.15, min(5.0, 1.0 / max(0.1, bandCfg.qFactor))))
            eqBand.bypass = false
        }

        // 2. Configure Headphone Crossfeed
        crossfeedNode.bypass = !config.crossfeedEnabled
        if let cfAU = crossfeedNode.auAudioUnit as? CrossfeedAudioUnit {
            cfAU.renderState.level = config.crossfeedLevel
        }

        // 3. Configure Output DAC & Exclusive Hog Mode
        refreshOutputDevices()
        if deviceChanged || hogChanged {
            if let oldHogID = hoggedDeviceID, (!config.exclusiveHogMode || deviceChanged) {
                CoreAudioDeviceManager.setHogMode(enabled: false, on: oldHogID)
                hoggedDeviceID = nil
                isHogModeActive = false
            }

            if deviceChanged {
                let wasPlaying = (state == .playing)
                let resumeTime = currentTime
                if wasPlaying {
                    playerNode.pause()
                }
                if engine.isRunning {
                    engine.stop()
                }
                let resolved = CoreAudioDeviceManager.setOutputDevice(uid: config.selectedOutputDeviceUID, on: engine)
                activeOutputDevice = resolved
                if let dev = resolved {
                    var rate = dev.nominalSampleRate
                    if config.autoSampleRateSwitching, currentTrack != nil, fileSampleRate > 0 {
                        rate = CoreAudioDeviceManager.switchSampleRateIfSupported(fileSampleRate, on: dev.deviceID)
                    }
                    hardwareSampleRate = rate
                }
                rebuildGraphForHardwareFormatChange()
                if wasPlaying, let track = currentTrack {
                    play(track: track, at: resumeTime)
                }
            }

            if config.exclusiveHogMode, let dev = activeOutputDevice {
                let locked = CoreAudioDeviceManager.setHogMode(enabled: true, on: dev.deviceID)
                isHogModeActive = locked
                hoggedDeviceID = locked ? dev.deviceID : nil
            } else {
                isHogModeActive = false
            }
        } else if let dev = activeOutputDevice {
            hardwareSampleRate = CoreAudioDeviceManager.nominalSampleRate(for: dev.deviceID) ?? dev.nominalSampleRate
        }

        // 4. Refresh ReplayGain & volume
        activeReplayGainDb = computeReplayGainDb(for: currentTrack)
        updateVolume()
    }

    private func computeReplayGainDb(for track: Track?) -> Double {
        guard let track else { return 0 }
        switch currentConfig.replayGainMode {
        case .off:
            return 0
        case .track:
            return track.replayGainTrackDb ?? track.replayGainAlbumDb ?? 0
        case .album:
            return track.replayGainAlbumDb ?? track.replayGainTrackDb ?? 0
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
            VisualizerEngine.shared.pushStereoSamples(left: buf, right: buf)
        } else if channelCount >= 2 {
            let leftBuf = UnsafeBufferPointer(start: channelData[0], count: frameLength)
            let rightBuf = UnsafeBufferPointer(start: channelData[1], count: frameLength)
            VisualizerEngine.shared.pushStereoSamples(left: leftBuf, right: rightBuf)
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
        commandCenter.previousTrackCommand.addTarget(handler: Self.makeRemoteCommandHandler(engine: self) { $0.onPreviousTrackRequested?() })

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
        activeSegmentId &+= 1
        clearGaplessScheduledState()
        stopPlaybackTimer()
        playerNode.stop()
        state = .stopped
        currentTime = 0
        playbackSampleTimeBase = 0

        do {
            let file: AVAudioFile
            if preloadedTrack?.id == track.id, let cached = preloadedFile {
                file = cached
            } else {
                file = try OpenSourceDecoders.openAudioFile(for: track.path)
            }
            preloadedTrack = nil
            preloadedFile = nil

            self.audioFile = file
            self.totalFrames = file.length
            self.fileSampleRate = file.fileFormat.sampleRate

            let startSecs = max(0, track.startTimeOffset ?? 0)
            let startFrame = min(file.length, AVAudioFramePosition(startSecs * fileSampleRate))
            let endFrame: AVAudioFramePosition
            if let endSecs = track.endTimeOffset, endSecs > startSecs {
                endFrame = min(file.length, AVAudioFramePosition(endSecs * fileSampleRate))
            } else {
                endFrame = file.length
            }
            self.trackStartFrame = startFrame
            self.trackEndFrame = endFrame
            self.seekFrameOffset = startFrame
            self.duration = fileSampleRate > 0
                ? Double(max(0, endFrame - startFrame)) / fileSampleRate
                : max(0, track.duration)

            // Auto switch hardware DAC sample rate to match source file if enabled,
            // and ensure graph node format matches file.processingFormat
            var needsGraphRebuild = (file.processingFormat != currentGraphFormat)
            if currentConfig.autoSampleRateSwitching,
               fileSampleRate > 0,
               let dev = activeOutputDevice ?? CoreAudioDeviceManager.resolveDevice(uid: currentConfig.selectedOutputDeviceUID) {
                activeOutputDevice = dev
                let newRate = CoreAudioDeviceManager.switchSampleRateIfSupported(fileSampleRate, on: dev.deviceID)
                if abs(newRate - hardwareSampleRate) >= 1.0 {
                    hardwareSampleRate = newRate
                    needsGraphRebuild = true
                } else {
                    hardwareSampleRate = newRate
                }
            } else if let dev = activeOutputDevice {
                hardwareSampleRate = CoreAudioDeviceManager.nominalSampleRate(for: dev.deviceID) ?? dev.nominalSampleRate
            }

            if needsGraphRebuild {
                rebuildGraphForHardwareFormatChange(format: file.processingFormat)
            }

            var playingTrack = track
            var trackChanged = false
            if playingTrack.sampleRate == nil && fileSampleRate > 0 {
                playingTrack.sampleRate = fileSampleRate
                trackChanged = true
            }
            if playingTrack.bitrate == nil, let size = playingTrack.fileSize, self.duration > 0 {
                playingTrack.bitrate = Int((Double(size * 8) / self.duration) / 1000.0)
                trackChanged = true
            }
            self.currentTrack = trackChanged ? playingTrack : track
            self.activeReplayGainDb = computeReplayGainDb(for: self.currentTrack)
            updateVolume()

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
        scheduleGaplessNextIfPossible()
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
        activeSegmentId &+= 1
        clearGaplessScheduledState()
        stopPlaybackTimer()
        playerNode.stop()
        state = .stopped
        currentTime = 0
        trackStartFrame = 0
        trackEndFrame = 0
        seekFrameOffset = 0
        playbackSampleTimeBase = 0
        currentScheduledSegmentFrames = 0
        audioFile = nil
        activeReplayGainDb = 0
        VisualizerEngine.shared.clear()
        updateNowPlayingInfo()
    }

    public func clearCurrentTrack() {
        stop()
        currentTrack = nil
        duration = 0
        preloadedTrack = nil
        preloadedFile = nil
        updateNowPlayingInfo()
    }

    public func seek(to time: TimeInterval, startPlaying: Bool = true) {
        guard let file = audioFile else { return }
        let targetTime = min(max(time, 0.0), duration)
        let frameRate = file.processingFormat.sampleRate
        let targetFrame = trackStartFrame + AVAudioFramePosition(targetTime * frameRate)

        playbackGeneration &+= 1
        segmentCounter &+= 1
        let segId = segmentCounter
        activeSegmentId = segId

        clearGaplessScheduledState()
        stopPlaybackTimer()
        playerNode.stop()
        playbackSampleTimeBase = 0

        let framesRemaining = max(0, trackEndFrame - targetFrame)
        guard framesRemaining > 0 else {
            return
        }

        seekFrameOffset = targetFrame
        currentTime = targetTime
        currentScheduledSegmentFrames = framesRemaining

        let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(UInt32.max), framesRemaining))

        playerNode.scheduleSegment(
            file,
            startingFrame: targetFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: Self.makeSegmentCompletionHandler(engine: self, segmentId: segId)
        )

        if startPlaying || state == .playing {
            if !engine.isRunning {
                try? engine.start()
            }
            playerNode.play()
            state = .playing
            startPlaybackTimer()
            scheduleGaplessNextIfPossible()
        }

        updateNowPlayingInfo()
    }

    public func seekRelative(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private func updateVolume() {
        if isMuted {
            mixerNode.volume = 0.0
            return
        }
        var effectiveVol = max(0.0, volume)
        if currentConfig.replayGainMode != .off {
            let totalDb = activeReplayGainDb + Double(currentConfig.replayGainPreampDb)
            var rgLinear = Float(pow(10.0, totalDb / 20.0))
            if let peak = currentTrack?.replayGainPeak, peak > 0 {
                let maxSafe = Float(1.0 / peak)
                rgLinear = min(rgLinear, maxSafe)
            }
            effectiveVol *= rgLinear
        }
        mixerNode.volume = max(0.0, effectiveVol)
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
        let elapsedFrames = playerTime.sampleTime - playbackSampleTimeBase
        let currentTotalFrames = seekFrameOffset + elapsedFrames
        let trackRelativeFrames = currentTotalFrames - trackStartFrame
        let calculatedTime = Double(trackRelativeFrames) / sampleRate

        if currentTotalFrames >= trackEndFrame && trackEndFrame > trackStartFrame {
            if gaplessScheduledTrack != nil {
                advanceToGaplessScheduledTrack()
            } else {
                handleTrackFinished()
            }
        } else {
            currentTime = max(0.0, min(calculatedTime, duration))
        }
    }

    private func handleTrackFinished() {
        guard state == .playing else { return }
        guard duration > 0, currentTime >= max(0.0, duration - 1.5) else { return }
        stop()
        onTrackCompleted?()
    }

    public func clearPreloadedNextTrack() {
        preloadedTrack = nil
        preloadedFile = nil
        preloadGeneration &+= 1
        if gaplessScheduledTrack != nil {
            let resumeTime = currentTime
            let wasPlaying = (state == .playing)
            clearGaplessScheduledState()
            if audioFile != nil {
                seek(to: resumeTime, startPlaying: wasPlaying)
            }
        }
    }

    public func preloadNextTrack(_ track: Track) {
        if gaplessScheduledTrack?.id == track.id {
            return
        }
        if gaplessScheduledTrack != nil && gaplessScheduledTrack?.id != track.id {
            // Queue/upcoming track changed while a different segment was already queued on playerNode
            let resumeTime = currentTime
            let wasPlaying = (state == .playing)
            clearGaplessScheduledState()
            if audioFile != nil {
                seek(to: resumeTime, startPlaying: wasPlaying)
            }
        }

        if preloadedTrack?.id == track.id, preloadedFile != nil {
            scheduleGaplessNextIfPossible()
            return
        }

        preloadedTrack = track
        preloadedFile = nil
        preloadGeneration &+= 1
        let gen = preloadGeneration

        Task.detached(priority: .utility) {
            let file = try? OpenSourceDecoders.openAudioFile(for: track.path)
            await MainActor.run { [weak self] in
                guard let self = self, self.preloadGeneration == gen, self.preloadedTrack?.id == track.id else {
                    return
                }
                self.preloadedFile = file
                self.scheduleGaplessNextIfPossible()
            }
        }
    }

    private func clearGaplessScheduledState() {
        gaplessScheduledTrack = nil
        gaplessScheduledFile = nil
        gaplessScheduledStartFrame = 0
        gaplessScheduledEndFrame = 0
        gaplessScheduledFrameCount = 0
        isGaplessNextScheduled = false
    }

    private func scheduleGaplessNextIfPossible() {
        guard state == .playing,
              gaplessScheduledTrack == nil,
              let nextTrack = preloadedTrack,
              let nextFile = preloadedFile,
              let currentFile = audioFile else {
            return
        }

        // Gapless node scheduling requires matching PCM processing format and no pending hardware sample-rate switch
        guard nextFile.processingFormat == currentFile.processingFormat else {
            return
        }
        if currentConfig.autoSampleRateSwitching,
           abs(nextFile.fileFormat.sampleRate - hardwareSampleRate) >= 1.0 {
            return
        }

        let rate = nextFile.fileFormat.sampleRate
        let startSecs = max(0, nextTrack.startTimeOffset ?? 0)
        let startFrame = min(nextFile.length, AVAudioFramePosition(startSecs * rate))
        let endFrame: AVAudioFramePosition
        if let endSecs = nextTrack.endTimeOffset, endSecs > startSecs {
            endFrame = min(nextFile.length, AVAudioFramePosition(endSecs * rate))
        } else {
            endFrame = nextFile.length
        }
        let frameCountPos = max(0, endFrame - startFrame)
        guard frameCountPos > 0 else { return }

        segmentCounter &+= 1
        let nextSegId = segmentCounter
        nextScheduledSegmentId = nextSegId

        let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(UInt32.max), frameCountPos))
        playerNode.scheduleSegment(
            nextFile,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: Self.makeSegmentCompletionHandler(engine: self, segmentId: nextSegId)
        )

        gaplessScheduledTrack = nextTrack
        gaplessScheduledFile = nextFile
        gaplessScheduledStartFrame = startFrame
        gaplessScheduledEndFrame = endFrame
        gaplessScheduledFrameCount = frameCountPos
        isGaplessNextScheduled = true
    }

    private func advanceToGaplessScheduledTrack() {
        guard let nextTrack = gaplessScheduledTrack,
              let nextFile = gaplessScheduledFile else {
            return
        }

        playbackSampleTimeBase += currentScheduledSegmentFrames
        audioFile = nextFile
        totalFrames = nextFile.length
        fileSampleRate = nextFile.fileFormat.sampleRate
        trackStartFrame = gaplessScheduledStartFrame
        trackEndFrame = gaplessScheduledEndFrame
        seekFrameOffset = gaplessScheduledStartFrame
        currentScheduledSegmentFrames = gaplessScheduledFrameCount
        duration = fileSampleRate > 0
            ? Double(max(0, trackEndFrame - trackStartFrame)) / fileSampleRate
            : max(0, nextTrack.duration)
        activeSegmentId = nextScheduledSegmentId

        clearGaplessScheduledState()
        preloadedTrack = nil
        preloadedFile = nil

        var playingTrack = nextTrack
        if playingTrack.sampleRate == nil && fileSampleRate > 0 {
            playingTrack.sampleRate = fileSampleRate
        }
        currentTrack = playingTrack
        currentTime = 0
        activeReplayGainDb = computeReplayGainDb(for: playingTrack)
        updateVolume()
        VisualizerEngine.shared.setSampleRate(fileSampleRate)
        updateNowPlayingInfo()

        onGaplessTrackAdvanced?(playingTrack)
    }

    public func updateCurrentTrackMetadata(_ updatedTrack: Track) {
        guard currentTrack?.id == updatedTrack.id else { return }
        currentTrack = updatedTrack
        activeReplayGainDb = computeReplayGainDb(for: updatedTrack)
        updateVolume()
        updateNowPlayingInfo()
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

    private nonisolated static func makeConfigurationChangeObserver(
        engine: AudioEngine,
        audioEngine: AVAudioEngine
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak engine] _ in
            MainActor.assumeIsolated {
                engine?.handleEngineConfigurationChange()
            }
        }
    }

    private nonisolated static func makeSegmentCompletionHandler(
        engine: AudioEngine,
        segmentId: UInt64
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        return { [weak engine] _ in
            Task { @MainActor in
                guard let engine = engine, engine.activeSegmentId == segmentId else { return }
                if engine.gaplessScheduledTrack != nil {
                    engine.advanceToGaplessScheduledTrack()
                } else {
                    engine.handleTrackFinished()
                }
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
