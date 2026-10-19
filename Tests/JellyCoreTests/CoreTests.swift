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
        #expect(Ticks.runtime(6300) == "1 hr 45 min")
        #expect(Ticks.runtime(7200) == "2 hr")
        #expect(Ticks.runtime(2520) == "42 min")
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

    @Test func estimatesAConversionsSize() {
        var film = item(container: "mkv", video: "hevc", audio: "opus")
        film.runTimeTicks = Ticks.from(seconds: 3600)
        var record = DownloadRecord(item: film, mediaSourceId: "ms", quality: .converted(bitrate: 8_000_000), state: .downloading, addedAt: Date())
        // 8 Mbps for an hour is 3.6 GB.
        #expect(DownloadPlanner.expectedBytes(for: record) == 3_600_000_000)
        record.quality = .original
        #expect(DownloadPlanner.expectedBytes(for: record) == nil)
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

struct MP4Tests {
    /// The start of a real Jellyfin 12.2 direct stream: Sintel's HEVC copied out of MKV,
    /// tagged hev1, which AVPlayer will not open.
    private func serverHead() throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: "converted-hevc-head", withExtension: "mp4", subdirectory: "Fixtures"))
        return Array(try Data(contentsOf: url))
    }

    private func count(_ tag: String, in bytes: [UInt8]) -> Int {
        let needle = Array(tag.utf8)
        return (0 ... bytes.count - needle.count).filter { Array(bytes[$0 ..< $0 + 4]) == needle }.count
    }

    @Test func retagsTheServersHEVCForAVPlayer() throws {
        var bytes = try serverHead()
        #expect(count("hev1", in: bytes) == 1)
        let changed = MP4.retag(&bytes, in: 0 ..< bytes.count)
        #expect(changed.count == 1)
        #expect(count("hev1", in: bytes) == 0)
        #expect(count("hvc1", in: bytes) == 1)
        // Nothing else moves.
        #expect(bytes.count == (try serverHead()).count)
    }

    @Test func fixesTheFileInPlaceOnce() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("retag-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        // The header, then a media box of filler, as the download would have it.
        var data = Data(try serverHead())
        data.append(contentsOf: [0, 0, 0, 16] + Array("mdat".utf8) + [UInt8](repeating: 7, count: 8))
        try data.write(to: file)
        #expect(try MP4.retagHEVC(at: file) == 1)
        let fixed = Array(try Data(contentsOf: file))
        #expect(count("hvc1", in: fixed) == 1)
        #expect(fixed.count == data.count)
        #expect(Array(fixed.suffix(8)) == [UInt8](repeating: 7, count: 8))
        #expect(try MP4.retagHEVC(at: file) == 0)
    }

    @Test func leavesAnythingElseAlone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("retag-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: file) }
        let junk = Data([0x1a, 0x45, 0xdf, 0xa3] + [UInt8](repeating: 0xff, count: 60))
        try junk.write(to: file)
        #expect(try MP4.retagHEVC(at: file) == 0)
        #expect(try Data(contentsOf: file) == junk)
        var truncated = Array(try serverHead().prefix(200))
        #expect(MP4.retag(&truncated, in: 0 ..< truncated.count).isEmpty)
    }
}

@MainActor
struct SessionPreviewTests {
    /// An engine that plays nothing: the session only needs somewhere to send the file.
    private final class StillEngine: PlayerEngine {
        let kind = PlayerKind.mpv
        var onEvent: (@MainActor (PlayerEvent) -> Void)?
        func load(_ plan: PlaybackPlan) {}
        func play() {}
        func pause() {}
        func seek(to seconds: Double) {}
        func setRate(_ rate: Double) {}
        func selectAudio(_ streamIndex: Int, in plan: PlaybackPlan) -> Bool { true }
        func selectSubtitle(_ streamIndex: Int?, in plan: PlaybackPlan) -> Bool { true }
        func stop() {}
    }

