import SwiftUI

public struct LyricsCardView: View {
    public let status: LyricsStatus
    public let window: LyricsWindow
    @Binding public var scale: Double

    public init(status: LyricsStatus, window: LyricsWindow, scale: Binding<Double>) {
        self.status = status
        self.window = window
        self._scale = scale
    }

    private var cgScale: CGFloat {
        CGFloat(min(max(scale, 0.85), 2.8))
    }

    public var body: some View {
        let s = cgScale
        let outerFontSize: CGFloat = 11.0 * s
        let innerFontSize: CGFloat = 12.5 * s
        let activeFontSize: CGFloat = 15.0 * s

        let outerRowHeight: CGFloat = 16.0 * s
        let innerRowHeight: CGFloat = 19.0 * s
        let activeRowHeight: CGFloat = 24.0 * s
        let lineSpacing: CGFloat = 5.0 * s

        VStack(alignment: .leading, spacing: 6) {
            // Header outside card (matches Spectrum Analyzer & Waveform headers)
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

                if case .found = status {
                    Text("LRCLIB")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                }
            }

            // 5-Line Synchronized Presentation Card
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
        .fixedSize(horizontal: false, vertical: true)
    }
}
