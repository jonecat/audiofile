import SwiftUI

@MainActor
final class WaveformBarState: ObservableObject {
    @Published var isHovering = false
    @Published var hoverFraction: CGFloat?
    @Published var isDragging = false
}

public struct WaveformBarView: View {
    public let waveform: WaveformData?
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let onSeek: (TimeInterval) -> Void

    @StateObject private var state = WaveformBarState()

    public init(
        waveform: WaveformData?,
        currentTime: TimeInterval,
        duration: TimeInterval,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.waveform = waveform
        self.currentTime = currentTime
        self.duration = duration
        self.onSeek = onSeek
    }

    private var progressFraction: CGFloat {
        if state.isDragging, let hover = state.hoverFraction {
            return hover
        }
        guard duration > 0 else { return 0 }
        return CGFloat(currentTime / duration)
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack(alignment: .leading) {
                // Background & Waveform Canvas
                Canvas { context, size in
                    let peaks = waveform?.peaks ?? []
                    let count = peaks.count

                    if count > 0 {
                        let barSpacing: CGFloat = 1.0
                        let totalBars = min(count, Int(size.width / (barSpacing + 1.0)))
                        let barWidth = max(1.0, (size.width - CGFloat(totalBars - 1) * barSpacing) / CGFloat(totalBars))
                        let step = Double(count) / Double(totalBars)

                        let playedWidth = progressFraction * size.width

                        for b in 0..<totalBars {
                            let peakIndex = min(Int(Double(b) * step), count - 1)
                            let amp = CGFloat(peaks[peakIndex])
                            let barHeight = max(3.0, amp * (size.height - 4.0))
                            let x = CGFloat(b) * (barWidth + barSpacing)
                            let y = (size.height - barHeight) / 2.0

                            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                            let path = Path(roundedRect: rect, cornerRadius: 1.0)

                            if x <= playedWidth {
                                context.fill(path, with: .color(Color.accentColor))
                            } else {
                                context.fill(path, with: .color(Color.primary.opacity(0.18)))
                            }
                        }
                    } else {
                        // Fallback horizontal progress bar
                        let bgRect = CGRect(x: 0, y: height / 2 - 2, width: width, height: 4)
                        context.fill(Path(roundedRect: bgRect, cornerRadius: 2), with: .color(Color.primary.opacity(0.15)))

                        let playedRect = CGRect(x: 0, y: height / 2 - 2, width: progressFraction * width, height: 4)
                        context.fill(Path(roundedRect: playedRect, cornerRadius: 2), with: .color(Color.accentColor))
                    }
                }

                // Playhead thumb circle (appears on hover/drag)
                if state.isHovering || state.isDragging {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .shadow(radius: 2)
                        .position(x: min(max(5, progressFraction * width), width - 5), y: height / 2)
                }

                // Hover time label tooltip
                if let hover = state.hoverFraction, state.isHovering {
                    let hoverTime = Double(hover) * duration
                    Text(formatTime(hoverTime))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .shadow(radius: 2)
                        .position(x: min(max(24, hover * width), width - 24), y: -12)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard width > 0, duration > 0 else { return }
                let fraction = min(max(location.x / width, 0.0), 1.0)
                onSeek(Double(fraction) * duration)
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        state.isDragging = true
                        let fraction = min(max(value.location.x / width, 0.0), 1.0)
                        state.hoverFraction = fraction
                    }
                    .onEnded { value in
                        state.isDragging = false
                        let fraction = min(max(value.location.x / width, 0.0), 1.0)
                        onSeek(Double(fraction) * duration)
                        state.hoverFraction = nil
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    state.isHovering = true
                    state.hoverFraction = min(max(location.x / width, 0.0), 1.0)
                case .ended:
                    state.isHovering = false
                    state.hoverFraction = nil
                }
            }
        }
        .frame(height: 28)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