    @Test func previewsComeFromThePlayingSourcesTiles() async throws {
        // Nothing listens there: the session falls back on the item it was given.
        let nowhere = JellyfinClient(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            device: DeviceIdentity(deviceName: "Test", deviceId: "device-1", version: "0.1.0"),
            token: "secret-token", userId: "user-1"
        )
        var film = BaseItem(id: "film")
        film.trickplay = ["ms": ["320": TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 250, interval: 10_000)]]
        let session = PlaybackSession(item: film, client: nowhere, engine: StillEngine(), preferences: PlaybackPreferences())
        let plan = PlaybackPlan(
            itemId: "film", source: MediaSource(id: "ms"), playSessionId: nil, method: .directPlay,
            url: URL(fileURLWithPath: "/nonexistent/film.mkv"), startSeconds: 0, audioIndex: nil, subtitleIndex: nil,
            externalSubtitles: [], transcodeReasons: [], httpHeaders: [:]
        )
        #expect(session.preview(at: 10) == nil)
        await session.start(at: 0, local: plan)
        for _ in 0 ..< 150 where session.trickplay == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let preview = try #require(session.preview(at: 1230))
        #expect(preview.frame == TrickplayFrame(tileIndex: 1, x: 960, y: 360, width: 320, height: 180))
        #expect(preview.tile.absoluteString.contains("/Videos/film/Trickplay/320/1.jpg?mediaSourceId=ms"))
        #expect(preview.tile.absoluteString.contains("ApiKey=secret-token"))
    }
}

struct PreferencesStorageTests {
    @Test func survivesARestart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("preferences-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(Preferences.load(from: file) == Preferences())
        var preferences = Preferences()
        preferences.autoplayNext = false
        preferences.preferredAudioLanguage = "jpn"
        preferences.save(to: file)
        #expect(Preferences.load(from: file) == preferences)
    }
}

struct ServerMessageTests {
    private func decode(_ json: String) -> ServerMessage? {
        ServerMessage.decode(Data(json.utf8))
    }

