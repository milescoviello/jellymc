import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A film or episode kept on the device, with what playing it offline needs: the file,
/// its text subtitles as WebVTT, and the item as it was when it was saved.
struct DownloadRecord: Codable, Sendable, Identifiable, Equatable {
    enum State: Codable, Sendable, Equatable {
        case queued
        case downloading
        case done
        case failed(String)
    }

    enum Quality: Codable, Sendable, Equatable {
        /// The file as it is on the server.
        case original
        /// Converted by the server to HEVC and AAC in MP4, at most this many bits a second.
        case converted(bitrate: Int)

        var title: String {
            switch self {
            case .original: return "Original"
            case let .converted(bitrate): return "Converted, \(bitrate / 1_000_000) Mbps"
            }
        }
    }

    struct Subtitle: Codable, Sendable, Equatable {
        var streamIndex: Int
        var file: String
        var language: String?
        var title: String
    }

    var item: BaseItem
    var mediaSourceId: String
    var quality: Quality
    var state: State
    var progress: Double = 0
    var bytes: Int64?
    /// Relative to `DownloadStore.root`.
    var file: String?
    var subtitles: [Subtitle] = []
    /// A landscape picture, relative to `DownloadStore.root`, for the list with no server.
    var art: String?
    var addedAt: Date

    var id: String { item.id }
    var isDone: Bool { state == .done }

