import SwiftUI

public struct LyricsCardView: View {
    public let status: LyricsStatus
    public let window: LyricsWindow
    @Binding public var scale: Double
    public let isExpanded: Bool
    public var onSeek: ((TimeInterval) -> Void)? = nil

    public init(
        status: LyricsStatus,
        window: LyricsWindow,
        scale: Binding<Double>,
        isExpanded: Bool = false,
        onSeek: ((TimeInterval) -> Void)? = nil
    ) {
        self.status = status
        self.window = window
        self._scale = scale
        self.isExpanded = isExpanded
        self.onSeek = onSeek
    }

    private var cgScale: CGFloat {
        CGFloat(min(max(scale, 0.85), 2.8))
    }

    public var body: some View {
        let s = cgScale

        VStack(alignment: .leading, spacing: 6) {
            // Header outside card (matches Visualizer header style)
            HStack(spacing: 10) {
                Label("Lyrics", systemImage: "music.note.list")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                // Text Size Slider
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    Slider(value: $scale, in: 0.85...2.8)
                        .tint(Color.accentColor)
                        .frame(width: 110)
                        .controlSize(.mini)

                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .help("Adjust lyrics text and card size")
            }

            // Presentation Area: switches between 5-Line Compact vs Full Dynamic Scroll
            if isExpanded {
                expandedLyricsView(scale: s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                compactLyricsView(scale: s)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : nil)
    }

    // MARK: - Compact 5-Line Presentation (When Visualizer is Active)

    @ViewBuilder
    private func compactLyricsView(scale s: CGFloat) -> some View {
        let outerFontSize: CGFloat = 11.0 * s
        let innerFontSize: CGFloat = 12.5 * s
        let activeFontSize: CGFloat = 15.0 * s

        let outerRowHeight: CGFloat = 16.0 * s
        let innerRowHeight: CGFloat = 19.0 * s
        let activeRowHeight: CGFloat = 24.0 * s
        let lineSpacing: CGFloat = 5.0 * s

        VStack(spacing: lineSpacing) {
            switch status {
            case .idle:
                Text("Ready")
                    .font(.system(size: 13 * s))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64 * s)

            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching lyrics from LRCLIB...")
                        .font(.system(size: 12 * s, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                .frame(maxWidth: .infinity, minHeight: 64 * s)

            case .instrumental:
                Text("♪   Instrumental Track   ♪")
                    .font(.system(size: 13 * s, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 64 * s)

            case .notFound:
                Text("○   No lyrics available   ○")
                    .font(.system(size: 13 * s))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64 * s)

            case .found:
                // Row 0: 2 lines before
                Text(window.prev2?.text ?? " ")
                    .font(.system(size: outerFontSize))
                    .foregroundColor(.secondary.opacity(0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(height: outerRowHeight)

                // Row 1: 1 line before
                Text(window.prev1?.text ?? " ")
                    .font(.system(size: innerFontSize))
                    .foregroundColor(.secondary.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(height: innerRowHeight)

                // Row 2: Current active line
                if window.isInstrumentalGap {
                    HStack(spacing: 6) {
                        Text("♪   Instrumental Break   ♪")
                            .font(.system(size: activeFontSize, weight: .bold))
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(height: activeRowHeight)
                } else if let curr = window.curr, !curr.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                            .font(.system(size: 11 * s, weight: .bold))
                            .foregroundColor(.accentColor)
                        Text(curr.text)
                            .font(.system(size: activeFontSize, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(height: activeRowHeight)
                } else {
                    Text("♪")
                        .font(.system(size: activeFontSize, weight: .bold))
                        .foregroundColor(.accentColor)
                        .frame(height: activeRowHeight)
                }

                // Row 3: 1 line after
                Text(window.next1?.text ?? " ")
                    .font(.system(size: innerFontSize))
                    .foregroundColor(.secondary.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(height: innerRowHeight)

                // Row 4: 2 lines after
                Text(window.next2?.text ?? " ")
                    .font(.system(size: outerFontSize))
                    .foregroundColor(.secondary.opacity(0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(height: outerRowHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14 + (s - 1.0) * 4.0)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.2), value: window.curr?.timestamp)
    }

    // MARK: - Dynamic Full-Height Presentation (When Visualizer is Off)

    @ViewBuilder
    private func expandedLyricsView(scale s: CGFloat) -> some View {
        ZStack {
            switch status {
            case .idle:
                Text("Ready")
                    .font(.system(size: 14 * s))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Fetching lyrics from LRCLIB...")
                        .font(.system(size: 13 * s, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .instrumental:
                VStack(spacing: 8) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 32 * s))
                        .foregroundColor(.accentColor)
                    Text("Instrumental Track")
                        .font(.system(size: 15 * s, weight: .bold))
                        .foregroundColor(.primary)
                    Text("No vocal lyrics present for this recording")
                        .font(.system(size: 12 * s))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .notFound:
                VStack(spacing: 8) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 28 * s))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text("No Synchronized Lyrics Found")
                        .font(.system(size: 14 * s, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .found(let synced):
                let lines = synced.lines
                let currentTimestamp = window.curr?.timestamp
                let activeIndex = lines.firstIndex(where: { $0.timestamp == currentTimestamp }) ?? 0

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 10.0 * s) {
                            // Top breathing space so the first line can center comfortably
                            Spacer().frame(height: 90.0 * s)

                            ForEach(Array(lines.enumerated()), id: \.element.timestamp) { index, line in
                                let isActive = (line.timestamp == currentTimestamp)
                                let distance = abs(index - activeIndex)

                                ExpandedLyricRowView(
                                    line: line,
                                    isActive: isActive,
                                    distance: distance,
                                    scale: s,
                                    onSeek: {
                                        onSeek?(line.timestamp)
                                    }
                                )
                                .id(line.timestamp)
                            }

                            // Bottom breathing space so the final line can center comfortably
                            Spacer().frame(height: 90.0 * s)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                    }
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.09),
                                .init(color: .black, location: 0.91),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .onChange(of: currentTimestamp) { _, newTs in
                        if let newTs = newTs {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(newTs, anchor: .center)
                            }
                        }
                    }
                    .onAppear {
                        if let curr = currentTimestamp {
                            proxy.scrollTo(curr, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

// MARK: - Expanded Lyric Row Component

private struct ExpandedLyricRowView: View {
    let line: LRCLine
    let isActive: Bool
    let distance: Int
    let scale: CGFloat
    let onSeek: (() -> Void)?

    var body: some View {
        Button {
            onSeek?()
        } label: {
            HStack(spacing: 8) {
                if isActive {
                    Image(systemName: "music.note")
                        .font(.system(size: 12 * scale, weight: .bold))
                        .foregroundColor(.accentColor)
                }

                Text(line.isInstrumental ? "♪   Instrumental Break   ♪" : line.text)
                    .font(.system(
                        size: fontSize,
                        weight: isActive ? .bold : (distance <= 1 ? .semibold : .medium)
                    ))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isActive ? 8 * scale : 4 * scale)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.14))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Click to jump playback to \(line.formattedTimestamp)")
    }

    private var fontSize: CGFloat {
        if isActive {
            return 16.5 * scale
        } else if distance <= 1 {
            return 13.5 * scale
        } else if distance <= 3 {
            return 12.0 * scale
        } else {
            return 11.0 * scale
        }
    }

    private var textColor: Color {
        if line.isInstrumental {
            return Color.accentColor.opacity(isActive ? 1.0 : 0.45)
        }
        if isActive {
            return Color.primary
        }
        if distance <= 1 {
            return Color.secondary.opacity(0.85)
        } else if distance <= 3 {
            return Color.secondary.opacity(0.55)
        } else {
            return Color.secondary.opacity(0.32)
        }
    }
}
