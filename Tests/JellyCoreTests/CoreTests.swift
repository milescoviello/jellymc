import Foundation
import Testing

@testable import JellyCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let client = JellyfinClient(
    baseURL: URL(string: "http://jelly.lan:8096")!,
    device: DeviceIdentity(deviceName: "Test", deviceId: "device-1", version: "0.1.0"),
    token: "secret-token",
    userId: "user-1"
)

/// Recorded from a Jellyfin 12.2 test server: the shapes the app has to read.
struct DecodingTests {
    @Test func decodesAFilmWithEverythingADetailPageAsksFor() throws {
        let item = try JSONCoding.decoder().decode(BaseItem.self, from: fixture("item-sintel"))
        #expect(item.title == "Sintel")
        #expect(item.type == .movie)
        let source = try #require(item.mediaSources?.first)
        #expect(source.container == "mkv")
        #expect(source.videoStream?.codec == "hevc")
        #expect(source.audioStreams.map(\.codec) == ["opus", "aac"])
        #expect(source.subtitleStreams.first?.codec == "ass")
        #expect(item.chapters?.map(\.name) == ["Opening", "The middle", "Credits"])
        #expect(item.chapters?[1].startPositionTicks == 300_000_000)
        let trickplay = try #require(TrickplayFrame.info(for: item, mediaSourceId: source.id))
        #expect(trickplay.width == 320)
        #expect(trickplay.tileWidth == 10)
    }

    @Test func decodesAPageOfItems() throws {
        let page = try JSONCoding.decoder().decode(ItemsPage<BaseItem>.self, from: fixture("items-movies-series"))
        #expect(page.items.count == page.totalRecordCount)
        #expect(page.items.contains { $0.type == .series })
        #expect(page.items.allSatisfy { !$0.id.isEmpty })
    }

    @Test func decodesLibrariesAndServerInfo() throws {
        let views = try JSONCoding.decoder().decode(ItemsPage<BaseItem>.self, from: fixture("user-views"))
        #expect(Set(views.items.compactMap(\.collectionType)) == ["movies", "tvshows", "music"])
        // The app shows films and shows only.
        #expect(views.items.filter(HomeModel.isShown).compactMap(\.collectionType).sorted() == ["movies", "tvshows"])
        let info = try JSONCoding.decoder().decode(PublicSystemInfo.self, from: fixture("system-info-public"))
        #expect(info.version?.hasPrefix("12.") == true)
        #expect(info.startupWizardCompleted == true)
    }

    @Test func anUnknownKindStillDecodes() throws {
        let json = #"{"Id":"x","Type":"SomethingNew","MediaStreams":[{"Type":"Hologram","Index":0}]}"#
        let item = try JSONCoding.decoder().decode(BaseItem.self, from: Data(json.utf8))
        #expect(item.type == ItemKind("SomethingNew"))
        #expect(item.mediaStreams?.first?.type == .unknown)
    }
}

struct JSONCodingTests {
    @Test func readsTheServersSevenDigitFractions() throws {
        let date = try #require(JSONCoding.parseDate("2026-10-18T19:12:34.1234567Z"))
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        #expect(components.hour == 19)
        #expect(components.second == 34)
        #expect(JSONCoding.parseDate("0001-01-01T00:00:00.0000000Z") != nil)
        #expect(JSONCoding.parseDate("2026-10-18T19:12:34Z") != nil)
        #expect(JSONCoding.parseDate("2026-10-18T19:12:34.5") != nil)
    }

    @Test func writesPascalCaseKeys() throws {
        let report = PlaybackReport(
            plan: PlaybackPlan(
                itemId: "i", source: MediaSource(id: "m"), playSessionId: "p", method: .directPlay,
                url: URL(string: "http://x")!, startSeconds: 0, audioIndex: 1, subtitleIndex: nil,
                externalSubtitles: [], transcodeReasons: [], httpHeaders: [:]
            ),
            position: 12.5, isPaused: true
        )
        let json = try #require(String(data: JSONCoding.encoder().encode(report), encoding: .utf8))
        #expect(json.contains(#""PositionTicks":125000000"#))
        #expect(json.contains(#""PlayMethod":"DirectPlay""#))
        #expect(json.contains(#""IsPaused":true"#))
        #expect(!json.contains("positionTicks"))
    }

