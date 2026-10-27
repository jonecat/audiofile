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
            .help(tooltipText)
    }

    public var tooltipText: String {
        Self.formatDescription(for: format, isLossless: isLossless)
    }

    public static func formatDescription(for format: String, isLossless: Bool) -> String {
        let f = format.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch f {
        case "FLAC":
            return """
            Format: FLAC (Free Lossless Audio Codec)
            Type: Lossless Compression (Bit-Perfect)
            Open-source lossless audio codec that preserves 100% of the original studio recording data with zero quality loss.
            """
        case "ALAC":
            return """
            Format: ALAC (Apple Lossless Audio Codec)
            Type: Lossless Compression (Bit-Perfect)
            Apple's lossless audio compression format packaged in an MPEG-4 container (.m4a), bit-for-bit identical to the master.
            """
        case "WAV", "WAVE":
            return """
            Format: WAV (Waveform Audio File Format)
            Type: Uncompressed Linear PCM
            Industry-standard uncompressed digital PCM audio with maximum fidelity and zero compression artifacts.
            """
        case "AIFF", "AIF":
            return """
            Format: AIFF (Audio Interchange File Format)
            Type: Uncompressed Linear PCM
            Apple's uncompressed digital PCM audio format with native support for embedded metadata and album art.
            """
        case "DSD", "DSF", "DFF":
            return """
            Format: DSD (Direct Stream Digital)
            Type: 1-Bit Pulse Density Modulation (SACD)
            Ultra-high resolution 1-bit audio sampling at MHz frequencies (e.g. 2.82 MHz / 5.64 MHz) for pristine analog-like micro-dynamics.
            """
        case "APE":
            return """
            Format: APE (Monkey's Audio)
            Type: Lossless Compression (Bit-Perfect)
            High-compression bit-perfect lossless audio format.
            """
        case "M4A":
            if isLossless {
                return """
                Format: ALAC / Lossless M4A (Apple Lossless)
                Type: Lossless Compression (Bit-Perfect)
                Bit-perfect studio audio stored in an MPEG-4 audio container (.m4a).
                """
            } else {
                return """
                Format: AAC / M4A (Advanced Audio Coding)
                Type: Perceptual Lossy Compression
                Standard MPEG-4 AAC audio delivering high fidelity at efficient file sizes.
                """
            }
        case "AAC":
            return """
            Format: AAC (Advanced Audio Coding)
            Type: Perceptual Lossy Compression
            Efficient lossy audio compression format delivering high perceived fidelity.
            """
        case "MP3":
            return """
            Format: MP3 (MPEG-1 Audio Layer III)
            Type: Perceptual Lossy Compression
            Ubiquitous lossy audio format using psychoacoustic perceptual coding.
            """
        case "CAF":
            return """
            Format: CAF (Apple Core Audio Format)
            Type: 64-Bit High-Resolution Container
            Flexible Apple audio container capable of storing uncompressed or lossless audio without 4GB file size limits.
            """
        default:
            return """
            Format: \(f)
            Type: \(isLossless ? "Lossless Audio (Bit-Perfect)" : "Compressed Audio")
            """
        }
    }
}
