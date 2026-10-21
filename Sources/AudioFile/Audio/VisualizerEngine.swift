import Foundation
import Accelerate

public struct VisualizerFrame: Sendable {
    public let bands: [Float]
    public let peaks: [Float]
    public let vuLeft: Float
    public let vuRight: Float
    public let vuLeftPeak: Bool
    public let vuRightPeak: Bool

    public init(
        bands: [Float] = [Float](repeating: 0, count: VisualizerEngine.numBands),
        peaks: [Float] = [Float](repeating: 0, count: VisualizerEngine.numBands),
        vuLeft: Float = 0,
        vuRight: Float = 0,
        vuLeftPeak: Bool = false,
        vuRightPeak: Bool = false
    ) {
        self.bands = bands
        self.peaks = peaks
        self.vuLeft = vuLeft
        self.vuRight = vuRight
        self.vuLeftPeak = vuLeftPeak
        self.vuRightPeak = vuRightPeak
    }
}

public final class VisualizerEngine: @unchecked Sendable {
    public static let shared = VisualizerEngine()

    public static let fftSize = 2048
    public static let numBands = 64

    private let lock = NSLock()
    private var sampleBuffer = [Float](repeating: 0, count: fftSize)
    private var leftBuffer = [Float](repeating: 0, count: fftSize)
    private var rightBuffer = [Float](repeating: 0, count: fftSize)
    private var writePos = 0
    private var sampleRate: Double = 44100
    private var fps: Double = 60

    // Spectrum state
    private var bandValues = [Float](repeating: 0, count: numBands)
    private var peakValues = [Float](repeating: 0, count: numBands)

    // VU meter needle state (position & velocity for dynamic ballistics)
    private var vuPosL: Float = 0.0
    private var vuVelL: Float = 0.0
    private var vuPosR: Float = 0.0
    private var vuVelR: Float = 0.0
    private var peakHoldL: Float = 0.0
    private var peakHoldR: Float = 0.0

    private var fftSetup: FFTSetup?
    private let log2n = vDSP_Length(11) // 2048 = 2^11
    private var window = [Float](repeating: 0, count: fftSize)

    // Preallocated working buffers to avoid heap allocations
    private var windowedSamples = [Float](repeating: 0, count: fftSize)
    private var realBuffer = [Float](repeating: 0, count: fftSize / 2)
    private var imagBuffer = [Float](repeating: 0, count: fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: fftSize / 2)
    private var recentL = [Float](repeating: 0, count: 1024)
    private var recentR = [Float](repeating: 0, count: 1024)

    public init(sampleRate: Double = 44100) {
        self.sampleRate = max(1.0, sampleRate)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        // Create Hann window
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    public func setFPS(_ targetFPS: Double) {
        lock.lock()
        fps = min(max(targetFPS, 10), 240)
        lock.unlock()
    }

    public func setSampleRate(_ rate: Double) {
        lock.lock()
        sampleRate = max(1.0, rate)
        lock.unlock()
    }

    public func pushSamples(_ samples: UnsafeBufferPointer<Float>) {
        pushStereoSamples(left: samples, right: samples)
    }

    public func pushStereoSamples(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }

        let bufCount = sampleBuffer.count
        let count = min(left.count, right.count)
        guard count > 0 else { return }

        for i in 0..<count {
            let l = left[i]
            let r = right[i]
            let mono = (l + r) * 0.5

            leftBuffer[writePos] = l
            rightBuffer[writePos] = r
            sampleBuffer[writePos] = mono

            writePos = (writePos + 1) % bufCount
        }
    }

    public func clear() {
        lock.lock()
        sampleBuffer = [Float](repeating: 0, count: Self.fftSize)
        leftBuffer = [Float](repeating: 0, count: Self.fftSize)
        rightBuffer = [Float](repeating: 0, count: Self.fftSize)
        bandValues = [Float](repeating: 0, count: Self.numBands)
        peakValues = [Float](repeating: 0, count: Self.numBands)
        vuPosL = 0.0
        vuVelL = 0.0
        vuPosR = 0.0
        vuVelR = 0.0
        peakHoldL = 0.0
        peakHoldR = 0.0
        lock.unlock()
    }

