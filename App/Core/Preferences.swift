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

    /// What follows you from device to device: how subtitles and audio are chosen, what is
    /// skipped, whether the next episode starts. Quality stays with each device: a phone on
    /// cellular and a desktop on the LAN want different ones.
    struct Shared: Codable, Sendable, Equatable {
        var segmentActions: [MediaSegment.Kind: SegmentAction]
        var autoplayNext: Bool
        var preferredAudioLanguage: String?
        var preferredSubtitleLanguage: String?
        var subtitleMode: SubtitleMode
        var subtitleSize: SubtitleSize
    }

    var shared: Shared {
        get {
            Shared(
                segmentActions: segmentActions, autoplayNext: autoplayNext,
                preferredAudioLanguage: preferredAudioLanguage, preferredSubtitleLanguage: preferredSubtitleLanguage,
                subtitleMode: subtitleMode, subtitleSize: subtitleSize
            )
        }
        set {
            segmentActions = newValue.segmentActions
            autoplayNext = newValue.autoplayNext
            preferredAudioLanguage = newValue.preferredAudioLanguage
            preferredSubtitleLanguage = newValue.preferredSubtitleLanguage
            subtitleMode = newValue.subtitleMode
            subtitleSize = newValue.subtitleSize
        }
    }

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
    ///
    /// With no audio language chosen, a film starts in the language it was made in, when
    /// it has a track in it: a file can flag a dub as its default. Then the file's default
    /// subtitles, which go with its default audio, are not shown either.
    func initialTracks(for source: MediaSource, item: BaseItem? = nil) -> (audio: Int?, subtitle: Int?) {
        let flagged = source.audioStreams.first { $0.index == source.defaultAudioStreamIndex }
            ?? source.audioStreams.first { $0.isDefault == true }
        let original = preferredAudioLanguage == nil ? item.map(Self.originalLanguages) ?? [] : []
        let audio = source.audioStreams.first { $0.language == preferredAudioLanguage }
            ?? (flagged.flatMap { original.contains($0.language ?? "") ? $0 : nil })
            ?? source.audioStreams.first { original.contains($0.language ?? "") }
            ?? flagged
            ?? source.audioStreams.first
        let followsFile = flagged == nil || audio?.index == flagged?.index
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
                    ?? (followsFile ? subtitles.first { $0.index == source.defaultSubtitleStreamIndex && $0.isDefault == true } : nil)
            }
        }
        return (audio?.index, subtitle?.index)
    }

    /// The languages of where it was made, as files tag their tracks (both ISO 639-2 forms).
    static func originalLanguages(_ item: BaseItem) -> Set<String> {
        guard let country = item.productionLocations?.first?.lowercased() else { return [] }
        let languages: [(countries: [String], codes: Set<String>)] = [
            (["united states of america", "united states", "usa", "united kingdom", "uk", "canada", "australia", "new zealand", "ireland"], ["eng"]),
            (["japan"], ["jpn"]),
            (["south korea", "korea", "republic of korea"], ["kor"]),
            (["china", "hong kong", "taiwan"], ["chi", "zho"]),
            (["france"], ["fre", "fra"]),
            (["germany"], ["ger", "deu"]),
            (["spain", "mexico", "argentina"], ["spa"]),
            (["italy"], ["ita"]),
            (["russia", "russian federation"], ["rus"]),
            (["brazil", "portugal"], ["por"]),
            (["sweden"], ["swe"]),
            (["denmark"], ["dan"]),
            (["norway"], ["nor", "nob"]),
            (["netherlands"], ["dut", "nld"]),
            (["poland"], ["pol"]),
            (["turkey"], ["tur"]),
            (["thailand"], ["tha"]),
        ]
        return languages.first { $0.countries.contains(country) }?.codes ?? []
    }
}

/// What the network costs, for picking a bitrate.
enum NetworkKind: Sendable, Equatable {
    case wifi
    case cellular
    case offline
}
