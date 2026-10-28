import SwiftUI
import AppKit

public struct TrackMetadataSheetView: View {
    @ObservedObject var vm: PlayerViewModel
    public let track: Track

    public init(vm: PlayerViewModel, track: Track) {
        self.vm = vm
        self.track = track
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header: Artwork + Summary
            HStack(spacing: 16) {
                ArtworkView(track: track, cornerRadius: 10, shadowRadius: 4)
                    .frame(width: 68, height: 68)

                VStack(alignment: .leading, spacing: 5) {
                    Text(vm.metaTitle.isEmpty ? track.displayTitle : vm.metaTitle)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)

                    Text("\(vm.metaArtist.isEmpty ? track.displayArtist : vm.metaArtist) • \(vm.metaAlbum.isEmpty ? track.displayAlbum : vm.metaAlbum)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let dr = track.dynamicRange {
                            DynamicRangeBadgeView(score: dr, compact: true)
                        }

                        FormatBadgeView(format: track.format, isLossless: track.isLossless)

                        if !track.qualityDescription.isEmpty {
                            Text(track.qualityDescription)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))

            // Editable Metadata Section
            VStack(alignment: .leading, spacing: 10) {
                Text("METADATA TAGS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(0.8)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Title:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 85, alignment: .trailing)
                        TextField("Song Title", text: $vm.metaTitle)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("Artist:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 85, alignment: .trailing)
                        TextField("Artist", text: $vm.metaArtist)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("Album:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 85, alignment: .trailing)
                        TextField("Album", text: $vm.metaAlbum)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("Album Artist:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 85, alignment: .trailing)
                        TextField("Album Artist", text: $vm.metaAlbumArtist)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("Genre:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 85, alignment: .trailing)
                        TextField("Genre", text: $vm.metaGenre)
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("Track #:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 85, alignment: .trailing)

                        HStack(spacing: 14) {
                            TextField("Track", text: $vm.metaTrackNumber)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 68)

                            Text("Disc #:")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)

                            TextField("Disc", text: $vm.metaDiscNumber)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 68)

                            Text("Year:")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)

                            TextField("Year", text: $vm.metaYear)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 82)
                        }
                    }
                }
            }

            Divider()

            // Read-Only Technical Audio & File Information
            VStack(alignment: .leading, spacing: 8) {
                Text("AUDIO & FILE DETAILS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(0.8)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        techItem(label: "Format", value: "\(track.format.uppercased()) (\(track.isLossless ? "Lossless" : "Lossy"))")
                        techItem(label: "Sample Rate", value: track.formattedSampleRate ?? "N/A")
                        techItem(label: "Bit Depth", value: track.bitDepth.map { "\($0)-bit" } ?? "N/A")
                    }
                    GridRow {
                        techItem(label: "Bitrate", value: track.bitrate.map { "\($0) kbps" } ?? "N/A")
                        techItem(label: "Duration", value: track.formattedDuration)
                        techItem(label: "File Size", value: formattedFileSize)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                )

                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text(track.path.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Spacer()

                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([track.path])
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }

            Divider()

            // Footer: Save Mode + Actions
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Save Mode:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Picker("", selection: $vm.metaSaveMode) {
                        ForEach(HealthFixMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 205)
                }

                Spacer()

                Button("Cancel") {
                    vm.inspectingTrack = nil
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .disabled(vm.isSavingTrackMetadata)

                Button {
                    vm.saveInspectedTrackMetadata()
                } label: {
                    if vm.isSavingTrackMetadata {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Saving…")
                        }
                    } else {
                        Text("Save Metadata")
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isSavingTrackMetadata)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private var formattedFileSize: String {
        if let bytes = track.fileSize, bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: track.path.path),
           let size = attrs[.size] as? NSNumber {
            return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
        }
        return "N/A"
    }

    private func techItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