    public func getBands() -> (bands: [Float], peaks: [Float]) {
        let frame = getFrame(for: .bars)
        return (frame.bands, frame.peaks)
    }

    public func getFrame(for mode: VisualizerMode = .bars) -> VisualizerFrame {
        lock.lock()
        defer { lock.unlock() }

        let currentFPS = max(fps, 10.0)
        let dt = Float(1.0 / currentFPS)

        switch mode {
        case .bars, .circular:
            computeFFT()
            return VisualizerFrame(
                bands: bandValues,
                peaks: peakValues
            )

        case .vuMeter:
            let (vuL, vuR, peakL, peakR) = computeVUMeters(dt: dt)
            return VisualizerFrame(
                vuLeft: vuL,
                vuRight: vuR,
                vuLeftPeak: peakL,
                vuRightPeak: peakR
            )
        }
    }

    // MARK: - Internal DSP Algorithms

    private func computeFFT() {
        guard let setup = fftSetup else { return }

        let halfSize = Self.fftSize / 2
        let currentWritePos = writePos

        // Order samples from ring buffer into contiguous windowed buffer
        for i in 0..<Self.fftSize {
            let idx = (currentWritePos + i) % Self.fftSize
            windowedSamples[i] = sampleBuffer[idx]
        }

        // Apply Hann window
        vDSP_vmul(windowedSamples, 1, window, 1, &windowedSamples, 1, vDSP_Length(Self.fftSize))

        // Prepare split complex buffer for vDSP FFT
        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )

                windowedSamples.withUnsafeBytes { rawBytes in
                    let dspComplexPtr = rawBytes.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(dspComplexPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(halfSize))
                }

