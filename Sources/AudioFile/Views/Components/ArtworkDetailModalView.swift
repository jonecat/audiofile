import SwiftUI
import AppKit

public struct ArtworkDetailModalView: View {
    @ObservedObject var vm: PlayerViewModel
    public let track: Track

    @StateObject private var loader = ArtworkLoader()

    public init(vm: PlayerViewModel, track: Track) {
        self.vm = vm
        self.track = track
    }

    private var imageDimensionsString: String? {
        guard let img = loader.artwork else { return nil }
        if let rep = img.representations.first, rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh) px"
        } else if img.size.width > 0 && img.size.height > 0 {
            return "\(Int(img.size.width)) × \(Int(img.size.height)) px"
        }
        return nil
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Header Bar
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayAlbum)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    vm.inspectingArtworkTrack = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary.opacity(0.7))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            // Main Artwork Display
            ZStack {
                if let image = loader.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 460, maxHeight: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(
                                colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 320, height: 320)

                        VStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .font(.system(size: 48, weight: .light))
                                .foregroundColor(.secondary)
                            Text("No Embedded Artwork")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 480)
            .padding(.horizontal, 20)

            // Artwork & Track Details Strip
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if let dr = track.dynamicRange {
                        DynamicRangeBadgeView(score: dr, compact: true)
                    }

                    FormatBadgeView(format: track.format, isLossless: track.isLossless)

                    if let dims = imageDimensionsString {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                                .font(.system(size: 10))
                            Text(dims)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.06))
                        )
                    }

                    if !track.qualityDescription.isEmpty {
                        Text(track.qualityDescription)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.06))
                            )
                    }

                    if let year = track.formattedYear {
                        Text(year)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.06))
                            )
                    }
                }

                Text(track.displayTitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 20)

            // Bottom Actions Bar
            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([track.path])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .help("Reveal audio file in Finder")

                Spacer()

                Button("Done") {
                    vm.inspectingArtworkTrack = nil
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .help("Close Artwork Viewer (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 540)
        .fixedSize(horizontal: true, vertical: false)
        .task(id: track.id) {
            await loader.load(track: track)
        }
    }
}