    @Test func readsWhatJellyfinSends() throws {
        // Both as a 12.2 server sent them to the test socket.
        #expect(decode(#"{"MessageId":"416cf1d220a948ff955a851ffe38b4fb","Data":60,"MessageType":"ForceKeepAlive"}"#) == .forceKeepAlive(seconds: 60))
        let changed = decode(#"""
        {"MessageId":"c85e","Data":{"UserId":"8cbc","UserDataList":[{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":true,"Key":"10378","ItemId":"4216"},{"PlayedPercentage":50,"UnplayedItemCount":2,"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false,"Key":"x","ItemId":"series"}]},"MessageType":"UserDataChanged"}
        """#)
        #expect(changed == .userDataChanged([
            UserDataChange(itemId: "4216", playbackPositionTicks: 0, played: true, isFavorite: false),
            UserDataChange(itemId: "series", playbackPositionTicks: 0, played: false, isFavorite: false),
        ]))
    }

    @Test func readsRemoteControl() throws {
        let play = decode(#"{"MessageType":"Play","Data":{"ItemIds":["a","b"],"StartPositionTicks":600000000,"PlayCommand":"PlayNow","StartIndex":1,"AudioStreamIndex":2}}"#)
        guard case let .play(request) = play else { Issue.record("\(String(describing: play))"); return }
        #expect(request.itemId == "b")
        #expect(request.start == 60)
        #expect(request.audioStreamIndex == 2)
        #expect(decode(#"{"MessageType":"Playstate","Data":{"Command":"Seek","SeekPositionTicks":300000000}}"#)
            == .playstate(RemotePlaystate(command: "Seek", seekPositionTicks: 300_000_000)))
        let message = decode(#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayMessage","Arguments":{"Header":"Hi","Text":"From the phone","TimeoutMs":"5000"}}}"#)
        guard case let .command(command) = message else { Issue.record("\(String(describing: message))"); return }
        #expect(command.name == "DisplayMessage")
        #expect(command.argument("Header") == "Hi")
        #expect(command.argument("text") == "From the phone")
        #expect(decode(#"{"MessageType":"LibraryChanged","Data":{"ItemsAdded":["x"]}}"#) == .libraryChanged)
        #expect(decode(#"{"MessageType":"ScheduledTaskEnded","Data":{}}"#) == .other("ScheduledTaskEnded"))
        #expect(decode("not json") == nil)
    }

    @Test func socketFollowsTheAddress() {
        #expect(client.socketURL?.absoluteString == "ws://jelly.lan:8096/socket?deviceId=device-1")
        let secure = JellyfinClient(baseURL: URL(string: "https://media.example.com/jellyfin/")!, device: client.device)
        #expect(secure.socketURL?.absoluteString == "wss://media.example.com/jellyfin/socket?deviceId=device-1")
    }
}

struct PlexLayoutTests {
    private func episode(_ id: String, series: String, played: Date? = nil, position: Int64 = 0) -> BaseItem {
        var item = BaseItem(id: id)
        item.type = .episode
        item.seriesId = series
        item.userData = UserItemData(playbackPositionTicks: position, lastPlayedDate: played)
        return item
    }

    @Test func continueWatchingIsOneRowNewestFirstOneEpisodePerShow() {
        let old = episode("a2", series: "a", played: Date(timeIntervalSince1970: 100), position: 50)
        let new = episode("b5", series: "b", played: Date(timeIntervalSince1970: 200), position: 50)
        var film = BaseItem(id: "film")
        film.type = .movie
        film.userData = UserItemData(playbackPositionTicks: 10, lastPlayedDate: Date(timeIntervalSince1970: 150))
        // An older episode of show b started too; next up has b, and c twice.
        let older = episode("b4", series: "b", played: Date(timeIntervalSince1970: 50), position: 50)
        let row = Hubs.continueWatching(
            resume: [old, new, film, older],
            nextUp: [episode("b6", series: "b"), episode("c1", series: "c"), episode("c2", series: "c")]
        )
        #expect(row.map(\.id) == ["b5", "film", "a2", "c1"])
    }

    @Test func cornersSayWhatIsLeft() {
        var film = BaseItem(id: "f")
        film.type = .movie
        #expect(Presentation.unwatched(film) == .mark)
        film.userData = UserItemData(playbackPositionTicks: 100)
        #expect(Presentation.unwatched(film) == .none)
        film.userData = UserItemData(played: true)
        #expect(Presentation.unwatched(film) == .none)
        var show = BaseItem(id: "s")
        show.type = .series
        show.userData = UserItemData(unplayedItemCount: 4)
        #expect(Presentation.unwatched(show) == .count(4))
    }

    @Test func detailsReadLikePlex() {
        var film = BaseItem(id: "f")
        film.type = .movie
        film.productionYear = 2010
        film.officialRating = "PG-13"
        film.runTimeTicks = Ticks.from(seconds: 6300)
        film.communityRating = 7.4
        film.criticRating = 85
        film.people = [
            Person(id: "1", name: "Actor One", role: "Hero", type: "Actor"),
            Person(id: "2", name: "Dee Rector", type: "Director"),
            Person(id: "3", name: "Rita Writer", type: "Writer"),
        ]
        film.studios = [NameIdPair(name: "Blender", id: "b")]
        let meta = Presentation.metaLine(film, now: Date(timeIntervalSince1970: 0))
        #expect(meta.hasPrefix("2010 · 1 hr 45 min · PG-13 · Ends at "))
        #expect(Presentation.ratings(film) == ["★ 7.4", "🍅 85%"])
        let credits = Presentation.credits(film)
        #expect(credits.map(\.title) == ["Directed by", "Written by", "Studio"])
        #expect(credits.first?.names == "Dee Rector")
        #expect(Presentation.castAndCrew(film).map(\.id) == ["1", "2", "3"])
    }

    @Test func recommendationsGetPlexTitles() {
        func title(_ type: String) -> String? {
            Recommendation(items: [], recommendationType: type, baselineItemName: "Sintel").title
        }
        #expect(title("SimilarToRecentlyPlayed") == "Because You Watched Sintel")
        #expect(title("HasDirectorFromRecentlyPlayed") == "Top Movies by Sintel")
        #expect(title("HasLikedActor") == "Top Movies Starring Sintel")
        #expect(title("Unknown") == nil)
    }

    @Test @MainActor func seeAllKeepsTheRowsOrder() {
        let browse = Browse(title: "Recently Added", libraryId: "lib", itemTypes: [.movie], sort: .dateAdded)
        #expect(browse.isDescending)
        let model = LibraryModel(browse: browse)
        #expect(model.sort == .dateAdded)
        #expect(model.descending)
        #expect(!model.isAlphabetical)
        #expect(LibraryModel(browse: Browse(title: "All", libraryId: "lib", itemTypes: [.movie])).isAlphabetical)
    }
}

struct PlayButtonTests {
    @Test func saysWhatItPlays() {
        var film = BaseItem(id: "f")
        film.type = .movie
        film.name = "Sintel"
        var collection = BaseItem(id: "c")
        collection.type = .boxSet
        #expect(Presentation.playLabel(for: film, on: collection) == "Play Sintel")
        #expect(Presentation.playLabel(for: film, on: film) == "Play")
        film.userData = UserItemData(playbackPositionTicks: Ticks.from(seconds: 90))
        #expect(Presentation.playLabel(for: film, on: film) == "Resume 1:30")
        var episode = BaseItem(id: "e")
        episode.type = .episode
        episode.parentIndexNumber = 1
        episode.indexNumber = 3
        var show = BaseItem(id: "s")
        show.type = .series
        #expect(Presentation.playLabel(for: episode, on: show) == "Play S1:E3")
    }
}

@MainActor
struct StillWatchingTests {
    private final class CountingEngine: PlayerEngine {
        let kind = PlayerKind.mpv
        var onEvent: (@MainActor (PlayerEvent) -> Void)?
        var pauses = 0
        var plays = 0
        func load(_ plan: PlaybackPlan) {}
        func play() { plays += 1 }
        func pause() { pauses += 1 }
        func seek(to seconds: Double) {}
        func setRate(_ rate: Double) {}
        func selectAudio(_ streamIndex: Int, in plan: PlaybackPlan) -> Bool { true }
        func selectSubtitle(_ streamIndex: Int?, in plan: PlaybackPlan) -> Bool { true }
        func stop() {}
    }

    private let nowhere = JellyfinClient(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        device: DeviceIdentity(deviceName: "Test", deviceId: "device-1", version: "0.1.0"),
        token: "t", userId: "u"
    )

    private func plan() -> PlaybackPlan {
        PlaybackPlan(
            itemId: "e", source: MediaSource(id: "ms"), playSessionId: nil, method: .directPlay,
            url: URL(fileURLWithPath: "/nonexistent/e.mkv"), startSeconds: 0, audioIndex: nil, subtitleIndex: nil,
            externalSubtitles: [], transcodeReasons: [], httpHeaders: [:]
        )
    }

    @Test func asksAfterThreeInARowAndCountsOnlyWhatNobodyStarted() async {
        var episode = BaseItem(id: "e")
        episode.type = .episode
        let engine = CountingEngine()
        let third = PlaybackSession(item: episode, client: nowhere, engine: engine, preferences: PlaybackPreferences(), continuing: .init(autoplayed: 3))
        await third.start(at: 0, local: plan())
        #expect(third.isAskingStillWatching)
        // The pause comes with the first frame, not before it.
        #expect(engine.pauses == 0)
        engine.onEvent?(.position(0.1, duration: 330))
        #expect(engine.pauses == 1)
        engine.onEvent?(.position(0.2, duration: 330))
        #expect(engine.pauses == 1)
        third.keepWatching()
        #expect(!third.isAskingStillWatching)
        #expect(engine.plays == 1)
        third.stop()

        let second = PlaybackSession(item: episode, client: nowhere, engine: CountingEngine(), preferences: PlaybackPreferences(), continuing: .init(autoplayed: 2))
        await second.start(at: 0, local: plan())
        #expect(!second.isAskingStillWatching)
        var handedOn: [Int] = []
        second.onPlayNext = { _, next in handedOn.append(next.autoplayed) }
        second.playNext(BaseItem(id: "next"), automatic: true)
        #expect(handedOn == [3])
        let chosen = PlaybackSession(item: episode, client: nowhere, engine: CountingEngine(), preferences: PlaybackPreferences(), continuing: .init(autoplayed: 2))
        await chosen.start(at: 0, local: plan())
        chosen.onPlayNext = { _, next in handedOn.append(next.autoplayed) }
        chosen.playNext(BaseItem(id: "next"))
        #expect(handedOn == [3, 0])
    }
}

@MainActor
struct QueueTests {
    private final class SilentEngine: PlayerEngine {
        let kind = PlayerKind.mpv
        var onEvent: (@MainActor (PlayerEvent) -> Void)?
        func load(_ plan: PlaybackPlan) {}
        func play() {}
        func pause() {}
        func seek(to seconds: Double) {}
        func setRate(_ rate: Double) {}
        func selectAudio(_ streamIndex: Int, in plan: PlaybackPlan) -> Bool { true }
        func selectSubtitle(_ streamIndex: Int?, in plan: PlaybackPlan) -> Bool { true }
        func stop() {}
    }

    @Test func aQueueIsWhatComesNextAndShrinks() async throws {
        let nowhere = JellyfinClient(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            device: DeviceIdentity(deviceName: "Test", deviceId: "device-1", version: "0.1.0"),
            token: "t", userId: "u"
        )
        let queue = [BaseItem(id: "b"), BaseItem(id: "c")]
        let session = PlaybackSession(
            item: BaseItem(id: "a"), client: nowhere, engine: SilentEngine(), preferences: PlaybackPreferences(),
            continuing: .init(queue: queue)
        )
        let plan = PlaybackPlan(
            itemId: "a", source: MediaSource(id: "ms"), playSessionId: nil, method: .directPlay,
            url: URL(fileURLWithPath: "/nonexistent/a.mkv"), startSeconds: 0, audioIndex: nil, subtitleIndex: nil,
            externalSubtitles: [], transcodeReasons: [], httpHeaders: [:]
        )
        await session.start(at: 0, local: plan)
        for _ in 0 ..< 150 where session.next == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(session.next?.id == "b")
        var handed: [(String, [String])] = []
        session.onPlayNext = { item, next in handed.append((item.id, next.queue.map(\.id))) }
        session.playNext(try #require(session.next), automatic: true)
        #expect(handed.first?.0 == "b")
        #expect(handed.first?.1 == ["c"])
    }

    @Test @MainActor func shuffleAndPlayAllFollowPlex() {
        let model = ItemModel(id: "c")
        var films: [BaseItem] = (1 ... 4).map { index in
            var film = BaseItem(id: "f\(index)")
            film.type = .movie
            return film
        }
        films[0].userData = UserItemData(played: true)
        // The rest of the collection after the one Play starts.
        #expect(Queues.after(films[1], in: films).map(\.id) == ["f3", "f4"])
        #expect(Queues.after(BaseItem(id: "elsewhere"), in: films).isEmpty)
        let shuffled = Queues.shuffle(films)
        #expect(Set(shuffled.map(\.id)) == Set(films.map(\.id)))
        _ = model
    }
}

struct PlaylistTests {
    @Test func playlistsAreALibraryOfTheirOwn() {
        var view = BaseItem(id: "p")
        view.collectionType = "playlists"
        #expect(HomeModel.isShown(view))
        #expect(!HomeModel.showsLatest(view))
        #expect(libraryItemTypes(view) == [.playlist])
        var playlist = BaseItem(id: "pl")
        playlist.type = .playlist
        #expect(Presentation.playLabel(for: BaseItem(id: "f"), on: playlist) == "Play")
    }
}

@MainActor
struct SleepTimerTests {
    @Test func timesOutAndStopsAtTheEnd() async throws {
        let timer = SleepTimer()
        var fired = 0
        timer.onFire = { fired += 1 }
        let now = Date(timeIntervalSince1970: 1000)
        timer.set(.thirty, now: now)
        #expect(timer.deadline == now.addingTimeInterval(1800))
        #expect(!timer.itemEnded())
        timer.set(.endOfItem)
        #expect(timer.deadline == nil)
        #expect(timer.itemEnded())
        #expect(fired == 1)
        #expect(timer.choice == .off)
        #expect(!timer.itemEnded())
        timer.set(.fifteen)
        timer.set(.off)
        #expect(timer.deadline == nil)
        #expect(fired == 1)
    }
}

struct LibraryFilterTests {
    @Test func decadesAndQueries() throws {
        let filters = LibraryFilters(genres: ["Animation"], officialRatings: ["PG"], years: [2006, 2008, 2010, 2012, 1999])
        #expect(filters.decades == [2010, 2000, 1990])
        var query = ItemQuery()
        query.years = Array(2000 ..< 2010)
        query.officialRatings = ["PG", "G"]
        query.is4K = false
        query.isHD = true
        let parameters = query.parameters
        #expect(parameters["years"] == "2000,2001,2002,2003,2004,2005,2006,2007,2008,2009")
        #expect(parameters["officialRatings"] == "PG|G")
        #expect(parameters["is4K"] == "false")
        #expect(parameters["isHd"] == "true")
    }

    @Test @MainActor func filtersCountAndClear() {
        let model = LibraryModel(browse: Browse(title: "Action", libraryId: "l", itemTypes: [.movie], genre: "Action"))
        #expect(model.activeFilters == 0)
        model.decade = 1990
        model.filter = .unplayed
        model.genre = "Drama"
        #expect(model.activeFilters == 3)
        model.clearFilters()
        #expect(model.activeFilters == 0)
        #expect(model.genre == "Action")
    }
}

struct PreferencesUpgradeTests {
    @Test func readsWhatAnOlderAppSaved() throws {
        // As 1.0's predecessor saved it: no subtitleSize, and an unknown mode.
        let old = #"{"autoplayNext":false,"subtitleMode":"sometimes","localPlayback":{"maxBitrate":20000000,"maxWidth":0,"keepASSStyling":true,"forceTranscode":false},"segmentActions":[]}"#
        let read = try JSONDecoder().decode(Preferences.self, from: Data(old.utf8))
        #expect(read.autoplayNext == false)
        #expect(read.localPlayback.maxBitrate == 20_000_000)
        #expect(read.remotePlayback == Preferences().remotePlayback)
        #expect(read.subtitleMode == .smart)
        #expect(read.subtitleSize == .normal)
        var changed = read
        changed.subtitleSize = .large
        let again = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed))
        #expect(again == changed)
    }
}

struct CardLinesTests {
    @Test func episodesAndSeasonsReadLikePlex() {
        var episode = BaseItem(id: "e")
        episode.type = .episode
        episode.name = "The Lighthouse"
        episode.seriesName = "Harbour Lights"
        episode.parentIndexNumber = 2
        episode.indexNumber = 3
        #expect(Presentation.cardLines(episode, style: .poster) == ("Harbour Lights", "S2 · E3"))
        #expect(Presentation.cardLines(episode, style: .landscape) == ("Harbour Lights", "S2 · E3 · The Lighthouse"))
        var season = BaseItem(id: "s")
        season.type = .season
        season.name = "Season 1"
        season.seriesName = "Harbour Lights"
        season.childCount = 5
        #expect(Presentation.cardLines(season, style: .poster) == ("Harbour Lights", "Season 1 · 5 episodes"))
        #expect(Presentation.cardLines(season, style: .poster, onParent: true) == ("Season 1", "5 episodes"))
        var film = BaseItem(id: "f")
        film.type = .movie
        film.name = "Sintel"
        film.productionYear = 2010
        #expect(Presentation.cardLines(film, style: .poster) == ("Sintel", "2010"))
    }
}

struct PlainTextTests {
    @Test func summariesLoseTheirHTML() {
        let html = "A keeper tends the light.<br><br>\nStorms &amp; ships <i>come</i>.<br/><br><br>(Source: example)"
        #expect(Presentation.plainText(html) == "A keeper tends the light.\n\nStorms & ships come.\n\n(Source: example)")
        #expect(Presentation.plainText("Plain.") == "Plain.")
        #expect(Presentation.plainText("One.<br><br>\r\n \r\nTwo.") == "One.\n\nTwo.")
    }
}
