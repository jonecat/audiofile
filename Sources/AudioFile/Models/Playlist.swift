import Foundation

public struct Playlist: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var trackIds: [String]

    public init(name: String, id: String? = nil, trackIds: [String] = []) {
        self.name = name
        self.id = id ?? "\(name.lowercased().replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970))"
        self.trackIds = trackIds
    }
}

public struct PlaylistsData: Codable, Sendable {
    public var playlists: [Playlist]
    public var favorites: [String]
    public var recentlyPlayed: [String]

    public init(playlists: [Playlist] = [], favorites: [String] = [], recentlyPlayed: [String] = []) {
        self.playlists = playlists
        self.favorites = favorites
        self.recentlyPlayed = recentlyPlayed
    }
}
