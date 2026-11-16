import SwiftUI
import AppKit

@MainActor
public final class ArtworkLoader: ObservableObject {
    @Published public var artwork: NSImage?
    @Published public var loadedTrackId: String?

    public init() {}

    public func load(track: Track?, maxPixelSize: Int? = 128) async {
        guard let t = track else {
            artwork = nil
            loadedTrackId = nil
            return
        }
        if loadedTrackId == t.id { return }
        if let cached = MetadataReader.cachedArtwork(for: t, maxPixelSize: maxPixelSize) {
            self.artwork = cached
            self.loadedTrackId = t.id
            return
        }
        if MetadataReader.isArtworkKnownMissing(for: t) {
            self.artwork = nil
            self.loadedTrackId = t.id
            return
        }
        let img = await MetadataReader.loadArtwork(for: t, maxPixelSize: maxPixelSize)
        self.artwork = img
        self.loadedTrackId = t.id
    }
}

public struct ArtworkView: View {
    public let track: Track?
    public let cornerRadius: CGFloat
    public let shadowRadius: CGFloat
    public let maxPixelSize: Int?

    @StateObject private var loader = ArtworkLoader()

    public init(track: Track?, cornerRadius: CGFloat = 8, shadowRadius: CGFloat = 4, maxPixelSize: Int? = 128) {
        self.track = track
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.maxPixelSize = maxPixelSize
    }

    public var body: some View {
        let displayImage = loader.loadedTrackId == track?.id
            ? loader.artwork
            : track.flatMap { MetadataReader.cachedArtwork(for: $0, maxPixelSize: maxPixelSize) }
        let useHighInterpolation = maxPixelSize.map { $0 > 128 } ?? true

        Group {
            if let image = displayImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(useHighInterpolation ? .high : .medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: Color.black.opacity(shadowRadius > 0 ? 0.25 : 0), radius: shadowRadius, y: shadowRadius > 0 ? 2 : 0)
        .task(id: track?.id) {
            guard let t = track else {
                loader.artwork = nil
                loader.loadedTrackId = nil
                return
            }
            if let cached = MetadataReader.cachedArtwork(for: t, maxPixelSize: maxPixelSize) {
                if loader.loadedTrackId != t.id || loader.artwork !== cached {
                    loader.artwork = cached
                    loader.loadedTrackId = t.id
                }
                return
            }
            if MetadataReader.isArtworkKnownMissing(for: t) {
                if loader.loadedTrackId != t.id || loader.artwork != nil {
                    loader.artwork = nil
                    loader.loadedTrackId = t.id
                }
                return
            }
            await loader.load(track: t, maxPixelSize: maxPixelSize)
        }
    }
}
