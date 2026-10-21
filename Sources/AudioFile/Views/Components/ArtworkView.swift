import SwiftUI
import AppKit

@MainActor
public final class ArtworkLoader: ObservableObject {
    @Published public var artwork: NSImage?
    @Published public var loadedTrackId: String?

    public init() {}

    public func load(track: Track?) async {
        guard let t = track else {
            artwork = nil
            loadedTrackId = nil
            return
        }
        if loadedTrackId == t.id { return }
        let img = await MetadataReader.loadArtwork(for: t)
        self.artwork = img
        self.loadedTrackId = t.id
    }
}

public struct ArtworkView: View {
    public let track: Track?
    public let cornerRadius: CGFloat
    public let shadowRadius: CGFloat

    @StateObject private var loader = ArtworkLoader()

    public init(track: Track?, cornerRadius: CGFloat = 8, shadowRadius: CGFloat = 4) {
        self.track = track
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
    }

    public var body: some View {
        Group {
            if let image = loader.artwork {
                Image(nsImage: image)
                    .resizable()
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
            await loader.load(track: track)
        }
    }
}