    @Test func ticks() {
        #expect(Ticks.seconds(10_000_000) == 1)
        #expect(Ticks.from(seconds: 1.5) == 15_000_000)
        #expect(Ticks.clock(3725) == "1:02:05")
        #expect(Ticks.clock(65) == "1:05")
        #expect(Ticks.runtime(6300) == "1h 45m")
    }
}

struct ClientTests {
    @Test func guessesWhatATypedAddressMeans() {
        #expect(JellyfinClient.candidates(for: "192.168.1.148").map(\.absoluteString) == ["http://192.168.1.148:8096", "https://192.168.1.148"])
        #expect(JellyfinClient.candidates(for: "jelly.example.com").map(\.absoluteString) == ["https://jelly.example.com", "http://jelly.example.com:8096"])
        #expect(JellyfinClient.candidates(for: "nas:8920").map(\.absoluteString) == ["http://nas:8920", "https://nas:8920"])
        #expect(JellyfinClient.candidates(for: "https://jelly.example.com/jellyfin/").map(\.absoluteString) == ["https://jelly.example.com/jellyfin"])
        #expect(JellyfinClient.candidates(for: "  ").isEmpty)
    }

    @Test func authorizesWithTheModernHeaderOnly() {
        let header = client.authorization
        #expect(header.hasPrefix("MediaBrowser "))
        #expect(header.contains(#"Client="jellymc""#))
        #expect(header.contains(#"DeviceId="device-1""#))
        #expect(header.contains(#"Token="secret-token""#))
    }

    @Test func playerURLsCarryApiKeyNeverTheLegacySpelling() throws {
        let fresh = try #require(client.authorizedURL("/videos/x/master.m3u8?DeviceId=d&MediaSourceId=m"))
        #expect(fresh.absoluteString.contains("ApiKey=secret-token"))
        let legacy = try #require(client.authorizedURL("videos/x/master.m3u8?api_key=old"))
        #expect(!legacy.absoluteString.contains("api_key"))
        #expect(legacy.absoluteString.contains("ApiKey=old"))
        #expect(!legacy.absoluteString.contains("secret-token"))
    }

    @Test func libraryQuery() {
        var query = ItemQuery()
        query.parentId = "lib"
        query.includeItemTypes = [.movie]
        query.recursive = true
        query.sort = .dateAdded
        query.descending = true
        query.filters = [.unplayed]
        let parameters = query.parameters
        #expect(parameters["sortBy"] == "DateCreated,SortName")
        #expect(parameters["sortOrder"] == "Descending")
        #expect(parameters["filters"] == "IsUnplayed")
        #expect(parameters["includeItemTypes"] == "Movie")
        #expect(parameters["recursive"] == "true")
    }

    @Test func localAddressesAreHome() {
        #expect(AppState.isLocal(host: "192.168.1.148"))
        #expect(AppState.isLocal(host: "10.0.0.2"))
        #expect(AppState.isLocal(host: "172.20.1.1"))
        #expect(AppState.isLocal(host: "nas"))
        #expect(!AppState.isLocal(host: "100.120.68.82"))
        #expect(!AppState.isLocal(host: "jelly.example.com"))
    }
}

struct PlaybackPlanTests {
    private func stream(_ type: MediaStream.Kind, _ index: Int, codec: String, language: String? = nil, external: Bool = false, url: String? = nil) -> MediaStream {
        var stream = MediaStream(type: type, index: index)
        stream.codec = codec
        stream.language = language
        stream.isExternal = external
        if let url {
            stream.deliveryMethod = "External"
            stream.deliveryUrl = url
        }
        return stream
    }

    @Test func directPlayOpensTheStaticFileWithItsKey() throws {
        var source = MediaSource(id: "ms1")
        source.supportsDirectPlay = true
        source.eTag = "etag"
        source.mediaStreams = [stream(.video, 0, codec: "h264"), stream(.audio, 1, codec: "aac", language: "eng")]
        let plan = try PlaybackPlan.make(
            itemId: "item", response: PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps"),
            startSeconds: 42, audioIndex: nil, subtitleIndex: nil, client: client
        )
        #expect(plan.method == .directPlay)
        let url = plan.url.absoluteString
        #expect(url.hasPrefix("http://jelly.lan:8096/Videos/item/stream?"))
        #expect(url.contains("static=true"))
        #expect(url.contains("mediaSourceId=ms1"))
        #expect(url.contains("playSessionId=ps"))
        #expect(url.contains("ApiKey=secret-token"))
        #expect(plan.audioIndex == 1)
        #expect(plan.subtitleIndex == nil)
    }

