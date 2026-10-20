import Foundation
import Accelerate

public final class VisualizerEngine: @unchecked Sendable {
    public static let shared = VisualizerEngine()

    public static let fftSize = 2048
    public static let numBands = 64

    private let lock = NSLock()
    private var sampleBuffer = [Float](repeating: 0, count: fftSize)
    private var writePos = 0
    private var sampleRate: Double = 44100
    private var fps: Double = 60

    private var bandValues = [Float](repeating: 0, count: numBands)
    private var peakValues = [Float](repeating: 0, count: numBands)

    private var fftSetup: FFTSetup?
    private let log2n = vDSP_Length(11) // 2048 = 2^11
    private var window = [Float](repeating: 0, count: fftSize)

    // Preallocated working buffers for FFT to avoid heap allocations in audio loop
    private var windowedSamples = [Float](repeating: 0, count: fftSize)
    private var realBuffer = [Float](repeating: 0, count: fftSize / 2)
    private var imagBuffer = [Float](repeating: 0, count: fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: fftSize / 2)

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
        lock.lock()
        defer { lock.unlock() }

        let bufCount = sampleBuffer.count
        for sample in samples {
            sampleBuffer[writePos] = sample
            writePos = (writePos + 1) % bufCount
        }
    }

    public func clear() {
        lock.lock()
        sampleBuffer = [Float](repeating: 0, count: Self.fftSize)
        bandValues = [Float](repeating: 0, count: Self.numBands)
        peakValues = [Float](repeating: 0, count: Self.numBands)
        lock.unlock()
    }

    public func getBands() -> (bands: [Float], peaks: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        guard let setup = fftSetup else {
            return (bandValues, peakValues)
        }

        let halfSize = Self.fftSize / 2
        let currentWritePos = writePos

        // 1. Order samples from ring buffer into contiguous windowed buffer
        for i in 0..<Self.fftSize {
            let idx = (currentWritePos + i) % Self.fftSize
            windowedSamples[i] = sampleBuffer[idx]
        }

        // Apply Hann window
        vDSP_vmul(windowedSamples, 1, window, 1, &windowedSamples, 1, vDSP_Length(Self.fftSize))

        // 2. Prepare split complex buffer for vDSP FFT
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

                // 3. In-place Forward FFT
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                // 4. Compute magnitudes: sqrt(real^2 + imag^2)
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Scale by 0.5 because vDSP_fft_zrip scales by 2
        var scale: Float = 0.5 / Float(halfSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfSize))

        // 5. Map into 64 logarithmically spaced bands
        let sRate = Float(sampleRate)
        let binWidth = sRate / Float(Self.fftSize)
        let minFreq: Float = 40.0
        let maxFreq: Float = min(sRate / 2.0, 14000.0)

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

            // Treble boost curve + logarithmic dB compression matching omaflac
            let eqBoost = 1.0 + max(0.0, log10(freqCenter / 500.0)) * 1.8
            let scaled = min(1.0, pow(avgMag * 14.0 * eqBoost, 0.85))
            rawBands[band] = scaled
        }

        // 6. Dynamic envelope follower physics with hysteresis snap
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

        return (bandValues, peakValues)
    }
}
