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
        VStack(alignment: .leading, spacing: 0) {
            // Fixed Header: Artwork + Summary + Detected Tag Containers
            headerCard
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 14)

            Divider()

            // Scrollable Inspector Body
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editableMetadataSection

                    Divider()

                    fullEmbeddedTagsSection

                    Divider()

                    audioAndFileDetailsSection
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }

            Divider()

            // Fixed Footer: Save Mode + Actions
            footerBar
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 680, height: 640)
    }

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(spacing: 16) {
            ArtworkView(track: track, cornerRadius: 10, shadowRadius: 4)
                .frame(width: 72, height: 72)

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

                if let report = vm.inspectedTrackTagReport, !report.sections.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(report.sections) { section in
                            Text(section.title)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.12))
                                )
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    // MARK: - Editable Metadata Section

    private var editableMetadataSection: some View {
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

                        Text("Date:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        TextField("YYYY-MM-DD", text: $vm.metaYear)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 104)
                    }
                }
            }
        }
    }

    // MARK: - Full ID3 & Embedded Tags Section

    private var fullEmbeddedTagsSection: some View {
        let report = vm.inspectedTrackTagReport
        let filterQuery = vm.metaTagFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredSections = filteredTagSections(from: report, query: filterQuery)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("FULL ID3 & EMBEDDED TAGS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .tracking(0.8)

                    if let report, report.totalTagCount > 0 {
                        Text("\(report.totalTagCount)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                }

                Spacer()

                if let report, !report.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        TextField("Filter tags…", text: $vm.metaTagFilterQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .frame(width: 145)

                        if !vm.metaTagFilterQuery.isEmpty {
                            Button {
                                vm.metaTagFilterQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear tag filter")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    Button {
                        let text = report.formattedPlainText(for: track)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        vm.showToast(icon: "doc.on.doc", message: "Copied \(report.totalTagCount) metadata tags")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Copy All")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Copy all embedded metadata tags to clipboard")
                }
            }

            if vm.isLoadingInspectedTags {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading embedded file tags…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.035))
                )
            } else if let report, report.isEmpty {
                Text(track.id.hasPrefix("optical_") || track.format.uppercased() == "CDDA"
                     ? "Audio CD tracks do not contain embedded ID3 file headers."
                     : "No embedded ID3 or container metadata frames were found in this file.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.035))
                    )
            } else if filteredSections.isEmpty && !filterQuery.isEmpty {
                Text("No metadata frames match \"\(filterQuery)\".")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.035))
                    )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredSections) { section in
                        tagSectionCard(section)
                    }
                }
            }
        }
    }

    private func filteredTagSections(from report: FullTrackTagReport?, query: String) -> [TagSection] {
        guard let report else { return [] }
        if query.isEmpty {
            return report.sections
        }

        return report.sections.compactMap { section in
            if section.title.localizedCaseInsensitiveContains(query) {
                return section
            }
            let matchingItems = section.items.filter { item in
                item.rawKey.localizedCaseInsensitiveContains(query) ||
                item.displayName.localizedCaseInsensitiveContains(query) ||
                item.value.localizedCaseInsensitiveContains(query) ||
                (item.detail?.localizedCaseInsensitiveContains(query) ?? false)
            }
            guard !matchingItems.isEmpty else { return nil }
            return TagSection(
                id: section.id,
                title: section.title,
                subtitle: "\(matchingItems.count) of \(section.items.count) matching",
                items: matchingItems
            )
        }
    }

    private func tagSectionCard(_ section: TagSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                Text(section.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    tagFieldRow(item, isAlternate: index % 2 == 1)

                    if index < section.items.count - 1 {
                        Divider()
                            .opacity(0.5)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func tagFieldRow(_ item: TagFieldItem, isAlternate: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.rawKey)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.10))
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 190, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.value)
                    .font(.system(size: 11.5, design: item.isMultiline ? .default : .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isAlternate ? Color.primary.opacity(0.018) : Color.clear)
    }

    // MARK: - Audio & File Details Section

    private var audioAndFileDetailsSection: some View {
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

                if track.replayGainTrackDb != nil || track.replayGainAlbumDb != nil || track.replayGainPeak != nil {
                    GridRow {
                        techItem(
                            label: "Track ReplayGain",
                            value: track.replayGainTrackDb.map { String(format: "%+.2f dB", $0) } ?? "N/A"
                        )
                        techItem(
                            label: "Album ReplayGain",
                            value: track.replayGainAlbumDb.map { String(format: "%+.2f dB", $0) } ?? "N/A"
                        )
                        techItem(
                            label: "ReplayGain Peak",
                            value: track.replayGainPeak.map { String(format: "%.6f", $0) } ?? "N/A"
                        )
                    }
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
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
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
                vm.endInspectingMetadata()
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

    // MARK: - Helpers

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
