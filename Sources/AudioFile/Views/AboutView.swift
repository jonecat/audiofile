import SwiftUI

public struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        VStack(spacing: 16) {
            // App Icon & Title
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 64, height: 64)
                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 4) {
                Text("AudioFile")
                    .font(.title.weight(.bold))
                Text("Native Audiophile Music Player for macOS")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Version \(AppUpdater.shared.currentVersion)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("Pure Swift, SwiftUI & Accelerate vDSP", systemImage: "bolt.fill")
                Label("Lossless Gapless Playback (FLAC, ALAC, WAV, AIFF, APE, DSD, M4A, MP3)", systemImage: "sparkles")
                Label("LRCLIB Synchronized 3-Line Lyrics Engine", systemImage: "quote.bubble.fill")
                Label("Real-Time 64-Band FFT Spectrum Analyzer", systemImage: "waveform.path")
                Label("Native macOS Media Keys & Control Center", systemImage: "macwindow")
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)

            Divider()

            HStack {
                Text("Created by Jon Lawrence")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/jonecat/audiofile")!)
                    .font(.caption)
                    .help("Open AudioFile repository on GitHub")
            }

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .controlSize(.regular)
            .help("Close About window")
        }
        .padding(24)
        .frame(width: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
