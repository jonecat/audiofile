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

    public init() {}

    public func setMode(_ mode: VisualizerMode) {
        currentMode = mode
    }

    public func start(fps: Int) {
        stop()
        let interval = 1.0 / Double(max(fps, 10))

        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.frame = VisualizerEngine.shared.getFrame(for: self.currentMode)
            }
        }
        // Add to .common mode to prevent timer pausing during mouse movement and UI tracking
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}