    /// An episode with its series, for a list of everything saved.
    var title: String {
        guard item.type == .episode else { return item.title }
        return [item.seriesName, [item.episodeLabel, item.title].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var status: String {
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        switch state {
        case .queued: return "Waiting"
        case .downloading: return ["Downloading", "\(Int(progress * 100))%", size].compactMap { $0 }.joined(separator: " · ")
        case .done: return [quality.title, size].compactMap { $0 }.joined(separator: " · ")
        case let .failed(message): return "Failed: \(message)"
        }
    }
}

/// Which file to keep for a player, and where to fetch it.
enum DownloadPlanner {
    /// The file as it is when the player can open it; otherwise a conversion it can.
    static func quality(for item: BaseItem, player: PlayerKind, maxBitrate: Int = 20_000_000) -> DownloadRecord.Quality {
        guard player == .avPlayer, let source = item.mediaSources?.first else { return .original }
        let container = Set((source.container ?? "").split(separator: ",").map { String($0).lowercased() })
        let videoOK = ["h264", "hevc"].contains(source.videoStream?.codec ?? "")
        let audioOK = source.audioStreams.allSatisfy { ["aac", "ac3", "eac3", "alac", "flac", "mp3"].contains($0.codec ?? "") }
        if !container.isDisjoint(with: ["mp4", "m4v", "mov"]), videoOK, audioOK {
            return .original
        }
        let bitrate = min(maxBitrate, source.bitrate ?? maxBitrate)
        return .converted(bitrate: max(2_000_000, bitrate))
    }

    static func url(for record: DownloadRecord, client: JellyfinClient) -> URL? {
        switch record.quality {
        case .original:
            return client.authorizedURL("Items/\(record.item.id)/Download")
        case let .converted(bitrate):
            let query = [
                "static=false",
                "mediaSourceId=\(record.mediaSourceId)",
                "deviceId=\(client.device.deviceId)",
                "videoCodec=hevc",
                "audioCodec=aac",
                "maxAudioChannels=6",
                "videoBitRate=\(bitrate)",
                "maxWidth=3840",
                "requireAvc=false",
                "allowVideoStreamCopy=true",
                "allowAudioStreamCopy=true",
            ].joined(separator: "&")
            return client.authorizedURL("Videos/\(record.item.id)/stream.mp4?\(query)")
        }
    }

    /// About how big a conversion will be. The server streams one as it encodes, with no
    /// length, so progress is the bytes so far against its bitrate times its runtime.
    static func expectedBytes(for record: DownloadRecord) -> Int64? {
        guard case let .converted(bitrate) = record.quality, let runtime = record.item.runtime, runtime > 0 else { return nil }
        return Int64(Double(bitrate) / 8 * runtime)
    }

    /// Every text subtitle in the source, which the server extracts as WebVTT whether it
    /// is embedded or beside the file. Image subtitles cannot be kept this way.
    static func subtitleURLs(for record: DownloadRecord, client: JellyfinClient) -> [(MediaStream, URL)] {
        let source = record.item.mediaSources?.first { $0.id == record.mediaSourceId } ?? record.item.mediaSources?.first
        return (source?.subtitleStreams ?? []).compactMap { stream in
            guard stream.isTextSubtitleStream == true,
                  let url = client.authorizedURL("Videos/\(record.item.id)/\(record.mediaSourceId)/Subtitles/\(stream.index)/0/Stream.vtt")
            else { return nil }
            return (stream, url)
        }
    }
}

/// Everything downloaded, and what is on its way.
@MainActor
@Observable
final class DownloadStore {
    private(set) var records: [String: DownloadRecord] = [:]
    @ObservationIgnored private let downloader: Downloader
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var active: String?

    static let root: URL = {
        let url = Paths.root.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var index: URL { root.appendingPathComponent("index.json") }

    init(downloader: Downloader = URLSessionDownloader()) {
        self.downloader = downloader
        if let data = try? Data(contentsOf: Self.index),
           let saved = try? JSONCoding.decoder().decode([DownloadRecord].self, from: data) {
            records = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        }
        downloader.onProgress = { [weak self] id, progress, bytes in self?.progressed(id, progress, bytes) }
        downloader.onFinished = { [weak self] id, result in self?.finished(id, result) }
        Task { await reconcile() }
    }

    /// A download the session still has keeps going; one it has lost starts again.
    private func reconcile() async {
        let running = Set(await downloader.runningIds())
        for (id, record) in records where record.state == .downloading && !running.contains(id) {
            records[id]?.state = .queued
        }
        active = running.first { records[$0] != nil }
        save()
        startNext()
    }

    /// The newest first, for the Downloads screen.
    var all: [DownloadRecord] { records.values.sorted { $0.addedAt > $1.addedAt } }

    func record(for itemId: String) -> DownloadRecord? { records[itemId] }

    func connect(_ client: JellyfinClient?) {
        self.client = client
        startNext()
    }

    /// Saves a film or episode. `item` should be the full item, with its media sources.
    func download(_ item: BaseItem, quality: DownloadRecord.Quality) {
        guard records[item.id]?.state != .done, let source = item.mediaSources?.first else { return }
        records[item.id] = DownloadRecord(item: item, mediaSourceId: source.id, quality: quality, state: .queued, addedAt: Date())
        save()
        startNext()
    }

    /// Saves a film or episode as a file `player` opens. An item from a list comes without
    /// its media sources, so it is fetched in full first.
    func download(_ item: BaseItem, for player: PlayerKind) async {
        var item = item
        if item.mediaSources == nil {
            guard let client, let full = try? await client.item(item.id) else { return }
            item = full
        }
        download(item, quality: DownloadPlanner.quality(for: item, player: player))
    }

    /// Every episode not yet saved, in order.
    func download(_ episodes: [BaseItem], for player: PlayerKind) async {
        for episode in episodes where records[episode.id] == nil {
            await download(episode, for: player)
        }
    }

    func remove(_ itemId: String) {
        if active == itemId {
            downloader.cancel(id: itemId)
            active = nil
        }
        records[itemId] = nil
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(itemId, isDirectory: true))
        save()
        startNext()
    }

    func retry(_ itemId: String) {
        guard case .failed = records[itemId]?.state else { return }
        records[itemId]?.state = .queued
        records[itemId]?.progress = 0
        save()
        startNext()
    }

    /// The saved picture, to show in place of the server's.
    func artURL(for record: DownloadRecord) -> URL? {
        record.art.map { Self.root.appendingPathComponent($0) }
    }

    /// The bytes all downloads take.
    var totalBytes: Int64 { records.values.compactMap(\.bytes).reduce(0, +) }

    // MARK: - Playing offline

    /// A plan for the saved file, shaped like the server's so the player cannot tell —
    /// except that it reports nothing until it is back online.
    func localPlan(for itemId: String, start: Double) -> PlaybackPlan? {
        guard let record = records[itemId], record.isDone, let file = record.file else { return nil }
        let url = Self.root.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var source = record.item.mediaSources?.first { $0.id == record.mediaSourceId } ?? MediaSource(id: record.mediaSourceId)
        // A converted file has one audio track and no embedded subtitles.
        if case .converted = record.quality {
            let audio = source.audioStreams.first { $0.index == source.defaultAudioStreamIndex } ?? source.audioStreams.first
            source.mediaStreams = source.streams.filter { $0.type == .video } + [audio].compactMap { $0 }
                + source.subtitleStreams.filter { stream in record.subtitles.contains { $0.streamIndex == stream.index } }
        }
        let subtitles = record.subtitles.map { subtitle in
            ExternalSubtitle(
                streamIndex: subtitle.streamIndex,
                url: Self.root.appendingPathComponent(subtitle.file),
                title: subtitle.title, language: subtitle.language, codec: "webvtt"
            )
        }
        for index in (source.mediaStreams ?? []).indices where source.mediaStreams?[index].type == .subtitle {
            if record.subtitles.contains(where: { $0.streamIndex == source.mediaStreams?[index].index }) {
                source.mediaStreams?[index].deliveryMethod = "External"
            }
        }
        return PlaybackPlan(
            itemId: itemId, source: source, playSessionId: nil, method: .directPlay, url: url,
            startSeconds: start, audioIndex: source.audioStreams.first?.index, subtitleIndex: nil,
            externalSubtitles: subtitles, transcodeReasons: [], httpHeaders: [:]
        )
    }

    // MARK: - The queue

    private func startNext() {
        guard active == nil, let client else { return }
        guard let next = records.values.filter({ $0.state == .queued }).min(by: { $0.addedAt < $1.addedAt }),
              let url = DownloadPlanner.url(for: next, client: client)
        else { return }
        active = next.id
        records[next.id]?.state = .downloading
        save()
        downloader.start(id: next.id, url: url)
        Task { await Diagnostics.shared.record("downloads", "\(next.item.title): \(next.quality.title)") }
    }

    private func progressed(_ id: String, _ progress: Double, _ bytes: Int64?) {
        guard let record = records[id] else { return }
        var progress = progress
        if progress <= 0, let bytes, let expected = DownloadPlanner.expectedBytes(for: record) {
            progress = min(0.99, Double(bytes) / Double(expected))
        }
        // A percent at a time: every screen showing the download redraws on a change.
        // With no length and no estimate, the bytes are all there is to show.
        let old = record.progress
        let grown = (bytes ?? 0) - (record.bytes ?? 0) >= 5_000_000
        guard progress - old >= 0.01 || progress >= 1 || (progress <= 0 && grown) else { return }
        records[id]?.progress = progress
        if let bytes { records[id]?.bytes = bytes }
    }

    private func finished(_ id: String, _ result: Result<URL, Error>) {
        if active == id { active = nil }
        guard var record = records[id] else { return }
        switch result {
        case let .failure(error):
            record.state = .failed(error.localizedDescription)
            records[id] = record
            save()
            startNext()
        case let .success(staged):
            let folder = Self.root.appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = record.quality == .original ? "media.\(Self.fileExtension(record))" : "media.mp4"
            let destination = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: staged, to: destination)
            } catch {
                record.state = .failed(error.localizedDescription)
                records[id] = record
                save()
                startNext()
                return
            }
            record.file = "\(id)/\(name)"
            record.bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            record.progress = 1
            records[id] = record
            Task { await self.fetchExtras(id) }
        }
    }

