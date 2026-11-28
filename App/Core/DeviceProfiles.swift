import Foundation

// What each player can play, told to the server, which then decides between sending the
// file as it is, remuxing it, or transcoding it.

struct DeviceProfile: Codable, Sendable, Equatable {
    struct DirectPlay: Codable, Sendable, Equatable {
        var container: String
        var type: String
        var videoCodec: String?
        var audioCodec: String?
    }

    struct Transcoding: Codable, Sendable, Equatable {
        var container: String
        var type: String
        var videoCodec: String?
        var audioCodec: String
        var `protocol`: String
        var context: String
        var maxAudioChannels: String?
        var minSegments: Int?
        var breakOnNonKeyFrames: Bool?
        var copyTimestamps: Bool?
        var enableSubtitlesInManifest: Bool?
    }

    struct Condition: Codable, Sendable, Equatable {
        var condition: String
        var property: String
        var value: String
        var isRequired: Bool
    }

    struct Codec: Codable, Sendable, Equatable {
        var type: String
        var codec: String?
        var container: String?
        var conditions: [Condition]
    }

    struct Subtitle: Codable, Sendable, Equatable {
        var format: String
        var method: String
    }

    var name: String
    var maxStreamingBitrate: Int
    var maxStaticBitrate: Int
    var musicStreamingTranscodingBitrate: Int
    var directPlayProfiles: [DirectPlay]
    var transcodingProfiles: [Transcoding]
    var containerProfiles: [Codec] = []
    var codecProfiles: [Codec]
    var subtitleProfiles: [Subtitle]
}

/// What the user has asked for that changes the profile.
struct PlaybackPreferences: Codable, Sendable, Equatable {
    /// Bits per second; the server transcodes anything above it.
    var maxBitrate = 120_000_000
    /// Pixels wide; 0 for no limit.
    var maxWidth = 0
    /// Burn styled ASS in on iOS rather than flatten it to plain text in the HLS stream.
    var keepASSStyling = true
    /// Ask for a transcode even when the file would play as it is.
    var forceTranscode = false

    static let bitrateChoices: [(title: String, bits: Int)] = [
        ("Original", 120_000_000), ("40 Mbps", 40_000_000), ("20 Mbps", 20_000_000),
        ("10 Mbps", 10_000_000), ("6 Mbps", 6_000_000), ("3 Mbps", 3_000_000), ("1.5 Mbps", 1_500_000),
    ]
}

enum PlayerKind: String, Sendable {
    /// iOS: AVPlayer. MP4 and HLS only, no ASS or image subtitles.
    case avPlayer
    /// Linux: libmpv. Everything.
    case mpv
}

enum DeviceProfiles {
    static func profile(for player: PlayerKind, preferences: PlaybackPreferences = .init()) -> DeviceProfile {
        switch player {
        case .avPlayer: return avPlayer(preferences)
        case .mpv: return mpv(preferences)
        }
    }

    // MARK: AVPlayer

