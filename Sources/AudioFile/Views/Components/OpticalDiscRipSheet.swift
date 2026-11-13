import SwiftUI

public struct OpticalDiscRipSheet: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var opticalManager = OpticalDiscManager.shared
    @ObservedObject var ripEngine = OpticalDiscRipEngine.shared
    public let disc: OpticalDisc

    @Environment(\.dismiss) private var dismiss

    public init(vm: PlayerViewModel, disc: OpticalDisc) {
        self.vm = vm
        self.disc = disc

        if opticalManager.ripDestinationFolder == nil {
            let defaultFolder = vm.config.libraryFolders.first ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
            opticalManager.ripDestinationFolder = defaultFolder
        }
    }

    private var destinationFolderBinding: Binding<URL> {
        Binding(
            get: {
                opticalManager.ripDestinationFolder ?? vm.config.libraryFolders.first ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
            },
            set: { opticalManager.ripDestinationFolder = $0 }
        )
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack(spacing: 14) {
                if let artData = disc.artworkData, let img = NSImage(data: artData) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 2)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.2))
                        Image(systemName: "opticaldisc")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 56, height: 56)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Rip Audio CD")
                        .font(.title2.weight(.bold))
                    Text("\(disc.title) • \(disc.artist) (\(disc.tracks.count) tracks)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 1. Format Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Encoding Format")
                            .font(.headline)

                        Picker("Format", selection: $opticalManager.ripFormat) {
                            ForEach(RipFormat.allCases) { fmt in
                                Text(fmt.displayName).tag(fmt)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(opticalManager.ripFormat.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }

                    // 2. Destination Folder Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Destination Library Folder")
                            .font(.headline)

                        if vm.config.libraryFolders.count > 1 {
                            // Prompt user with picker of enabled library folders
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Multiple library folders enabled. Please select destination:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Picker("Library Folder", selection: destinationFolderBinding) {
                                    ForEach(vm.config.libraryFolders, id: \.self) { folder in
                                        Text(folder.path).tag(folder)
                                    }
                                }
                                .pickerStyle(.radioGroup)
                            }
                        } else {
                            HStack {
                                Text(destinationFolderBinding.wrappedValue.path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.05))
                                    .cornerRadius(6)

                                Button("Choose…") {
                                    chooseCustomFolder()
                                }
                            }
                        }

                        // Preview folder hierarchy: Artist / Album / Track - Song.ext
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Standard Folder Structure:")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            let previewPath = "\(OpticalDiscRipEngine.sanitizePathSegment(disc.artist)) / \(OpticalDiscRipEngine.sanitizePathSegment(disc.title)) / 01 - \(OpticalDiscRipEngine.sanitizePathSegment(disc.tracks.first?.title ?? "Song")).\(opticalManager.ripFormat.fileExtension)"
                            Text(previewPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.top, 4)
                    }

                    // 3. Whipper / AccurateRip Accuracy Verification
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rip Accuracy Verification")
                            .font(.headline)

                        Toggle(isOn: $opticalManager.verifyWithAccurateRip) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AccurateRip & Multi-Pass CRC Verification")
                                    .font(.subheadline.weight(.medium))
                                Text("Employs Whipper-style secure multi-pass sector re-reads, IEEE 802.3 CRC-32 consistency checks, and online AccurateRip database cross-referencing to ensure bit-perfect accuracy.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    startRipping()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Start Ripping (\(disc.tracks.count) tracks)")
                    }
                    .font(.headline)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540, height: 490)
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.message = "Choose destination library folder for CD rips"

        if panel.runModal() == .OK, let url = panel.url {
            opticalManager.ripDestinationFolder = url
        }
    }

    private func startRipping() {
        dismiss()

        let destination = destinationFolderBinding.wrappedValue
        let format = opticalManager.ripFormat
        let verify = opticalManager.verifyWithAccurateRip

        ripEngine.startRip(
            disc: disc,
            tracks: disc.tracks,
            destinationFolder: destination,
            format: format,
            verifyWithAccurateRip: verify,
            onTrackStateChanged: { trackNum, state in
                OpticalDiscManager.shared.updateTrackRipState(trackNumber: trackNum, state: state)
            },
            onFinished: { success, msg in
                vm.showToast(icon: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill", message: msg)
            }
        )
    }
}
