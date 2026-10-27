import SwiftUI

public struct DynamicRangeBadgeView: View {
    public let state: DynamicRangeState
    public let compact: Bool
    public let onAction: (() -> Void)?

    public init(
        state: DynamicRangeState,
        compact: Bool = false,
        onAction: (() -> Void)? = nil
    ) {
        self.state = state
        self.compact = compact
        self.onAction = onAction
    }

    public var body: some View {
        if onAction != nil, case .calculating = state {
            content
                .help(tooltipText)
        } else if let action = onAction {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
            .help(tooltipText)
        } else {
            content
                .help(tooltipText)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .ready(let result):
            HStack(spacing: 3) {
                Text(compact ? "DR\(result.score)" : "DR \(result.score)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, 2)
            .glassEffect(
                .regular.tint(result.ratingCategory.color.opacity(0.85)),
                in: .capsule
            )

        case .calculating:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 10, height: 10)
                Text(compact ? "DR…" : "DR …")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)

        case .idle:
            HStack(spacing: 3) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 8, weight: .bold))
                Text("DR")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)

        case .failed:
            Text("DR —")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .padding(.horizontal, compact ? 6 : 7)
                .padding(.vertical, 2)
                .glassEffect(.clear, in: .capsule)
        }
    }

    private var tooltipText: String {
        switch state {
        case .ready(let result):
            return result.tooltipText
        case .calculating:
            return """
            Dynamic Range: Measuring…
            Analyzing audio stream (Peak vs RMS energy on demand).
            """
        case .idle:
            return """
            Dynamic Range: Not Measured Yet
            Click to measure Dynamic Range on demand (Pleasurize Music Foundation standard).
            """
        case .failed(let msg):
            return """
            Dynamic Range: Measurement Unavailable
            Could not read stream: \(msg)
            Click to retry.
            """
        }
    }
}