    @Test func aTranscodeUsesTheServersURLAndSaysWhy() throws {
        var source = MediaSource(id: "ms1")
        source.supportsDirectPlay = false
        source.supportsDirectStream = false
        source.transcodingUrl = "/videos/item/master.m3u8?DeviceId=d&MediaSourceId=ms1&TranscodeReasons=VideoCodecNotSupported,SubtitleCodecNotSupported"
        source.mediaStreams = [
            stream(.video, 0, codec: "hevc"), stream(.audio, 1, codec: "opus"),
            stream(.subtitle, 2, codec: "subrip", external: true, url: "/Videos/item/ms1/Subtitles/2/0/Stream.srt"),
        ]
        let plan = try PlaybackPlan.make(
            itemId: "item", response: PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps"),
            startSeconds: 0, audioIndex: 1, subtitleIndex: 2, client: client
        )
        #expect(plan.method == .transcode)
        #expect(plan.url.absoluteString.contains("master.m3u8"))
        #expect(plan.url.absoluteString.contains("ApiKey=secret-token"))
        #expect(plan.transcodeReasons == ["VideoCodecNotSupported", "SubtitleCodecNotSupported"])
        #expect(plan.reasonSummary == "video codec, subtitle codec")
        #expect(plan.externalSubtitles.map(\.streamIndex) == [2])
        #expect(plan.externalSubtitles.first?.url.absoluteString.contains("ApiKey=secret-token") == true)
    }

    @Test func aRemuxIsDirectStream() throws {
        var source = MediaSource(id: "ms1")
        source.supportsDirectPlay = false
        source.supportsDirectStream = true
        source.transcodingUrl = "/videos/item/master.m3u8?MediaSourceId=ms1"
        let plan = try PlaybackPlan.make(
            itemId: "item", response: PlaybackInfoResponse(mediaSources: [source], playSessionId: nil),
            startSeconds: 0, audioIndex: nil, subtitleIndex: nil, client: client
        )
        #expect(plan.method == .directStream)
    }

    @Test func aRefusalIsAnError() {
        #expect(throws: JellyfinError.self) {
            try PlaybackPlan.make(
                itemId: "item", response: PlaybackInfoResponse(mediaSources: [], playSessionId: nil, errorCode: "NotAllowed"),
                startSeconds: 0, audioIndex: nil, subtitleIndex: nil, client: client
            )
        }
    }
}

struct ProfileTests {
    @Test func avPlayerBurnsInWhatItCannotDraw() {
        let profile = DeviceProfiles.avPlayer(PlaybackPreferences())
        let methods = Dictionary(profile.subtitleProfiles.map { ($0.format, $0.method) }, uniquingKeysWith: { first, _ in first })
        #expect(methods["subrip"] == "Hls")
        #expect(methods["ass"] == "Encode")
        #expect(methods["pgssub"] == "Encode")
        #expect(profile.directPlayProfiles.first?.container == "mp4,m4v,mov")
        #expect(profile.transcodingProfiles.first?.protocol == "hls")

        var flattened = PlaybackPreferences()
        flattened.keepASSStyling = false
        let plain = DeviceProfiles.avPlayer(flattened).subtitleProfiles.first { $0.format == "ass" }
        #expect(plain?.method == "Hls")
    }

    @Test func mpvPlaysEverythingAsItIs() {
        let profile = DeviceProfiles.mpv(PlaybackPreferences())
        let video = profile.directPlayProfiles.first { $0.type == "Video" }
        #expect(video?.container.contains("mkv") == true)
        #expect(video?.videoCodec == nil)
        #expect(profile.subtitleProfiles.contains { $0.format == "pgssub" && $0.method == "Embed" })
        #expect(profile.codecProfiles.isEmpty)
    }

    @Test func forcingATranscodeOffersNoDirectPlay() {
        var preferences = PlaybackPreferences()
        preferences.forceTranscode = true
        #expect(DeviceProfiles.mpv(preferences).directPlayProfiles.isEmpty)
        #expect(DeviceProfiles.avPlayer(preferences).directPlayProfiles.isEmpty)
    }

