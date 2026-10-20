import SwiftUI

public struct FormatBadgeView: View {
    public let format: String
    public let isLossless: Bool
    public let isHighlighted: Bool

    public init(format: String, isLossless: Bool = false, isHighlighted: Bool = false) {
        self.format = format
        self.isLossless = isLossless
        self.isHighlighted = isHighlighted
    }

    public var body: some View {
        Text(format.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(isHighlighted || isLossless ? Color.white : Color.primary.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .glassEffect(
                isHighlighted
                    ? .clear
                    : (isLossless ? .regular.tint(Color.accentColor) : .regular),
                in: .capsule
            )
    }
}
