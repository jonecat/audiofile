import SwiftUI

public struct SpectrumBarView: View {
    public let bands: [Float]
    public let peaks: [Float]

    public init(bands: [Float], peaks: [Float]) {
        self.bands = bands
        self.peaks = peaks
    }

    public var body: some View {
        Canvas { context, size in
            let count = bands.count
            guard count > 0 else { return }

            let totalWidth = size.width
            let totalHeight = size.height

            let barSpacing: CGFloat = 2.0
            let availableWidth = totalWidth - (CGFloat(count - 1) * barSpacing)
            let barWidth = max(1.0, availableWidth / CGFloat(count))

            for i in 0..<count {
                let x = CGFloat(i) * (barWidth + barSpacing)
                let val = CGFloat(bands[i])
                let peak = CGFloat(peaks[i])

                let barHeight = max(2.0, val * (totalHeight - 4.0))
                let y = totalHeight - barHeight

                // Draw main spectrum bar
                let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = Path(roundedRect: barRect, cornerRadius: min(2.0, barWidth / 2))

                let gradient = Gradient(colors: [
                    Color.accentColor,
                    Color.accentColor.opacity(0.75),
                    Color.accentColor.opacity(0.4)
                ])
                let shader = GraphicsContext.Shading.linearGradient(
                    gradient,
                    startPoint: CGPoint(x: x, y: y),
                    endPoint: CGPoint(x: x, y: totalHeight)
                )
                context.fill(path, with: shader)

                // Draw floating peak marker cap
                if peak > 0.02 {
                    let peakY = max(0.0, totalHeight - (peak * (totalHeight - 4.0)) - 3.0)
                    let peakRect = CGRect(x: x, y: peakY, width: barWidth, height: 2.0)
                    let peakPath = Path(roundedRect: peakRect, cornerRadius: 1.0)
                    context.fill(peakPath, with: .color(Color.white.opacity(0.85)))
                }
            }
        }
        .frame(minHeight: 48)
    }
}