    @Test func encodesAsTheServerSpellsIt() throws {
        let json = try #require(String(data: JSONCoding.encoder().encode(DeviceProfiles.avPlayer(PlaybackPreferences())), encoding: .utf8))
        #expect(json.contains(#""DirectPlayProfiles""#))
        #expect(json.contains(#""Protocol":"hls""#))
        #expect(json.contains(#""MaxStreamingBitrate""#))
    }
}

struct PreferencesTests {
    private func source() -> MediaSource {
        func make(_ type: MediaStream.Kind, _ index: Int, _ language: String?, forced: Bool = false) -> MediaStream {
            var stream = MediaStream(type: type, index: index)
            stream.language = language
            stream.isForced = forced
            return stream
        }
        var source = MediaSource(id: "m")
        source.mediaStreams = [
            make(.video, 0, nil), make(.audio, 1, "jpn"), make(.audio, 2, "eng"),
            make(.subtitle, 3, "eng", forced: true), make(.subtitle, 4, "eng"),
        ]
        return source
    }

    @Test func smartSubtitlesFollowTheAudio() {
        var preferences = Preferences()
        preferences.preferredSubtitleLanguage = "eng"
        preferences.preferredAudioLanguage = "jpn"
        #expect(preferences.initialTracks(for: source()) == (audio: 1, subtitle: 4))

        preferences.preferredAudioLanguage = "eng"
        #expect(preferences.initialTracks(for: source()) == (audio: 2, subtitle: 3))
    }

    @Test func neverMeansNone() {
        var preferences = Preferences()
        preferences.subtitleMode = .never
        #expect(preferences.initialTracks(for: source()).subtitle == nil)
    }
}

struct TrickplayTests {
    @Test func findsTheTileAndTheCell() throws {
        let info = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 250, interval: 10_000)
        let first = try #require(TrickplayFrame(info: info, seconds: 0))
        #expect(first == TrickplayFrame(tileIndex: 0, x: 0, y: 0, width: 320, height: 180))
        // Thumbnail 123: tile 1, cell 23 = column 3, row 2.
        let later = try #require(TrickplayFrame(info: info, seconds: 1230))
        #expect(later == TrickplayFrame(tileIndex: 1, x: 960, y: 360, width: 320, height: 180))
        // Past the end stays on the last thumbnail.
        let end = try #require(TrickplayFrame(info: info, seconds: 99_999))
        #expect(end.tileIndex == 2)
    }
}

struct CaptionsTests {
    @Test func readsWebVTTAndSRT() {
        let vtt = """
        WEBVTT

        1
        00:00:02.000 --> 00:00:06.000 line:90%
        <i>This is</i> a plain subtitle.

        00:01:10.500 --> 00:01:12.000
        {\\an8}Two
        lines
        """
        let captions = Captions(parsing: vtt)
        #expect(captions.cues.count == 2)
        #expect(captions.text(at: 1) == nil)
        #expect(captions.text(at: 3) == "This is a plain subtitle.")
        #expect(captions.text(at: 71) == "Two\nlines")

        let srt = "1\r\n00:00:02,000 --> 00:00:06,000\r\nComma decimals\r\n\r\n"
        #expect(Captions(parsing: srt).text(at: 2.5) == "Comma decimals")
    }

    @Test func timestamps() {
        #expect(Captions.seconds("01:02:03.456") == 3723.456)
        #expect(Captions.seconds("02:03.5") == 123.5)
        #expect(Captions.seconds("nonsense") == nil)
    }

    @Test func asksTheServerForWebVTT() {
        let subtitle = ExternalSubtitle(
            streamIndex: 0,
            url: URL(string: "http://jelly.lan:8096/Videos/x/y/Subtitles/0/0/Stream.subrip?ApiKey=k")!,
            title: "English", language: "eng", codec: "subrip"
        )
        #expect(subtitle.webVTTURL.absoluteString == "http://jelly.lan:8096/Videos/x/y/Subtitles/0/0/Stream.vtt?ApiKey=k")
    }
}

struct DownloadPlannerTests {
    private func item(container: String, video: String, audio: String, subtitles: [(String, Bool)] = []) -> BaseItem {
        var source = MediaSource(id: "ms")
        source.container = container
        source.bitrate = 8_000_000
        var videoStream = MediaStream(type: .video, index: 0)
        videoStream.codec = video
        var audioStream = MediaStream(type: .audio, index: 1)
        audioStream.codec = audio
        var streams: [MediaStream] = [videoStream, audioStream]
        for (offset, subtitle) in subtitles.enumerated() {
            var stream = MediaStream(type: .subtitle, index: 2 + offset)
            stream.codec = subtitle.0
            stream.isTextSubtitleStream = subtitle.1
            streams.append(stream)
        }
        source.mediaStreams = streams
        var item = BaseItem(id: "film")
        item.mediaSources = [source]
        return item
    }

