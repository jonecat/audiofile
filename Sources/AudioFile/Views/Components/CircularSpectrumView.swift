import SwiftUI

public struct CircularSpectrumView: View {
    public let bands: [Float]
    public let peaks: [Float]

    public init(bands: [Float], peaks: [Float]) {
        self.bands = bands
        self.peaks = peaks
    }

    public var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard w > 20, h > 20 else { return }

            let center = CGPoint(x: w / 2, y: h / 2)
            let maxRadius = min(w, h) / 2.0 - 6.0
            guard maxRadius > 25 else { return }

            let innerRadius: CGFloat = maxRadius * 0.38
            let barArea = maxRadius - innerRadius

            // Compute sub-bass pulse factor for inner core
            var bassSum: Float = 0
            let bassCount = min(bands.count, 6)
            for i in 0..<bassCount { bassSum += bands[i] }
            let bassFactor = CGFloat(bassCount > 0 ? (bassSum / Float(bassCount)) : 0)

            // 1. Draw Pulsing Inner Core
            let coreRadius = innerRadius * (0.82 + bassFactor * 0.25)
            let corePath = Path(ellipseIn: CGRect(
                x: center.x - coreRadius,
                y: center.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            ))

            let coreGradient = Gradient(colors: [
                Color.accentColor.opacity(0.35 + Double(bassFactor) * 0.45),
                Color.accentColor.opacity(0.12),
                Color.clear
            ])
            context.fill(corePath, with: .radialGradient(
                coreGradient,
                center: center,
                startRadius: 2,
                endRadius: coreRadius
            ))

            // Inner boundary circle
            let ringPath = Path(ellipseIn: CGRect(
                x: center.x - innerRadius,
                y: center.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            ))
            context.stroke(ringPath, with: .color(Color.accentColor.opacity(0.35)), lineWidth: 1.2)

            // 2. Draw 64 Radial Bars in Symmetrical Dual Arcs
            // Left half & Right half mirror:
            // Angle goes from bottom (pi/2) upwards to top (-pi/2)
            let totalBands = bands.count
            guard totalBands > 0 else { return }

            let halfCount = min(32, totalBands)
            let stepAngle = (CGFloat.pi) / CGFloat(halfCount)

            for i in 0..<halfCount {
                let val = CGFloat(bands[i])
                let peak = CGFloat(peaks[i])

                let barLength = max(2.0, val * barArea)
                let peakLength = max(2.0, peak * barArea)

                // Right side angle (bottom to top: +pi/2 to -pi/2)
                let angleRight = (CGFloat.pi / 2.0) - (CGFloat(i) * stepAngle)
                // Left side angle (bottom to top: +pi/2 to 3pi/2)
                let angleLeft = (CGFloat.pi / 2.0) + (CGFloat(i) * stepAngle)

                drawRadialBar(
                    context: &context,
                    center: center,
                    angle: angleRight,
                    innerR: innerRadius,
                    length: barLength,
                    peakLength: peakLength
                )

                if i > 0 && i < halfCount {
                    drawRadialBar(
                        context: &context,
                        center: center,
                        angle: angleLeft,
                        innerR: innerRadius,
                        length: barLength,
                        peakLength: peakLength
                    )
                }
            }
        }
        .frame(minHeight: 60)
    }

    private func drawRadialBar(
        context: inout GraphicsContext,
        center: CGPoint,
        angle: CGFloat,
        innerR: CGFloat,
        length: CGFloat,
        peakLength: CGFloat
    ) {
        let cosA = cos(angle)
        let sinA = sin(angle)

        let startPoint = CGPoint(x: center.x + innerR * cosA, y: center.y + innerR * sinA)
        let endPoint = CGPoint(x: center.x + (innerR + length) * cosA, y: center.y + (innerR + length) * sinA)

        // Radial Bar Line
        var barPath = Path()
        barPath.move(to: startPoint)
        barPath.addLine(to: endPoint)

        let shader = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color.accentColor.opacity(0.4), Color.accentColor]),
            startPoint: startPoint,
            endPoint: endPoint
        )
        context.stroke(barPath, with: shader, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

        // Floating Peak Dot
        if peakLength > length + 2.0 {
            let peakPoint = CGPoint(x: center.x + (innerR + peakLength) * cosA, y: center.y + (innerR + peakLength) * sinA)
            let dotRect = CGRect(x: peakPoint.x - 1.25, y: peakPoint.y - 1.25, width: 2.5, height: 2.5)
            context.fill(Path(ellipseIn: dotRect), with: .color(Color.white.opacity(0.85)))
        }
    }
}
