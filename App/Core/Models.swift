import Foundation

// The server's types, as the API sends them, cut to the fields the app reads.
//
// Jellyfin's JSON is PascalCase; `JSONCoding` maps it to Swift's camelCase in both
// directions, so the property names here are the API's own names with a lower-case first
// letter. Every field is optional unless the server always sends it: a 12.x point release
// that drops one must not stop a screen from decoding.

/// `GET /System/Info/Public`: answered without signing in, which is how a URL is checked
/// to be a Jellyfin server before asking for a password.
struct PublicSystemInfo: Codable, Sendable, Equatable {
    var serverName: String?
    var version: String?
    var id: String?
    var localAddress: String?
    var startupWizardCompleted: Bool?
}

struct UserPolicy: Codable, Sendable, Equatable {
    var isAdministrator: Bool?
    var enableMediaPlayback: Bool?
    var enableVideoPlaybackTranscoding: Bool?
    var enableContentDownloading: Bool?
}

/// The user's own settings on the server, from its web client's Home screen settings.
struct UserConfiguration: Codable, Sendable, Equatable {
    /// Libraries left out of the home screen's "Latest" rows.
    var latestItemsExcludes: [String]?
    /// Libraries hidden altogether; `/UserViews` already leaves them out.
    var myMediaExcludes: [String]?
    /// The user's order for libraries; `/UserViews` already returns them in it.
    var orderedViews: [String]?
    var enableNextEpisodeAutoPlay: Bool?
}

struct User: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String?
    var serverId: String?
    var primaryImageTag: String?
    var policy: UserPolicy?
    var configuration: UserConfiguration?
}

/// `POST /Users/AuthenticateByName`.
struct AuthenticationResult: Codable, Sendable {
    var user: User
    var accessToken: String
    var serverId: String?
}

/// One page of a list endpoint.
struct ItemsPage<Item: Codable & Sendable>: Codable, Sendable {
    var items: [Item]
    var totalRecordCount: Int?
    var startIndex: Int?

    init(items: [Item], totalRecordCount: Int? = nil, startIndex: Int? = nil) {
        self.items = items
        self.totalRecordCount = totalRecordCount
        self.startIndex = startIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount)
        startIndex = try container.decodeIfPresent(Int.self, forKey: .startIndex)
    }
}

/// The API's `BaseItemKind`, kept open: a kind this build has never heard of decodes
/// rather than failing the whole page.
struct ItemKind: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let movie = ItemKind("Movie")
    static let series = ItemKind("Series")
    static let season = ItemKind("Season")
    static let episode = ItemKind("Episode")
    static let video = ItemKind("Video")
    static let musicVideo = ItemKind("MusicVideo")
    static let boxSet = ItemKind("BoxSet")
    static let folder = ItemKind("Folder")
    static let collectionFolder = ItemKind("CollectionFolder")
    static let userView = ItemKind("UserView")
    static let musicAlbum = ItemKind("MusicAlbum")
    static let musicArtist = ItemKind("MusicArtist")
    static let audio = ItemKind("Audio")
    static let playlist = ItemKind("Playlist")
    static let person = ItemKind("Person")
    static let trailer = ItemKind("Trailer")
    static let photo = ItemKind("Photo")
    static let tvChannel = ItemKind("TvChannel")

    /// Kinds that play as video.
    var isVideo: Bool {
        [.movie, .episode, .video, .musicVideo, .trailer].contains(self)
    }
}

struct UserItemData: Codable, Sendable, Equatable {
    var playbackPositionTicks: Int64?
    var playCount: Int?
    var isFavorite: Bool?
    var played: Bool?
    var lastPlayedDate: Date?
    var playedPercentage: Double?
    var unplayedItemCount: Int?
}

struct NameIdPair: Codable, Sendable, Equatable, Hashable {
    var name: String?
    var id: String?
}

struct Person: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String?
    var role: String?
    var type: String?
    var primaryImageTag: String?
}

struct Chapter: Codable, Sendable, Equatable {
    var startPositionTicks: Int64
    var name: String?
    var imageTag: String?
}

/// One trickplay resolution: the server's thumbnails at `width`, packed into tiles of
/// `tileWidth` x `tileHeight` thumbnails, one every `interval` milliseconds.
struct TrickplayInfo: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var tileWidth: Int
    var tileHeight: Int
    var thumbnailCount: Int
    var interval: Int
    var bandwidth: Int?
}

struct ExternalURL: Codable, Sendable, Equatable {
    var name: String?
    var url: String?
}

struct MediaStream: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        case video = "Video"
        case audio = "Audio"
        case subtitle = "Subtitle"
        case embeddedImage = "EmbeddedImage"
        case data = "Data"
        case lyric = "Lyric"
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    var type: Kind
    var index: Int
    var codec: String?
    var codecTag: String?
    var language: String?
    var title: String?
    var displayTitle: String?
    var isDefault: Bool?
    var isForced: Bool?
    var isExternal: Bool?
    var isTextSubtitleStream: Bool?
    var supportsExternalStream: Bool?
    var deliveryMethod: String?
    var deliveryUrl: String?
    var path: String?
    var width: Int?
    var height: Int?
    var bitRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var channelLayout: String?
    var sampleRate: Int?
    var profile: String?
    var level: Double?
    var videoRange: String?
    var videoRangeType: String?
    var averageFrameRate: Double?
    var isInterlaced: Bool?

    /// What a track menu shows: the server's own description, which already reads like
    /// "English - AAC - Stereo - Default".
    var label: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        return [title, language, codec?.uppercased()].compactMap { $0 }.joined(separator: " · ")
    }

    var isHDR: Bool {
        guard let videoRangeType else { return false }
        return videoRangeType != "SDR" && videoRangeType != "Unknown"
    }
}

