import SwiftUI

public struct DualVUMeterView: View {
    public let left: Float
    public let right: Float
    public let leftPeak: Bool
    public let rightPeak: Bool
    public let stacked: Bool

    public init(left: Float, right: Float, leftPeak: Bool, rightPeak: Bool, stacked: Bool = false) {
        self.left = left
        self.right = right
        self.leftPeak = leftPeak
        self.rightPeak = rightPeak
        self.stacked = stacked
    }

    public var body: some View {
        Group {
            if stacked {
                VStack(spacing: 16) {
                    SingleVUMeter(channel: "LEFT", deflection: CGFloat(left), isPeak: leftPeak)
                    SingleVUMeter(channel: "RIGHT", deflection: CGFloat(right), isPeak: rightPeak)
                }
            } else {
                HStack(spacing: 14) {
                    SingleVUMeter(channel: "LEFT", deflection: CGFloat(left), isPeak: leftPeak)
                    SingleVUMeter(channel: "RIGHT", deflection: CGFloat(right), isPeak: rightPeak)
                }
            }
        }
        .frame(minHeight: 80)
    }
}

private struct SingleVUMeter: View {
    let channel: String
    let deflection: CGFloat
    let isPeak: Bool

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard w > 20, h > 20 else { return }

            let uiScale = max(1.0, min(w, h) / 180.0)
            let meterRect = CGRect(origin: .zero, size: size)
            let meterCorner: CGFloat = 10.0 * min(uiScale, 2.0)

            // 1. Vintage Faceplate Background
            let bgPath = Path(roundedRect: meterRect, cornerRadius: meterCorner)
            let bgGradient = Gradient(colors: [
                Color(red: 0.11, green: 0.12, blue: 0.13),
                Color(red: 0.07, green: 0.08, blue: 0.09)
            ])
            context.fill(bgPath, with: .linearGradient(bgGradient, startPoint: CGPoint(x: w/2, y: 0), endPoint: CGPoint(x: w/2, y: h)))

            // Subtle warm ambient lamp glow from the top
            let lampGradient = Gradient(colors: [
                Color.orange.opacity(0.12),
                Color.yellow.opacity(0.04),
                Color.clear
            ])
            context.fill(bgPath, with: .radialGradient(lampGradient, center: CGPoint(x: w/2, y: 10 * uiScale), startRadius: 5, endRadius: max(w, h) * 0.75))

            // Faceplate border
            context.stroke(bgPath, with: .color(Color.white.opacity(0.12)), lineWidth: min(uiScale, 1.8))

            // Geometry of Arc & Pivot
            let pivot = CGPoint(x: w / 2, y: h * 0.98)
            let needleRadius = h * 0.82
            let arcRadius = h * 0.72

            let minAngleDeg: CGFloat = -44.0
            let maxAngleDeg: CGFloat = 44.0

            // Function to map deflection (0..1) to angle in radians (0 rad = straight up)
            func angleForDeflection(_ def: CGFloat) -> CGFloat {
                let clamped = min(max(def, 0.0), 1.15)
                let deg = minAngleDeg + clamped * (maxAngleDeg - minAngleDeg)
                return (deg - 90.0) * .pi / 180.0
            }

            // 2. Draw Arc Tracks
            // Normal range: 0.0 to 0.75 (black/white)
            // Overload range: 0.75 to 1.0 (red)
            let zeroAngle = angleForDeflection(0.75)
            let startAngle = angleForDeflection(0.0)
            let endAngle = angleForDeflection(1.0)

            var normalArc = Path()
            normalArc.addArc(center: pivot, radius: arcRadius, startAngle: Angle(radians: Double(startAngle)), endAngle: Angle(radians: Double(zeroAngle)), clockwise: false)
            context.stroke(normalArc, with: .color(Color.white.opacity(0.4)), lineWidth: 2.0 * uiScale)

            var redArc = Path()
            redArc.addArc(center: pivot, radius: arcRadius, startAngle: Angle(radians: Double(zeroAngle)), endAngle: Angle(radians: Double(endAngle)), clockwise: false)
            context.stroke(redArc, with: .color(Color.red.opacity(0.85)), lineWidth: 2.5 * uiScale)

            // 3. Scale Ticks & Decibel Labels
            let ticks: [(def: CGFloat, label: String, isRed: Bool)] = [
                (0.00, "-20", false),
                (0.24, "-10", false),
                (0.42, "-7", false),
                (0.55, "-5", false),
                (0.66, "-3", false),
                (0.75, "0", true),
                (0.85, "+1", true),
                (0.93, "+2", true),
                (1.00, "+3", true)
            ]

