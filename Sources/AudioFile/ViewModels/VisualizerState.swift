import Foundation
import SwiftUI

@MainActor
public final class VisualizerState: ObservableObject {
    public static let shared = VisualizerState()

    @Published public var bands: [Float] = [Float](repeating: 0, count: VisualizerEngine.numBands)
    @Published public var peaks: [Float] = [Float](repeating: 0, count: VisualizerEngine.numBands)

    private var timer: Timer?

    public init() {}

    public func start(fps: Int) {
        stop()
        let interval = 1.0 / Double(max(fps, 10))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let result = VisualizerEngine.shared.getBands()
                self?.bands = result.bands
                self?.peaks = result.peaks
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}
