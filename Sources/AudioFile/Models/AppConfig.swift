import Foundation

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off = "Off"
    case all = "All"
    case one = "1"

    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    public var systemImage: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

public enum VisualizerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case bars = "Spectrum Bars"
    case vuMeter = "Analog VU Meter"
    case circular = "Radial Halo"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .bars: return "chart.bar.fill"
        case .vuMeter: return "gauge.with.needle"
        case .circular: return "circle.dashed"
        }
    }

    public var next: VisualizerMode {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .bars }
        let nextIdx = (idx + 1) % all.count
        return all[nextIdx]
    }
}

public struct AppConfig: Codable, Sendable {
    public var libraryFolders: [URL]
    public var volume: Float
    public var repeatMode: RepeatMode
    public var shuffle: Bool
    public var visualizerFPS: Int
    public var visualizerMode: VisualizerMode
    public var showLyrics: Bool
    public var showVisualizer: Bool
    public var lyricsScale: Double
    public var autoFetchLyrics: Bool
    public var artistsColumnWidth: Double
    public var albumsColumnWidth: Double

    public init(
        libraryFolders: [URL] = AppConfig.defaultFolders(),
        volume: Float = 0.8,
        repeatMode: RepeatMode = .off,
        shuffle: Bool = false,
        visualizerFPS: Int = 60,
        visualizerMode: VisualizerMode = .bars,
        showLyrics: Bool = true,
        showVisualizer: Bool = true,
        lyricsScale: Double = 1.0,
        autoFetchLyrics: Bool = true,
        artistsColumnWidth: Double = 220.0,
        albumsColumnWidth: Double = 250.0
    ) {
        self.libraryFolders = libraryFolders
        self.volume = volume
        self.repeatMode = repeatMode
        self.shuffle = shuffle
        self.visualizerFPS = visualizerFPS
        self.visualizerMode = visualizerMode
        self.showLyrics = showLyrics
        self.showVisualizer = showVisualizer
        self.lyricsScale = lyricsScale
        self.autoFetchLyrics = autoFetchLyrics
        self.artistsColumnWidth = artistsColumnWidth
        self.albumsColumnWidth = albumsColumnWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.libraryFolders = try container.decodeIfPresent([URL].self, forKey: .libraryFolders) ?? AppConfig.defaultFolders()
        self.volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 0.8
        self.repeatMode = try container.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        self.shuffle = try container.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        self.visualizerFPS = try container.decodeIfPresent(Int.self, forKey: .visualizerFPS) ?? 60
        self.visualizerMode = (try? container.decodeIfPresent(VisualizerMode.self, forKey: .visualizerMode)) ?? .bars
        self.showLyrics = try container.decodeIfPresent(Bool.self, forKey: .showLyrics) ?? true
        self.showVisualizer = try container.decodeIfPresent(Bool.self, forKey: .showVisualizer) ?? true
        self.lyricsScale = try container.decodeIfPresent(Double.self, forKey: .lyricsScale) ?? 1.0
        self.autoFetchLyrics = try container.decodeIfPresent(Bool.self, forKey: .autoFetchLyrics) ?? true
        self.artistsColumnWidth = try container.decodeIfPresent(Double.self, forKey: .artistsColumnWidth) ?? 220.0
        self.albumsColumnWidth = try container.decodeIfPresent(Double.self, forKey: .albumsColumnWidth) ?? 250.0
    }

    public static func defaultFolders() -> [URL] {
        let musicDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        if let dir = musicDir, FileManager.default.fileExists(atPath: dir.path) {
            return [dir]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fallback = home.appendingPathComponent("Music")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return [fallback]
        }
        return []
    }

    public static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AudioFile", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("config.json")
    }

    public static func load() -> AppConfig {
        let url = configURL
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        let config = AppConfig()
        config.save()
        return config
    }

    public func save() {
        let url = AppConfig.configURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
