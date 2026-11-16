import SwiftUI

/// 10-band Parametric EQ control surface with Bit-Perfect Bypass, presets, and AutoEQ .txt import.
public struct ParametricEQView: View {
    @ObservedObject public var vm: PlayerViewModel
    public let showDSPExtras: Bool

    public init(vm: PlayerViewModel, showDSPExtras: Bool = true) {
        self.vm = vm
        self.showDSPExtras = showDSPExtras
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header & Controls
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { vm.config.eqEnabled },
                    set: { vm.setEQEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Parametric EQ")
                            .font(.system(size: 13, weight: .bold))
                        Text(vm.config.eqEnabled ? "DSP Active (\(vm.config.eqPresetName))" : "Bit-Perfect Bypass")
                            .font(.system(size: 10))
                            .foregroundColor(vm.config.eqEnabled ? .accentColor : .green)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                Picker("Preset", selection: Binding(
                    get: { vm.config.eqPresetName },
                    set: { vm.applyEQPreset($0) }
                )) {
                    ForEach(PlayerViewModel.eqPresetNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !PlayerViewModel.eqPresetNames.contains(vm.config.eqPresetName) {
                        Text(vm.config.eqPresetName).tag(vm.config.eqPresetName)
                    }
                }
                .labelsHidden()
                .frame(width: 135)
                .controlSize(.small)

                Button {
                    vm.importAutoEQFile()
                } label: {
                    Label("AutoEQ…", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Import EqualizerAPO / AutoEQ ParametricEQ .txt profile")
            }

            // Preamp Gain
            HStack(spacing: 10) {
                Text("Preamp")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .leading)

                Slider(value: Binding(
                    get: { vm.config.eqPreampDb },
                    set: { vm.setEQPreamp($0) }
                ), in: -12.0...12.0, step: 0.5)
                .controlSize(.small)

                Text(String(format: "%+.1f dB", vm.config.eqPreampDb))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 56, alignment: .trailing)

                Button("Reset") {
                    vm.applyEQPreset("Flat")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            // 10-Band Vertical Parametric Sliders
            HStack(spacing: 6) {
                ForEach(Array(vm.config.eqBands.enumerated()), id: \.offset) { index, band in
                    VStack(spacing: 6) {
                        Text(String(format: "%+.1f", band.gainDb))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(abs(band.gainDb) > 0.05 && vm.config.eqEnabled ? .accentColor : .secondary)

                        Slider(value: Binding(
                            get: { Double(band.gainDb) },
                            set: { vm.updateEQBand(at: index, gainDb: Float($0)) }
                        ), in: -12.0...12.0, step: 0.5)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 108, height: 26)
                        .frame(width: 28, height: 108)
                        .opacity(vm.config.eqEnabled ? 1.0 : 0.55)

                        Text(formatFrequency(band.frequency))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.85))
                            .help("Double-click to flatten band (\(formatFrequency(band.frequency)), Q \(String(format: "%.2f", band.qFactor)))")
                            .onTapGesture(count: 2) {
                                vm.updateEQBand(at: index, gainDb: 0.0)
                            }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.04))
            )

            if showDSPExtras {
                Divider()

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { vm.config.crossfeedEnabled },
                            set: { vm.setCrossfeedEnabled($0) }
                        )) {
                            Text("Headphone Crossfeed (BS2B)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Spacer()

                        Slider(value: Binding(
                            get: { Double(vm.config.crossfeedLevel) },
                            set: { vm.setCrossfeedLevel(Float($0)) }
                        ), in: 0.05...0.75)
                        .frame(width: 110)
                        .controlSize(.small)
                        .disabled(!vm.config.crossfeedEnabled)

                        Text("\(Int((vm.config.crossfeedLevel * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }

                    HStack(spacing: 10) {
                        Text("ReplayGain")
                            .font(.system(size: 11, weight: .semibold))

                        Spacer()

                        Picker("ReplayGain", selection: Binding(
                            get: { vm.config.replayGainMode },
                            set: { vm.setReplayGainMode($0) }
                        )) {
                            ForEach(ReplayGainMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 215)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func formatFrequency(_ hz: Double) -> String {
        if hz >= 1000.0 {
            let khz = hz / 1000.0
            if abs(khz - khz.rounded()) < 0.05 {
                return "\(Int(khz.rounded()))k"
            }
            return String(format: "%.1fk", khz)
        }
        return "\(Int(hz.rounded()))"
    }
}
