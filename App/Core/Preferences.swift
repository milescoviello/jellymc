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

    private static let key = "preferences.v1"

    static func load(from defaults: UserDefaults = .standard) -> Preferences {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
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