    @Test func keepsWhatThePlayerCanOpenAndConvertsTheRest() {
        #expect(DownloadPlanner.quality(for: item(container: "mov,mp4,m4a", video: "h264", audio: "aac"), player: .avPlayer) == .original)
        #expect(DownloadPlanner.quality(for: item(container: "mkv", video: "hevc", audio: "opus"), player: .avPlayer) == .converted(bitrate: 8_000_000))
        #expect(DownloadPlanner.quality(for: item(container: "mkv", video: "hevc", audio: "truehd"), player: .mpv) == .original)
    }

    @Test func asksForTheRightFiles() throws {
        let film = item(container: "mkv", video: "hevc", audio: "opus", subtitles: [("subrip", true), ("pgssub", false)])
        let record = DownloadRecord(item: film, mediaSourceId: "ms", quality: .converted(bitrate: 6_000_000), state: .queued, addedAt: Date())
        let url = try #require(DownloadPlanner.url(for: record, client: client)).absoluteString
        #expect(url.contains("/Videos/film/stream.mp4?"))
        #expect(url.contains("videoCodec=hevc"))
        #expect(url.contains("videoBitRate=6000000"))
        #expect(url.contains("ApiKey=secret-token"))
        var original = record
        original.quality = .original
        #expect(DownloadPlanner.url(for: original, client: client)?.absoluteString.contains("/Items/film/Download?ApiKey=") == true)
        // Text subtitles come along as WebVTT; image ones cannot.
        let subtitles = DownloadPlanner.subtitleURLs(for: record, client: client)
        #expect(subtitles.map(\.0.index) == [2])
        #expect(subtitles.first?.1.absoluteString.contains("/Subtitles/2/0/Stream.vtt") == true)
    }
}

@MainActor
struct OutboxTests {
    private func outbox() -> Outbox {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        return Outbox(file: file)
    }

    @Test func theLatestPlaceWinsAndOverridesTheServers() {
        let outbox = outbox()
        var film = BaseItem(id: "film")
        film.runTimeTicks = Ticks.from(seconds: 1000)
        film.userData = UserItemData(playbackPositionTicks: Ticks.from(seconds: 100), isFavorite: true)
        outbox.add(itemId: "film", position: 200, duration: 1000)
        outbox.add(itemId: "film", position: 300, duration: 1000)
        #expect(outbox.entries.count == 1)
        #expect(outbox.position(for: "film") == 300)
        let shown = outbox.applying(to: film)
        #expect(shown.resumeSeconds == 300)
        #expect(shown.isFavorite)
        #expect(!shown.isPlayed)
        #expect(outbox.applying(to: BaseItem(id: "other")) == BaseItem(id: "other"))
    }

    @Test func nearlyTheEndCountsAsWatched() {
        let outbox = outbox()
        outbox.add(itemId: "film", position: 950, duration: 1000)
        let shown = outbox.applying(to: BaseItem(id: "film"))
        #expect(shown.isPlayed)
        #expect(shown.resumeSeconds == 0)
    }

    @Test func keepsWhatItHasAcrossLaunches() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        Outbox(file: file).add(itemId: "film", position: 42, duration: 1000)
        #expect(Outbox(file: file).position(for: "film") == 42)
    }
}

struct DownloadRecordTests {
    @Test func saysWhatItIs() {
        var episode = BaseItem(id: "e1")
        episode.type = .episode
        episode.name = "Pilot"
        episode.seriesName = "Pioneer One"
        episode.parentIndexNumber = 1
        episode.indexNumber = 2
        var record = DownloadRecord(item: episode, mediaSourceId: "ms", quality: .converted(bitrate: 8_000_000), state: .downloading, progress: 0.42, addedAt: Date())
        #expect(record.title.hasPrefix("Pioneer One · "))
        #expect(record.title.hasSuffix("Pilot"))
        #expect(record.status == "Downloading · 42%")
        record.state = .done
        #expect(record.status == "Converted, 8 Mbps")
        record.state = .failed("No space")
        #expect(record.status == "Failed: No space")
    }
}
