import SwiftUI

public struct DualVUMeterView: View {
    public let left: Float
    public let right: Float
    public let leftPeak: Bool
    public let rightPeak: Bool

    public init(left: Float, right: Float, leftPeak: Bool, rightPeak: Bool) {
        self.left = left
        self.right = right
        self.leftPeak = leftPeak
        self.rightPeak = rightPeak
    }

    public var body: some View {
        HStack(spacing: 12) {
            SingleVUMeter(channel: "LEFT", deflection: CGFloat(left), isPeak: leftPeak)
            SingleVUMeter(channel: "RIGHT", deflection: CGFloat(right), isPeak: rightPeak)
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

            let meterRect = CGRect(origin: .zero, size: size)
            let meterCorner: CGFloat = 10.0

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
            context.fill(bgPath, with: .radialGradient(lampGradient, center: CGPoint(x: w/2, y: 10), startRadius: 5, endRadius: max(w, h) * 0.75))

            // Faceplate border
            context.stroke(bgPath, with: .color(Color.white.opacity(0.12)), lineWidth: 1.0)

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
            context.stroke(normalArc, with: .color(Color.white.opacity(0.4)), lineWidth: 2.0)

            var redArc = Path()
            redArc.addArc(center: pivot, radius: arcRadius, startAngle: Angle(radians: Double(zeroAngle)), endAngle: Angle(radians: Double(endAngle)), clockwise: false)
            context.stroke(redArc, with: .color(Color.red.opacity(0.85)), lineWidth: 2.5)

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

                let innerR = arcRadius - (tick.isRed ? 7 : 5)
                let outerR = arcRadius + 1

                var tickPath = Path()
                tickPath.move(to: CGPoint(x: pivot.x + innerR * cosA, y: pivot.y + innerR * sinA))
                tickPath.addLine(to: CGPoint(x: pivot.x + outerR * cosA, y: pivot.y + outerR * sinA))

                let tickColor = tick.isRed ? Color.red.opacity(0.9) : Color.white.opacity(0.65)
                context.stroke(tickPath, with: .color(tickColor), lineWidth: tick.def == 0.75 ? 2.0 : 1.2)

                // Draw Text Label if not ultra compact
                if !isCompact {
                    let textR = arcRadius - 16
                    let textPoint = CGPoint(x: pivot.x + textR * cosA, y: pivot.y + textR * sinA)
                    let text = Text(tick.label)
                        .font(.system(size: 8, weight: tick.isRed ? .bold : .medium, design: .monospaced))
                        .foregroundColor(tick.isRed ? Color.red : Color.secondary)
                    context.draw(context.resolve(text), at: textPoint, anchor: .center)
                }
            }

            // 4. Center Labels ("VU" and Channel name)
            let vuLabel = Text("VU")
                .font(.system(size: isCompact ? 10 : 13, weight: .black, design: .serif))
                .foregroundColor(Color.white.opacity(0.35))
            context.draw(context.resolve(vuLabel), at: CGPoint(x: w / 2, y: h * 0.45), anchor: .center)

            let chLabel = Text(channel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.accentColor.opacity(0.75))
            context.draw(context.resolve(chLabel), at: CGPoint(x: w / 2, y: h * 0.62), anchor: .center)

            // 5. Draw Overload / PEAK LED (Top Right)
            let ledCenter = CGPoint(x: w - 16, y: 16)
            let ledRadius: CGFloat = 4.0
            let ledBezelPath = Path(ellipseIn: CGRect(x: ledCenter.x - ledRadius - 1, y: ledCenter.y - ledRadius - 1, width: (ledRadius + 1) * 2, height: (ledRadius + 1) * 2))
            context.stroke(ledBezelPath, with: .color(Color.white.opacity(0.2)), lineWidth: 1.0)

            let ledPath = Path(ellipseIn: CGRect(x: ledCenter.x - ledRadius, y: ledCenter.y - ledRadius, width: ledRadius * 2, height: ledRadius * 2))
            if isPeak {
                // Bright glowing crimson LED
                context.fill(ledPath, with: .color(Color.red))
                let glowPath = Path(ellipseIn: CGRect(x: ledCenter.x - 9, y: ledCenter.y - 9, width: 18, height: 18))
                context.fill(glowPath, with: .radialGradient(
                    Gradient(colors: [Color.red.opacity(0.6), Color.clear]),
                    center: ledCenter,
                    startRadius: 2,
                    endRadius: 9
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
            shadowPath.move(to: CGPoint(x: pivot.x + 2, y: pivot.y + 2))
            shadowPath.addLine(to: CGPoint(x: needleTip.x + 2, y: needleTip.y + 2))
            context.stroke(shadowPath, with: .color(Color.black.opacity(0.35)), lineWidth: 2.0)

            // Main needle line
            var needlePath = Path()
            needlePath.move(to: pivot)
            needlePath.addLine(to: needleTip)

            let needleColor = (deflection > 0.75) ? Color.red : Color(red: 0.95, green: 0.35, blue: 0.2)
            context.stroke(needlePath, with: .color(needleColor), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

            // Pivot cap (the metal screw housing at the base)
            let capRadius: CGFloat = 7.0
            let capPath = Path(ellipseIn: CGRect(x: pivot.x - capRadius, y: pivot.y - capRadius, width: capRadius * 2, height: capRadius * 2))
            context.fill(capPath, with: .color(Color(white: 0.18)))
            context.stroke(capPath, with: .color(Color.white.opacity(0.3)), lineWidth: 1.0)
        }
    }
}