struct MediaSource: Codable, Sendable, Equatable {
    var id: String
    var name: String?
    var path: String?
    var container: String?
    var size: Int64?
    var bitrate: Int?
    var runTimeTicks: Int64?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var transcodingUrl: String?
    var transcodingSubProtocol: String?
    var transcodingContainer: String?
    var mediaStreams: [MediaStream]?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var hasSegments: Bool?
    var eTag: String?
    var isRemote: Bool?
    var requiredHttpHeaders: [String: String]?
    var liveStreamId: String?
    var requiresClosing: Bool?

    var streams: [MediaStream] { mediaStreams ?? [] }
    var videoStream: MediaStream? { streams.first { $0.type == .video } }
    var audioStreams: [MediaStream] { streams.filter { $0.type == .audio } }
    var subtitleStreams: [MediaStream] { streams.filter { $0.type == .subtitle } }
}

/// Everything the app shows: a film, a series, a season, an episode, a collection, a
/// person, a library. Which fields are present depends on the kind and on the `Fields` asked for.
struct BaseItem: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String?
    var originalTitle: String?
    var serverId: String?
    var type: ItemKind?
    var collectionType: String?
    var mediaType: String?
    var overview: String?
    var taglines: [String]?
    var productionYear: Int?
    var premiereDate: Date?
    var endDate: Date?
    var status: String?
    var officialRating: String?
    var communityRating: Double?
    var criticRating: Double?
    var runTimeTicks: Int64?
    var genres: [String]?
    var studios: [NameIdPair]?
    var people: [Person]?
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonName: String?
    var indexNumber: Int?
    var indexNumberEnd: Int?
    var parentIndexNumber: Int?
    var parentId: String?
    var isFolder: Bool?
    var childCount: Int?
    var recursiveItemCount: Int?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var parentLogoItemId: String?
    var parentLogoImageTag: String?
    var seriesPrimaryImageTag: String?
    var imageBlurHashes: [String: [String: String]]?
    var primaryImageAspectRatio: Double?
    var userData: UserItemData?
    var mediaSources: [MediaSource]?
    var mediaStreams: [MediaStream]?
    var chapters: [Chapter]?
    /// Media source id, then width, then the resolution's tiles.
    var trickplay: [String: [String: TrickplayInfo]]?
    var remoteTrailers: [ExternalURL]?
    var localTrailerCount: Int?
    var specialFeatureCount: Int?
    var container: String?
    var width: Int?
    var height: Int?
    var locationType: String?
    /// A cast or crew member's part, when a person is shown as an item.
    var role: String?

    var title: String { name ?? "Untitled" }

    var runtime: Double? { runTimeTicks.map(Ticks.seconds) }

    var resumeSeconds: Double {
        userData?.playbackPositionTicks.map(Ticks.seconds) ?? 0
    }

    var isPlayed: Bool { userData?.played ?? false }
    var isFavorite: Bool { userData?.isFavorite ?? false }

    /// 0...1 through the item, for the progress bar under a card. Nil when unstarted.
    var progress: Double? {
        guard let position = userData?.playbackPositionTicks, position > 0,
              let total = runTimeTicks, total > 0
        else { return nil }
        return min(1, Double(position) / Double(total))
    }

    /// "S1:E3" for an episode, nil for anything else.
    var episodeLabel: String? {
        guard type == .episode, let episode = indexNumber else { return nil }
        let season = parentIndexNumber.map { "S\($0):" } ?? ""
        if let end = indexNumberEnd { return "\(season)E\(episode)-\(end)" }
        return "\(season)E\(episode)"
    }

    /// The second line of a card: the year for a film, the episode for an episode.
    var subtitle: String? {
        switch type {
        case .episode?:
            return [seriesName, episodeLabel].compactMap { $0 }.joined(separator: " · ")
        case .season?:
            return seriesName
        case .person?:
            return role
        default:
            return productionYear.map(String.init)
        }
    }
}

/// `POST /Items/{id}/PlaybackInfo`.
struct PlaybackInfoResponse: Codable, Sendable {
    var mediaSources: [MediaSource]
    var playSessionId: String?
    var errorCode: String?

    init(mediaSources: [MediaSource], playSessionId: String?, errorCode: String? = nil) {
        self.mediaSources = mediaSources
        self.playSessionId = playSessionId
        self.errorCode = errorCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaSources = try container.decodeIfPresent([MediaSource].self, forKey: .mediaSources) ?? []
        playSessionId = try container.decodeIfPresent(String.self, forKey: .playSessionId)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

/// A range the server has marked in an item: an intro, the credits, a recap.
struct MediaSegment: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case intro = "Intro"
        case outro = "Outro"
        case recap = "Recap"
        case preview = "Preview"
        case commercial = "Commercial"
        case unknown = "Unknown"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }

        var skipLabel: String {
            switch self {
            case .intro: return "Skip Intro"
            case .outro: return "Skip Credits"
            case .recap: return "Skip Recap"
            case .preview: return "Skip Preview"
            case .commercial: return "Skip Ad"
            case .unknown: return "Skip"
            }
        }
    }

    var id: String?
    var itemId: String?
    var type: Kind
    var startTicks: Int64
    var endTicks: Int64

    var start: Double { Ticks.seconds(startTicks) }
    var end: Double { Ticks.seconds(endTicks) }
}

