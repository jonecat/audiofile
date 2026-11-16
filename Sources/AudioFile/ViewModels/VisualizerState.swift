import Foundation
import SwiftUI

@MainActor
public final class VisualizerState: ObservableObject {
    public static let shared = VisualizerState()

    @Published public private(set) var frame: VisualizerFrame = VisualizerFrame()
    public private(set) var currentMode: VisualizerMode = .bars

    public var bands: [Float] { frame.bands }
    public var peaks: [Float] { frame.peaks }
    public var vuLeft: Float { frame.vuLeft }
    public var vuRight: Float { frame.vuRight }
    public var vuLeftPeak: Bool { frame.vuLeftPeak }
    public var vuRightPeak: Bool { frame.vuRightPeak }

    private var timer: Timer?
    private var currentFPS: Int = 0
    private var isZeroed: Bool = true

    public init() {}

    public func setMode(_ mode: VisualizerMode) {
        currentMode = mode
    }

    public func start(fps: Int) {
        if timer != nil && currentFPS == fps { return }
        stop()
        currentFPS = fps
        isZeroed = false
        let interval = 1.0 / Double(max(fps, 10))

        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.frame = VisualizerEngine.shared.getFrame(for: self.currentMode)
                self.isZeroed = false
            }
        }
        // Add to .common mode to prevent timer pausing during mouse movement and UI tracking
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    public func stop(resetFrame: Bool = false) {
        timer?.invalidate()
        timer = nil
        currentFPS = 0
        if resetFrame && !isZeroed {
            frame = VisualizerFrame()
            isZeroed = true
        }
    }
}
