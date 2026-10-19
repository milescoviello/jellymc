import Foundation

/// Everything the user can set, saved as one JSON value.
struct Preferences: Codable, Sendable, Equatable {
    /// On the home network.
    var localPlayback = PlaybackPreferences()
    /// Away from home, and on a metered connection.
    var remotePlayback = PlaybackPreferences(maxBitrate: 10_000_000)
    var segmentActions: [MediaSegment.Kind: SegmentAction] = [:]
    var autoplayNext = true
    /// ISO 639-2, as the server labels streams: "eng", "jpn".
    var preferredAudioLanguage: String?
    var preferredSubtitleLanguage: String?
    var subtitleMode: SubtitleMode = .smart
    var subtitleSize: SubtitleSize = .normal

    /// Plex's subtitle sizes, as a scale on the player's own.
    enum SubtitleSize: String, Codable, Sendable, CaseIterable {
        case small, normal, large, huge

        var title: String { rawValue.capitalized }

        var scale: Double {
            switch self {
            case .small: return 0.8
            case .normal: return 1
            case .large: return 1.25
            case .huge: return 1.6
            }
        }
    }

    init() {}

    /// Missing keys keep their defaults: a newer app reads what an older one saved.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        localPlayback = try container.decodeIfPresent(PlaybackPreferences.self, forKey: .localPlayback) ?? defaults.localPlayback
        remotePlayback = try container.decodeIfPresent(PlaybackPreferences.self, forKey: .remotePlayback) ?? defaults.remotePlayback
        segmentActions = try container.decodeIfPresent([MediaSegment.Kind: SegmentAction].self, forKey: .segmentActions) ?? defaults.segmentActions
        autoplayNext = try container.decodeIfPresent(Bool.self, forKey: .autoplayNext) ?? defaults.autoplayNext
        preferredAudioLanguage = try container.decodeIfPresent(String.self, forKey: .preferredAudioLanguage)
        preferredSubtitleLanguage = try container.decodeIfPresent(String.self, forKey: .preferredSubtitleLanguage)
        subtitleMode = (try? container.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode)) ?? defaults.subtitleMode
        subtitleSize = (try? container.decodeIfPresent(SubtitleSize.self, forKey: .subtitleSize)) ?? defaults.subtitleSize
    }

    enum SubtitleMode: String, Codable, Sendable, CaseIterable {
        /// Subtitles when the audio is not in the preferred subtitle language.
        case smart
        case always
        /// Forced tracks only: signs and foreign dialogue.
        case forcedOnly
        case never

        var title: String {
            switch self {
            case .smart: return "When audio is another language"
            case .always: return "Always"
            case .forcedOnly: return "Forced only"
            case .never: return "Never"
            }
        }
    }

    func action(for kind: MediaSegment.Kind) -> SegmentAction {
        segmentActions[kind] ?? PlaybackSession.defaultAction(for: kind)
    }

    static let file = Paths.root.appendingPathComponent("preferences.json")

    /// From `preferences.json` beside the downloads. They were in UserDefaults once, which
    /// Foundation on Linux never writes to disk: Settings were gone at every start there.
    /// An older copy in UserDefaults is still read, once, where it exists.
    static func load(from file: URL = Self.file) -> Preferences {
        if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Preferences.self, from: data) {
            return value
        }
        if file == Self.file, let data = UserDefaults.standard.data(forKey: "preferences.v1"),
           let value = try? JSONDecoder().decode(Preferences.self, from: data) {
            return value
        }
        return Preferences()
    }

    func save(to file: URL = Self.file) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: file, options: .atomic) }
    }

    /// The audio and subtitle tracks to start with, by these preferences.
    func initialTracks(for source: MediaSource) -> (audio: Int?, subtitle: Int?) {
        let audio = source.audioStreams.first { $0.language == preferredAudioLanguage }
            ?? source.audioStreams.first { $0.index == source.defaultAudioStreamIndex }
            ?? source.audioStreams.first { $0.isDefault == true }
            ?? source.audioStreams.first
        let subtitles = source.subtitleStreams
        let wanted = preferredSubtitleLanguage
        let subtitle: MediaStream?
        switch subtitleMode {
        case .never:
            subtitle = nil
        case .forcedOnly:
            subtitle = subtitles.first { $0.isForced == true && ($0.language == audio?.language || wanted == nil || $0.language == wanted) }
        case .always:
            subtitle = subtitles.first { $0.language == wanted && $0.isForced != true }
                ?? subtitles.first { $0.index == source.defaultSubtitleStreamIndex }
                ?? subtitles.first
        case .smart:
            if let wanted, let audioLanguage = audio?.language, audioLanguage != wanted, audioLanguage != "und" {
                subtitle = subtitles.first { $0.language == wanted && $0.isForced != true } ?? subtitles.first { $0.language == wanted }
            } else {
                subtitle = subtitles.first { $0.isForced == true && ($0.language == audio?.language || $0.language == wanted) }
                    ?? subtitles.first { $0.index == source.defaultSubtitleStreamIndex && $0.isDefault == true }
            }
        }
        return (audio?.index, subtitle?.index)
    }
}

/// What the network costs, for picking a bitrate.
enum NetworkKind: Sendable, Equatable {
    case wifi
    case cellular
    case offline
}
