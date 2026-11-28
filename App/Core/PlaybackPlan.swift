import Foundation

/// `POST /Items/{id}/PlaybackInfo`'s body.
struct PlaybackInfoRequest: Encodable, Sendable {
    var userId: String?
    var maxStreamingBitrate: Int?
    var startTimeTicks: Int64?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var mediaSourceId: String?
    var deviceProfile: DeviceProfile
    var enableDirectPlay = true
    var enableDirectStream = true
    var enableTranscoding = true
    var allowVideoStreamCopy = true
    var allowAudioStreamCopy = true
    var autoOpenLiveStream = true
    var alwaysBurnInSubtitleWhenTranscoding = false
}

enum PlayMethod: String, Codable, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"

    var title: String {
        switch self {
        case .directPlay: return "Direct Play"
        case .directStream: return "Direct Stream"
        case .transcode: return "Transcode"
        }
    }
}

/// A subtitle the player loads from its own URL, alongside the video.
struct ExternalSubtitle: Sendable, Equatable {
    var streamIndex: Int
    var url: URL
    var title: String
    var language: String?
    var codec: String?
}

/// What the player opens, decided from the server's answer: the URL, how it plays, and
/// which tracks are where.
struct PlaybackPlan: Sendable, Equatable {
    var itemId: String
    var source: MediaSource
    var playSessionId: String?
    var method: PlayMethod
    var url: URL
    var startSeconds: Double
    var audioIndex: Int?
    var subtitleIndex: Int?
    var externalSubtitles: [ExternalSubtitle]
    /// From the transcoding URL: why the server would not send the file as it is.
    var transcodeReasons: [String]
    var httpHeaders: [String: String]

    var audioStreams: [MediaStream] { source.audioStreams }
    var subtitleStreams: [MediaStream] { source.subtitleStreams }

    /// Picks the media source and the way to play it, as the server allowed.
    ///
    /// The server has already applied the device profile: `SupportsDirectPlay` means the
    /// file plays as it is; otherwise `TranscodingUrl` is the stream it prepared, a remux
    /// when `SupportsDirectStream` is set and a transcode when not.
    static func make(
        itemId: String,
        response: PlaybackInfoResponse,
        mediaSourceId: String? = nil,
        startSeconds: Double,
        audioIndex: Int?,
        subtitleIndex: Int?,
        client: JellyfinClient
    ) throws -> PlaybackPlan {
        if let code = response.errorCode {
            throw JellyfinError(kind: .http(403), message: message(forErrorCode: code))
        }
        guard let source = response.mediaSources.first(where: { $0.id == mediaSourceId }) ?? response.mediaSources.first else {
            throw JellyfinError(kind: .decoding, message: "The server offered nothing to play.")
        }

        let method: PlayMethod
        let url: URL?
        var reasons: [String] = []
        if source.supportsDirectPlay == true {
            method = .directPlay
            url = client.directStreamURL(itemId: itemId, mediaSourceId: source.id, playSessionId: response.playSessionId, tag: source.eTag)
        } else if let transcodingURL = source.transcodingUrl {
            method = source.supportsDirectStream == true ? .directStream : .transcode
            url = client.authorizedURL(transcodingURL)
            reasons = transcodeReasons(in: transcodingURL)
        } else {
            throw JellyfinError(kind: .http(415), message: "The server can neither send this file as it is nor convert it.")
        }
        guard let url else { throw JellyfinError(kind: .badURL, message: "Could not build the stream address.") }

        let externals: [ExternalSubtitle] = source.subtitleStreams.compactMap { stream in
            guard stream.deliveryMethod == "External", let path = stream.deliveryUrl, let url = client.authorizedURL(path) else { return nil }
            return ExternalSubtitle(streamIndex: stream.index, url: url, title: stream.label, language: stream.language, codec: stream.codec)
        }

        return PlaybackPlan(
            itemId: itemId,
            source: source,
            playSessionId: response.playSessionId,
            method: method,
            url: url,
            startSeconds: startSeconds,
            audioIndex: audioIndex ?? source.defaultAudioStreamIndex ?? source.audioStreams.first?.index,
            subtitleIndex: subtitleIndex ?? source.defaultSubtitleStreamIndex.flatMap { $0 >= 0 ? $0 : nil },
            externalSubtitles: externals,
            transcodeReasons: reasons,
            httpHeaders: source.requiredHttpHeaders ?? [:]
        )
    }