    /// Subtitles and a picture are small; they come after the film, in one go, and the
    /// download is done when they are.
    private func fetchExtras(_ id: String) async {
        guard var record = records[id] else { return }
        if let client {
            for (stream, url) in DownloadPlanner.subtitleURLs(for: record, client: client) {
                guard let data = await Self.fetch(url) else { continue }
                let file = "\(id)/subtitle-\(stream.index).vtt"
                try? data.write(to: Self.root.appendingPathComponent(file))
                record.subtitles.append(.init(streamIndex: stream.index, file: file, language: stream.language, title: stream.label))
            }
            if let url = Artwork.landscape(record.item, client, width: 480), let data = await Self.fetch(url) {
                let file = "\(id)/art.jpg"
                if (try? data.write(to: Self.root.appendingPathComponent(file))) != nil { record.art = file }
            }
        }
        record.state = .done
        records[id] = record
        save()
        await Diagnostics.shared.record("downloads", "\(record.item.title): done, \(record.subtitles.count) subtitles")
        startNext()
    }

    private static func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    private static func fileExtension(_ record: DownloadRecord) -> String {
        let source = record.item.mediaSources?.first { $0.id == record.mediaSourceId }
        if let path = source?.path, let ext = path.split(separator: ".").last, ext.count <= 5 { return String(ext) }
        return source?.container?.split(separator: ",").first.map(String.init) ?? "mkv"
    }