            let isCompact = h < 95
            for tick in ticks {
                let a = angleForDeflection(tick.def)
                let cosA = cos(a)
                let sinA = sin(a)

                let innerR = arcRadius - (tick.isRed ? 7 : 5) * uiScale
                let outerR = arcRadius + 1 * uiScale

                var tickPath = Path()
                tickPath.move(to: CGPoint(x: pivot.x + innerR * cosA, y: pivot.y + innerR * sinA))
                tickPath.addLine(to: CGPoint(x: pivot.x + outerR * cosA, y: pivot.y + outerR * sinA))

                let tickColor = tick.isRed ? Color.red.opacity(0.9) : Color.white.opacity(0.65)
                context.stroke(tickPath, with: .color(tickColor), lineWidth: (tick.def == 0.75 ? 2.0 : 1.2) * uiScale)

                // Draw Text Label if not ultra compact
                if !isCompact {
                    let textR = arcRadius - 16 * uiScale
                    let textPoint = CGPoint(x: pivot.x + textR * cosA, y: pivot.y + textR * sinA)
                    let text = Text(tick.label)
                        .font(.system(size: 8 * uiScale, weight: tick.isRed ? .bold : .medium, design: .monospaced))
                        .foregroundColor(tick.isRed ? Color.red : Color.secondary)
                    context.draw(context.resolve(text), at: textPoint, anchor: .center)
                }
            }

            // 4. Center Labels ("VU" and Channel name)
            let vuLabel = Text("VU")
                .font(.system(size: isCompact ? 10 : 13 * uiScale, weight: .black, design: .serif))
                .foregroundColor(Color.white.opacity(0.35))
            context.draw(context.resolve(vuLabel), at: CGPoint(x: w / 2, y: h * 0.45), anchor: .center)

            let chLabel = Text(channel)
                .font(.system(size: 9 * uiScale, weight: .bold, design: .monospaced))
                .foregroundColor(Color.accentColor.opacity(0.75))
            context.draw(context.resolve(chLabel), at: CGPoint(x: w / 2, y: h * 0.62), anchor: .center)

            // 5. Draw Overload / PEAK LED (Top Right)
            let ledInset = 16 * uiScale
            let ledCenter = CGPoint(x: w - ledInset, y: ledInset)
            let ledRadius: CGFloat = 4.0 * uiScale
            let ledBezelPath = Path(ellipseIn: CGRect(x: ledCenter.x - ledRadius - 1 * uiScale, y: ledCenter.y - ledRadius - 1 * uiScale, width: (ledRadius + 1 * uiScale) * 2, height: (ledRadius + 1 * uiScale) * 2))
            context.stroke(ledBezelPath, with: .color(Color.white.opacity(0.2)), lineWidth: 1.0 * uiScale)

            let ledPath = Path(ellipseIn: CGRect(x: ledCenter.x - ledRadius, y: ledCenter.y - ledRadius, width: ledRadius * 2, height: ledRadius * 2))
            if isPeak {
                // Bright glowing crimson LED
                context.fill(ledPath, with: .color(Color.red))
                let glowRadius = 9 * uiScale
                let glowPath = Path(ellipseIn: CGRect(x: ledCenter.x - glowRadius, y: ledCenter.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2))
                context.fill(glowPath, with: .radialGradient(
                    Gradient(colors: [Color.red.opacity(0.6), Color.clear]),
                    center: ledCenter,
                    startRadius: 2 * uiScale,
                    endRadius: glowRadius
                ))
            } else {
                // Extinguished dark red LED
                context.fill(ledPath, with: .color(Color(red: 0.25, green: 0.05, blue: 0.05)))
            }

            // 6. Draw Analog Needle
            let needleAngle = angleForDeflection(deflection)
            let nCos = cos(needleAngle)
            let nSin = sin(needleAngle)

            let needleTip = CGPoint(x: pivot.x + needleRadius * nCos, y: pivot.y + needleRadius * nSin)

            // Soft shadow slightly offset
            var shadowPath = Path()
            shadowPath.move(to: CGPoint(x: pivot.x + 2 * uiScale, y: pivot.y + 2 * uiScale))
            shadowPath.addLine(to: CGPoint(x: needleTip.x + 2 * uiScale, y: needleTip.y + 2 * uiScale))
            context.stroke(shadowPath, with: .color(Color.black.opacity(0.35)), lineWidth: 2.0 * uiScale)

            // Main needle line
            var needlePath = Path()
            needlePath.move(to: pivot)
            needlePath.addLine(to: needleTip)

            let needleColor = (deflection > 0.75) ? Color.red : Color(red: 0.95, green: 0.35, blue: 0.2)
            context.stroke(needlePath, with: .color(needleColor), style: StrokeStyle(lineWidth: 1.8 * uiScale, lineCap: .round))

            // Pivot cap (the metal screw housing at the base)
            let capRadius: CGFloat = 7.0 * uiScale
            let capPath = Path(ellipseIn: CGRect(x: pivot.x - capRadius, y: pivot.y - capRadius, width: capRadius * 2, height: capRadius * 2))
            context.fill(capPath, with: .color(Color(white: 0.18)))
            context.stroke(capPath, with: .color(Color.white.opacity(0.3)), lineWidth: 1.0 * uiScale)
        }
    }
}