    /// What AVFoundation really plays. Anything else is remuxed to HLS fMP4 (cheap: the
    /// video is copied), or transcoded; text subtitles come beside the video as WebVTT and
    /// the app draws them, and image or styled ones are burnt in.
    static func avPlayer(_ preferences: PlaybackPreferences) -> DeviceProfile {
        let videoAudio = "aac,ac3,eac3,alac,flac,mp3"
        var codecs: [DeviceProfile.Codec] = [
            .init(type: "Video", codec: "h264", conditions: [
                .init(condition: "LessThanEqual", property: "VideoBitDepth", value: "8", isRequired: false),
                .init(condition: "LessThanEqual", property: "VideoLevel", value: "52", isRequired: false),
                .init(condition: "NotEquals", property: "IsInterlaced", value: "true", isRequired: false),
            ]),
            .init(type: "Video", codec: "hevc", conditions: [
                .init(condition: "LessThanEqual", property: "VideoBitDepth", value: "10", isRequired: false),
                .init(condition: "EqualsAny", property: "VideoRangeType",
                      value: "SDR|HDR10|HDR10Plus|HLG|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR|DOVIWithHDR10Plus", isRequired: false),
                // AVFoundation plays HEVC in MP4 only under the `hvc1`/`dvh1` sample entries;
                // an `hev1` file is remuxed, which retags it.
                .init(condition: "EqualsAny", property: "VideoCodecTag", value: "hvc1|dvh1", isRequired: false),
            ]),
            .init(type: "VideoAudio", codec: nil, conditions: [
                .init(condition: "LessThanEqual", property: "AudioChannels", value: "8", isRequired: false),
            ]),
        ]
        if preferences.maxWidth > 0 {
            codecs.append(.init(type: "Video", codec: nil, conditions: [
                .init(condition: "LessThanEqual", property: "Width", value: String(preferences.maxWidth), isRequired: false),
            ]))
        }

        // Text subtitles always come alongside as a file, and the app draws them, whether
        // the video plays as it is or the server makes a stream. Never "Hls" (WebVTT in the
        // stream's manifest): the server stamps every WebVTT segment
        // `X-TIMESTAMP-MAP=MPEGTS:900000`, which is right for MPEG-TS segments that start
        // at 10 s, but its fMP4 segments start at 0, so AVPlayer showed every line 10 s
        // late. Without "External" the server will not direct play a file that has a
        // default text subtitle at all, even with none requested.
        var subtitles: [DeviceProfile.Subtitle] = ["vtt", "webvtt", "subrip", "srt", "mov_text", "ttml"].map {
            DeviceProfile.Subtitle(format: $0, method: "External")
        }
        // Styled subtitles flattened to text: the server converts them to WebVTT for the
        // app, the way it converts SRT.
        for format in ["ass", "ssa"] {
            subtitles.append(.init(format: format, method: preferences.keepASSStyling ? "Encode" : "External"))
        }
        for format in ["pgssub", "pgs", "dvdsub", "dvbsub", "sub"] {
            subtitles.append(.init(format: format, method: "Encode"))
        }

        return DeviceProfile(
            name: "jellymc AVPlayer",
            maxStreamingBitrate: preferences.maxBitrate,
            maxStaticBitrate: preferences.maxBitrate,
            musicStreamingTranscodingBitrate: 320_000,
            directPlayProfiles: preferences.forceTranscode ? [] : [
                .init(container: "mp4,m4v,mov", type: "Video", videoCodec: "h264,hevc", audioCodec: videoAudio),
            ],
            transcodingProfiles: [
                .init(container: "mp4", type: "Video", videoCodec: "hevc,h264", audioCodec: "aac,ac3,eac3,flac,alac",
                      protocol: "hls", context: "Streaming", maxAudioChannels: "8", minSegments: 2, breakOnNonKeyFrames: true,
                      copyTimestamps: nil, enableSubtitlesInManifest: false),
            ],
            codecProfiles: codecs,
            subtitleProfiles: subtitles
        )
    }

    // MARK: mpv

    /// libmpv plays anything FFmpeg reads, so every container and codec is direct play
    /// and every subtitle is embedded or loaded alongside. Every HDR type is declared too:
    /// mpv tone-maps for nothing, the server would spend its GPU doing the same.
    static func mpv(_ preferences: PlaybackPreferences) -> DeviceProfile {
        let containers = "mkv,mp4,m4v,mov,webm,ts,m2ts,mts,mpegts,avi,ogg,ogv,flv,wmv,asf,3gp,mpeg,mpg,vob,divx,xvid"
        var codecs: [DeviceProfile.Codec] = []
        if preferences.maxWidth > 0 {
            codecs.append(.init(type: "Video", codec: nil, conditions: [
                .init(condition: "LessThanEqual", property: "Width", value: String(preferences.maxWidth), isRequired: false),
            ]))
        }
        let subtitles = ["ass", "ssa", "subrip", "srt", "vtt", "webvtt", "pgssub", "pgs", "dvdsub", "dvbsub", "sub", "smi", "ttml", "mov_text"]
            .flatMap { [DeviceProfile.Subtitle(format: $0, method: "Embed"), DeviceProfile.Subtitle(format: $0, method: "External")] }

        return DeviceProfile(
            name: "jellymc mpv",
            maxStreamingBitrate: preferences.maxBitrate,
            maxStaticBitrate: preferences.maxBitrate,
            musicStreamingTranscodingBitrate: 320_000,
            directPlayProfiles: preferences.forceTranscode ? [] : [
                .init(container: containers, type: "Video", videoCodec: nil, audioCodec: nil),
            ],
            transcodingProfiles: [
                .init(container: "mp4", type: "Video", videoCodec: "hevc,h264", audioCodec: "aac,ac3,eac3,opus,flac",
                      protocol: "hls", context: "Streaming", maxAudioChannels: "8", minSegments: 2, breakOnNonKeyFrames: true,
                      copyTimestamps: nil, enableSubtitlesInManifest: nil),
            ],
            codecProfiles: codecs,
            subtitleProfiles: subtitles
        )
    }
}