    /// One line for the log: how it plays, and where each chosen track comes from.
    var logSummary: String {
        var parts = [method.title]
        let container = source.container ?? "?"
        parts.append(method == .directPlay ? container : "\(container) as \(source.transcodingContainer ?? "?") over \(source.transcodingSubProtocol ?? "http")")
        if let video = source.videoStream {
            parts.append("video \(video.codec ?? "?") \(video.width ?? 0)x\(video.height ?? 0)")
        }
        if let index = audioIndex, let audio = source.audioStreams.first(where: { $0.index == index }) {
            parts.append("audio #\(index) \(audio.codec ?? "?") \(audio.language ?? "und")")
        }
        if let index = subtitleIndex, let subtitle = source.subtitleStreams.first(where: { $0.index == index }) {
            let delivery = externalSubtitles.contains { $0.streamIndex == index } ? "drawn by the app" : (subtitle.deliveryMethod ?? "?")
            parts.append("subtitle #\(index) \(subtitle.codec ?? "?") \(subtitle.language ?? "und") \(delivery)")
        } else {
            parts.append("no subtitle")
        }
        parts.append("from \(Ticks.clock(startSeconds))")
        if !transcodeReasons.isEmpty { parts.append("because \(reasonSummary)") }
        return parts.joined(separator: ", ")
    }

    static func transcodeReasons(in url: String) -> [String] {
        guard let components = URLComponents(string: url.hasPrefix("http") ? url : "http://x" + (url.hasPrefix("/") ? url : "/" + url)),
              let value = components.queryItems?.first(where: { $0.name.lowercased() == "transcodereasons" })?.value
        else { return [] }
        return value.split(separator: ",").map(String.init)
    }

    static func message(forErrorCode code: String) -> String {
        switch code {
        case "NotAllowed": return "This account is not allowed to play this."
        case "NoCompatibleStream": return "The server found no way to play this on this device."
        case "RateLimitExceeded": return "The server is limiting how much can stream at once."
        default: return "The server refused to play this (\(code))."
        }
    }

    /// The server's reasons, readable: "VideoCodecNotSupported" becomes "video codec".
    /// Whether the server sends the file's own video, repackaged: true for a remux even
    /// when the server marks the source `SupportsDirectStream: false`, which it does for
    /// an MKV it remuxes to HLS (its session then reports `IsVideoDirect`). Only a reason
    /// about the video itself, or a subtitle to burn in, means re-encoding.
    var videoIsCopied: Bool {
        guard method == .transcode else { return true }
        let encodes = ["RefFramesNotSupported", "AnamorphicVideoNotSupported", "InterlacedVideoNotSupported", "UnknownVideoStreamInfo"]
        return !transcodeReasons.contains { $0.hasPrefix("Video") || $0.hasPrefix("Subtitle") || encodes.contains($0) }
    }

    /// How the play method reads in the stats panel: a remux is not a transcode.
    var methodTitle: String {
        if method == .transcode, videoIsCopied { return "Remux" }
        return method.title
    }

    var reasonSummary: String {
        transcodeReasons.map { reason in
            var words = ""
            for character in reason.replacingOccurrences(of: "NotSupported", with: "") {
                if character.isUppercase, !words.isEmpty { words += " " }
                words.append(character)
            }
            return words.lowercased()
        }.joined(separator: ", ")
    }
}

/// The body of every `/Sessions/Playing*` report.
struct PlaybackReport: Encodable, Sendable, Equatable {
    var itemId: String
    var mediaSourceId: String?
    var playSessionId: String?
    var positionTicks: Int64
    var isPaused: Bool
    var isMuted = false
    var canSeek = true
    var playMethod: PlayMethod
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var playbackRate: Double?
    var repeatMode = "RepeatNone"
    var playbackOrder = "Default"

    init(plan: PlaybackPlan, position: Double, isPaused: Bool) {
        itemId = plan.itemId
        mediaSourceId = plan.source.id
        playSessionId = plan.playSessionId
        positionTicks = Ticks.from(seconds: position)
        self.isPaused = isPaused
        playMethod = plan.method
        audioStreamIndex = plan.audioIndex
        subtitleStreamIndex = plan.subtitleIndex
    }
}