    private func save() {
        guard let data = try? JSONCoding.encoder().encode(Array(records.values)) else { return }
        try? data.write(to: Self.index, options: .atomic)
    }
}

/// What was watched while offline, kept until the server can be told.
@MainActor
final class Outbox {
    struct Entry: Codable, Sendable {
        var itemId: String
        var position: Double
        var played: Bool
        var date: Date
    }

    static let shared = Outbox(file: Paths.root.appendingPathComponent("outbox.json"))

    private(set) var entries: [Entry] = []
    private let file: URL

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONCoding.decoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// The latest position per item wins; an older one for the same item is dropped.
    func add(itemId: String, position: Double, duration: Double) {
        let played = duration > 0 && position / duration > 0.9
        entries.removeAll { $0.itemId == itemId }
        entries.append(Entry(itemId: itemId, position: played ? 0 : position, played: played, date: Date()))
        save()
    }

    /// The item with what was watched offline and not yet sent, which is newer than
    /// anything the server or the cache says.
    func applying(to item: BaseItem) -> BaseItem {
        guard let entry = entries.first(where: { $0.itemId == item.id }) else { return item }
        var item = item
        var data = item.userData ?? UserItemData()
        data.playbackPositionTicks = Ticks.from(seconds: entry.position)
        if entry.played { data.played = true }
        item.userData = data
        return item
    }

    /// Where the item was left, if that has not reached the server yet.
    func position(for itemId: String) -> Double? {
        entries.first { $0.itemId == itemId }?.position
    }

    private var isFlushing = false

    /// Sends what it can; whatever fails stays for next time, and so does anything added
    /// while it was sending.
    func flush(_ client: JellyfinClient) async {
        guard !isFlushing, !entries.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        var sent = 0
        for entry in entries {
            do {
                try await client.setPosition(entry.position, played: entry.played, lastPlayed: entry.date, itemId: entry.itemId)
                if entry.played { _ = try? await client.setPlayed(true, itemId: entry.itemId) }
                entries.removeAll { $0.itemId == entry.itemId && $0.date == entry.date }
                sent += 1
            } catch {
                continue
            }
        }
        if sent > 0 {
            save()
            await Diagnostics.shared.record("outbox", "sent \(sent) saved position\(sent == 1 ? "" : "s")")
        }
    }

    private func save() {
        if let data = try? JSONCoding.encoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}