                // In-place Forward FFT
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                // Compute magnitudes: sqrt(real^2 + imag^2)
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Scale by 0.5 because vDSP_fft_zrip scales by 2
        var scale: Float = 0.5 / Float(halfSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfSize))

        // Map into 64 logarithmically spaced bands
        let sRate = Float(sampleRate)
        let binWidth = sRate / Float(Self.fftSize)
        let minFreq: Float = 35.0
        let maxFreq: Float = min(sRate / 2.0, 16000.0)

        var rawBands = [Float](repeating: 0, count: Self.numBands)

        for band in 0..<Self.numBands {
            let t0 = Float(band) / Float(Self.numBands)
            let t1 = Float(band + 1) / Float(Self.numBands)

            let fLow = minFreq * pow(maxFreq / minFreq, t0)
            let fHigh = minFreq * pow(maxFreq / minFreq, t1)
            let freqCenter = sqrt(fLow * fHigh)

            let exactLow = min(max(fLow / binWidth, 1.0), Float(halfSize - 2))
            let exactHigh = min(max(fHigh / binWidth, exactLow), Float(halfSize - 1))

            let avgMag: Float
            if exactHigh - exactLow < 1.0 {
                let exactCenter = min(max(freqCenter / binWidth, 1.0), Float(halfSize - 2))
                let idx0 = Int(floor(exactCenter))
                let idx1 = min(idx0 + 1, halfSize - 1)
                let frac = exactCenter - Float(idx0)
                let m0 = magnitudes[idx0]
                let m1 = magnitudes[idx1]
                avgMag = m0 * (1.0 - frac) + m1 * frac
            } else {
                let binLow = min(max(Int(floor(exactLow)), 1), halfSize - 1)
                let binHigh = min(max(Int(ceil(exactHigh)), binLow + 1), halfSize)
                var sumMag: Float = 0
                var maxMag: Float = 0
                var count = 0
                for b in binLow..<binHigh {
                    let m = magnitudes[b]
                    sumMag += m
                    if m > maxMag { maxMag = m }
                    count += 1
                }
                avgMag = count > 0 ? (sumMag / Float(count)) * 0.5 + maxMag * 0.5 : 0.0
            }

            // Treble boost curve + logarithmic dB compression
            let eqBoost = 1.0 + max(0.0, log10(freqCenter / 500.0)) * 1.8
            let scaled = min(1.0, pow(avgMag * 14.0 * eqBoost, 0.85))
            rawBands[band] = scaled
        }

        // Dynamic envelope follower physics with hysteresis snap
        let currentFPS = max(fps, 10.0)
        let dtRatio = Float(30.0 / currentFPS)
        let attackFactor = min(max(1.0 - pow(1.0 - 0.65, dtRatio), 0.01), 1.0)
        let decayFactor = min(max(1.0 - pow(1.0 - 0.20, dtRatio), 0.01), 1.0)
        let peakFalloff = Float(0.02) * dtRatio

        for b in 0..<Self.numBands {
            let target = rawBands[b]
            let current = bandValues[b]
            let diff = target - current

            let nextVal: Float
            if abs(diff) < 1e-4 {
                nextVal = target
            } else if diff > 0 {
                nextVal = current + diff * attackFactor
            } else {
                nextVal = current + diff * decayFactor
            }
            let clampedNext = min(max(nextVal, 0.0), 1.0)
            bandValues[b] = clampedNext

            // Peak cap decay
            let peak = peakValues[b]
            let nextPeak: Float
            if clampedNext >= peak || abs(peak - clampedNext) < 1e-4 {
                nextPeak = clampedNext
            } else {
                nextPeak = max(peak - peakFalloff, clampedNext)
            }
            peakValues[b] = min(max(nextPeak, 0.0), 1.0)
        }
    }

    private func computeVUMeters(dt: Float) -> (Float, Float, Bool, Bool) {
        let analysisSize = 1024
        let total = Self.fftSize

        let startIdx = (writePos - analysisSize + total) % total
        for i in 0..<analysisSize {
            let idx = (startIdx + i) % total
            recentL[i] = leftBuffer[idx]
            recentR[i] = rightBuffer[idx]
        }

        var rmsL: Float = 0
        var rmsR: Float = 0
        var peakL: Float = 0
        var peakR: Float = 0

        vDSP_rmsqv(recentL, 1, &rmsL, vDSP_Length(analysisSize))
        vDSP_rmsqv(recentR, 1, &rmsR, vDSP_Length(analysisSize))
        vDSP_maxmgv(recentL, 1, &peakL, vDSP_Length(analysisSize))
        vDSP_maxmgv(recentR, 1, &peakR, vDSP_Length(analysisSize))

        let dbL = 20.0 * log10(max(rmsL, 1e-4))
        let dbR = 20.0 * log10(max(rmsR, 1e-4))

        let targetL = min(max((dbL + 34.0) / 26.0, 0.0), 1.15)
        let targetR = min(max((dbR + 34.0) / 26.0, 0.0), 1.15)

        // D'Arsonval analog galvanometer spring-damper ballistics
        let springK: Float = 145.0
        let damping: Float = 17.0

        vuVelL += ((targetL - vuPosL) * springK - vuVelL * damping) * dt
        vuPosL += vuVelL * dt
        vuPosL = min(max(vuPosL, 0.0), 1.15)

        vuVelR += ((targetR - vuPosR) * springK - vuVelR * damping) * dt
        vuPosR += vuVelR * dt
        vuPosR = min(max(vuPosR, 0.0), 1.15)

        if peakL > 0.91 { peakHoldL = 0.35 } else { peakHoldL = max(0, peakHoldL - dt) }
        if peakR > 0.91 { peakHoldR = 0.35 } else { peakHoldR = max(0, peakHoldR - dt) }

        return (vuPosL, vuPosR, peakHoldL > 0, peakHoldR > 0)
    }
}
