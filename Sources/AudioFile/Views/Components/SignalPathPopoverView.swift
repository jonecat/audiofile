import SwiftUI

/// Roon-style inspection popover showing every step from source file decoding to hardware DAC output.
public struct SignalPathPopoverView: View {
    @ObservedObject public var vm: PlayerViewModel
    @ObservedObject public var audio: AudioEngine

    public init(vm: PlayerViewModel, audio: AudioEngine) {
        self.vm = vm
        self.audio = audio
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerView

            Divider()

            if let track = audio.currentTrack {
                VStack(alignment: .leading, spacing: 0) {
                    stageRow(
                        color: track.isLossless ? .green : .orange,
                        title: "Source",
                        detail: sourceDetail(for: track),
                        subtitle: track.isCueTrack ? "Timestamp-sliced .cue Virtual Track" : track.path.lastPathComponent,
                        showConnector: true
                    )

                    let srcRate = track.sampleRate ?? audio.hardwareSampleRate
                    let rateMatches = abs(srcRate - audio.hardwareSampleRate) < 1.0
                    stageRow(
                        color: rateMatches ? .green : .orange,
                        title: "Sample Rate",
                        detail: rateMatches
                            ? "Native \(formatRate(srcRate)) → \(formatRate(audio.hardwareSampleRate))"
                            : "Resampled \(formatRate(srcRate)) → \(formatRate(audio.hardwareSampleRate))",
                        subtitle: vm.config.autoSampleRateSwitching
                            ? "Auto Sample-Rate Switching enabled"
                            : "System mixer rate locked (enable Auto Switching in Audio Settings)",
                        showConnector: true
                    )

                    if vm.config.replayGainMode != .off {
                        stageRow(
                            color: .cyan,
                            title: "ReplayGain (\(vm.config.replayGainMode.rawValue))",
                            detail: String(format: "%+.1f dB (Preamp %+.1f dB)", audio.activeReplayGainDb, vm.config.replayGainPreampDb),
                            subtitle: "Peak-protected float headroom scaling",
                            showConnector: true
                        )
                    } else {
                        stageRow(
                            color: .secondary,
                            title: "ReplayGain",
                            detail: "Bypassed (Off)",
                            subtitle: nil,
                            showConnector: true
                        )
                    }

                    if vm.config.eqEnabled {
                        stageRow(
                            color: .cyan,
                            title: "10-Band Parametric EQ",
                            detail: "\(vm.config.eqPresetName) • Preamp \(String(format: "%+.1f", vm.config.eqPreampDb)) dB",
                            subtitle: "64-bit internal AVAudioUnitEQ processing",
                            showConnector: true
                        )
                    } else {
                        stageRow(
                            color: .green,
                            title: "10-Band Parametric EQ",
                            detail: "Bit-Perfect Bypass",
                            subtitle: nil,
                            showConnector: true
                        )
                    }

                    if vm.config.crossfeedEnabled {
                        stageRow(
                            color: .cyan,
                            title: "Headphone Crossfeed",
                            detail: "BS2B Acoustic Feed • \(Int((vm.config.crossfeedLevel * 100).rounded()))%",
                            subtitle: "700 Hz low-pass + 260 µs interaural delay",
                            showConnector: true
                        )
                    }

                    let isUnity = !audio.isMuted && abs(audio.volume - 1.0) <= 0.005
                    HStack(alignment: .top, spacing: 10) {
                        connectorColumn(color: isUnity ? .green : .cyan, showLine: true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Output Gain")
                                    .font(.system(size: 12, weight: .semibold))
                                if !isUnity && !audio.isMuted {
                                    Button("Unity 100%") {
                                        audio.volume = 1.0
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                            Text(audio.isMuted ? "Muted" : (isUnity ? "Unity Gain (100% — 0.0 dB)" : "Digital Volume (\(Int((audio.volume * 100).rounded()))%)"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 6)

                    stageRow(
                        color: audio.isHogModeActive ? .purple : .green,
                        title: "CoreAudio HAL Output",
                        detail: audio.activeOutputDevice?.name ?? "System Default Output",
                        subtitle: dacSubtitle,
                        showConnector: false
                    )
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                    Text("Play any song to inspect live CoreAudio sample rate, DSP processing, and hardware DAC routing.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(width: 345)
    }

    private var headerView: some View {
        let tier = vm.signalPathTier
        let (title, subtitle, color, icon): (String, String, Color, String) = {
            switch tier {
            case .bitPerfect:
                return ("Signal Path: Lossless Bit-Perfect", "Stream reaches DAC without DSP or resampling", .green, "sparkles")
            case .enhanced:
                return ("Signal Path: High Quality (DSP)", "Active gain/DSP or sample rate conversion", .cyan, "waveform.path.ecg")
            case .lossy:
                return ("Signal Path: Lossy Source", "Decoded from compressed lossy encoding", .orange, "waveform")
            case .idle:
                return ("Signal Path", "CoreAudio bit-accurate playback pipeline", .secondary, "waveform.circle")
            }
        }()

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Audio Prefs") {
                vm.showingSignalPathPopover = false
                vm.selectedSettingsTab = .audio
                vm.showingSettings = true
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func stageRow(
        color: Color,
        title: String,
        detail: String,
        subtitle: String?,
        showConnector: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            connectorColumn(color: color, showLine: showConnector)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, showConnector ? 8 : 0)
    }

    private func connectorColumn(color: Color, showLine: Bool) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 3)
            if showLine {
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 1.5)
                    .frame(minHeight: 16, maxHeight: .infinity)
            }
        }
        .frame(width: 12)
    }

    private var dacSubtitle: String {
        var parts: [String] = []
        if let dev = audio.activeOutputDevice {
            parts.append("DAC \(dev.formattedSampleRate)")
            if dev.isSystemDefault {
                parts.append("System Default")
            }
        }
        parts.append(audio.isHogModeActive ? "Exclusive Hog Mode Locked" : "Shared HAL Mode")
        if audio.isGaplessNextScheduled {
            parts.append("Gapless Next Pre-Buffered")
        }
        return parts.joined(separator: " • ")
    }

    private func sourceDetail(for track: Track) -> String {
        var specs: [String] = [track.format]
        if let sr = track.sampleRate {
            specs.append(formatRate(sr))
        }
        if let bd = track.bitDepth, bd > 0 {
            specs.append("\(bd)-bit")
        }
        return specs.joined(separator: " • ")
    }

    private func formatRate(_ hz: Double) -> String {
        let khz = hz / 1000.0
        if khz == floor(khz) {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }
}
