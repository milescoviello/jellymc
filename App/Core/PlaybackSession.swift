import Foundation
import Observation

/// What a player engine reports back.
enum PlayerEvent: Sendable, Equatable {
    case position(Double, duration: Double?)
    case paused(Bool)
    case buffering(Bool)
    case ended
    case failed(String)
}

/// A video player on one platform: AVPlayer on iOS, libmpv on Linux. It opens a plan,
/// plays and seeks, and reports what happens; deciding what to play, keeping the server
/// informed, skipping intros and moving on to the next episode is `PlaybackSession`'s.
@MainActor
protocol PlayerEngine: AnyObject {
    var kind: PlayerKind { get }
    var onEvent: (@MainActor (PlayerEvent) -> Void)? { get set }
    func load(_ plan: PlaybackPlan)
    func play()
    func pause()
    func seek(to seconds: Double)
    func setRate(_ rate: Double)
    /// Switches tracks inside the file already playing. False when the engine cannot,
    /// and the session must ask the server for a new stream instead.
    func selectAudio(_ streamIndex: Int, in plan: PlaybackPlan) -> Bool
    func selectSubtitle(_ streamIndex: Int?, in plan: PlaybackPlan) -> Bool
    func stop()
}

/// What to do when playback enters a kind of segment.
enum SegmentAction: String, Codable, Sendable, CaseIterable {
    case ask, skip, ignore

    var title: String {
        switch self {
        case .ask: return "Show Skip Button"
        case .skip: return "Skip Automatically"
        case .ignore: return "Do Nothing"
        }
    }
}

/// One video playing: the server's plan, the engine, and everything between them —
/// progress reports, track switches, skip buttons, the next episode's countdown.
@MainActor
@Observable
final class PlaybackSession {
    let item: BaseItem
    private(set) var plan: PlaybackPlan?
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var error: String?
    private(set) var segments: [MediaSegment] = []
    /// The thumbnails the server made for this source, once known.
    @ObservationIgnored private(set) var trickplay: TrickplayInfo?
    /// The segment under the playhead whose skip button should show.
    private(set) var skippable: MediaSegment?
    /// The episode that follows, once known.
    private(set) var next: BaseItem?
    /// Seconds left before the next episode starts by itself; nil when not counting.
    private(set) var countdown: Int?
    private(set) var hasEnded = false

    /// Set by the screen: open this item as the next playback.
    @ObservationIgnored var onPlayNext: (@MainActor (BaseItem) -> Void)?
    /// Set by the screen: playback is over and the player should close.
    @ObservationIgnored var onFinished: (@MainActor () -> Void)?

    @ObservationIgnored private let client: JellyfinClient
    @ObservationIgnored private let engine: PlayerEngine
    @ObservationIgnored private let preferences: PlaybackPreferences
    @ObservationIgnored private let segmentActions: [MediaSegment.Kind: SegmentAction]
    @ObservationIgnored private let autoplayNext: Bool
    @ObservationIgnored private var reportTimer: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var autoSkipped: Set<Int64> = []
    @ObservationIgnored private var dismissedSkip: Set<Int64> = []
    @ObservationIgnored private var countdownDismissed = false
    @ObservationIgnored private var started = false
    /// Playing a downloaded file: its progress also goes to the outbox, for when the
    /// server could not be told.
    @ObservationIgnored private var isLocal = false

    init(
        item: BaseItem,
        client: JellyfinClient,
        engine: PlayerEngine,
        preferences: PlaybackPreferences,
        segmentActions: [MediaSegment.Kind: SegmentAction] = [:],
        autoplayNext: Bool = true
    ) {
        self.item = item
        self.client = client
        self.engine = engine
        self.preferences = preferences
        self.segmentActions = segmentActions
        self.autoplayNext = autoplayNext
        duration = item.runtime ?? 0
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }

    var title: String { item.type == .episode ? (item.seriesName ?? item.title) : item.title }
    var subtitle: String? { item.type == .episode ? [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ") : item.productionYear.map(String.init) }

    // MARK: - Starting

    /// Asks the server how to play the item, opens it, and starts reporting.
    func start(at start: Double? = nil, audioIndex: Int? = nil, subtitleIndex: Int? = nil, mediaSourceId: String? = nil, local: PlaybackPlan? = nil) async {
        // A position saved offline and not yet sent is newer than the server's.
        let startSeconds = start ?? Outbox.shared.position(for: item.id) ?? item.resumeSeconds
        if var local {
            isLocal = true
            local.startSeconds = startSeconds
            local.audioIndex = audioIndex ?? local.audioIndex
            local.subtitleIndex = subtitleIndex
            open(local)
            await Diagnostics.shared.record("playback", "\(item.title): downloaded file via \(engine.kind.rawValue)")
            Task { await loadSegmentsAndNext() }
            return
        }
        do {
            let plan = try await makePlan(start: startSeconds, audioIndex: audioIndex, subtitleIndex: subtitleIndex, mediaSourceId: mediaSourceId)
            open(plan)
            await Diagnostics.shared.record("playback", "\(item.title): \(plan.method.rawValue) via \(engine.kind.rawValue)\(plan.transcodeReasons.isEmpty ? "" : " (\(plan.reasonSummary))")")
        } catch {
            self.error = error.localizedDescription
            await Diagnostics.shared.record("playback", "\(item.title): \(error.localizedDescription)")
        }
        Task { await loadSegmentsAndNext() }
    }

    private func makePlan(start: Double, audioIndex: Int?, subtitleIndex: Int?, mediaSourceId: String?, forceTranscode: Bool = false) async throws -> PlaybackPlan {
        var preferences = self.preferences
        if forceTranscode { preferences.forceTranscode = true }
        // The server applies the audio and subtitle indexes only to the media source the
        // request names; without one it quietly plays its own defaults.
        let source = mediaSourceId ?? item.mediaSources?.first?.id ?? item.id
        let request = PlaybackInfoRequest(
            userId: client.userId,
            maxStreamingBitrate: preferences.maxBitrate,
            startTimeTicks: Ticks.from(seconds: start),
            audioStreamIndex: audioIndex,
            subtitleStreamIndex: subtitleIndex ?? -1,
            mediaSourceId: source,
            deviceProfile: DeviceProfiles.profile(for: engine.kind, preferences: preferences),
            enableDirectPlay: !forceTranscode
        )
        let response = try await client.playbackInfo(itemId: item.id, request: request)
        return try PlaybackPlan.make(
            itemId: item.id, response: response, mediaSourceId: source,
            startSeconds: start, audioIndex: audioIndex, subtitleIndex: subtitleIndex, client: client
        )
    }

    /// The session playing here now, if any: what another device's remote control acts on.
    private(set) static weak var current: PlaybackSession?

    private func open(_ plan: PlaybackPlan) {
        Self.current = self
        self.plan = plan
        error = nil
        hasEnded = false
        isBuffering = true
        position = plan.startSeconds
        engine.load(plan)
        started = true
        let report = PlaybackReport(plan: plan, position: plan.startSeconds, isPaused: false)
        Task { await client.reportStart(report) }
        startReporting()
    }

    private func loadSegmentsAndNext() async {
        // An item from a list comes without its trickplay; the full one has it.
        var detailed = item
        if detailed.trickplay == nil, let full = try? await client.item(item.id) { detailed = full }
        if let source = plan?.source.id { trickplay = TrickplayFrame.info(for: detailed, mediaSourceId: source) }
        if let segments = try? await client.mediaSegments(itemId: item.id) {
            self.segments = segments.sorted { $0.startTicks < $1.startTicks }
        }
        if item.type == .episode, let seriesId = item.seriesId,
           let episodes = try? await client.episodes(seriesId: seriesId, seasonId: nil),
           let index = episodes.firstIndex(where: { $0.id == item.id }), index + 1 < episodes.count {
            next = episodes[index + 1]
        }
    }

    /// The server's thumbnail for a moment, for a preview over the seek bar: the tile
    /// image to fetch, and where the thumbnail is in it. Nil when the server made none.
    func preview(at seconds: Double) -> TrickplayPreview? {
        guard let info = trickplay, let source = plan?.source.id, let frame = TrickplayFrame(info: info, seconds: seconds),
              let url = client.trickplayTileURL(itemId: item.id, width: info.width, index: frame.tileIndex, mediaSourceId: source)
        else { return nil }
        return TrickplayPreview(tile: url, frame: frame)
    }

    // MARK: - Controls

    func togglePause() {
        isPaused ? engine.play() : engine.pause()
    }

    func setPaused(_ paused: Bool) {
        paused ? engine.pause() : engine.play()
    }

    /// Stops, and has the player closed, as the end of a film does.
    func end() {
        stop()
        onFinished?()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        engine.seek(to: target)
        position = target
        reportNow()
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    func skipSegment() {
        guard let segment = skippable else { return }
        if segment.type == .outro, let next {
            playNext(next)
            return
        }
        seek(to: segment.end)
        skippable = nil
    }

    func dismissSkip() {
        if let segment = skippable { dismissedSkip.insert(segment.startTicks) }
        skippable = nil
    }

    func setRate(_ rate: Double) {
        engine.setRate(rate)
    }

    func selectAudio(_ streamIndex: Int) {
        guard var plan, plan.audioIndex != streamIndex else { return }
        if engine.selectAudio(streamIndex, in: plan) {
            plan.audioIndex = streamIndex
            self.plan = plan
            reportNow()
        } else {
            reload(audioIndex: streamIndex, subtitleIndex: plan.subtitleIndex)
        }
    }

    func selectSubtitle(_ streamIndex: Int?) {
        guard var plan, plan.subtitleIndex != streamIndex else { return }
        if engine.selectSubtitle(streamIndex, in: plan) {
            plan.subtitleIndex = streamIndex
            self.plan = plan
            reportNow()
        } else {
            reload(audioIndex: plan.audioIndex, subtitleIndex: streamIndex)
        }
    }

    /// Asks the server again at the current position, for a change the stream itself
    /// must carry: another audio track in an HLS remux, a subtitle to burn in.
    func reload(audioIndex: Int?, subtitleIndex: Int?, forceTranscode: Bool = false) {
        guard let old = plan else { return }
        let at = position
        let stoppedReport = PlaybackReport(plan: old, position: at, isPaused: isPaused)
        Task {
            await client.reportStopped(stoppedReport)
            do {
                let plan = try await makePlan(start: at, audioIndex: audioIndex, subtitleIndex: subtitleIndex, mediaSourceId: old.source.id, forceTranscode: forceTranscode)
                open(plan)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// After the engine fails: try once more with the server converting the stream.
    func retryWithTranscode() {
        guard let plan else { return }
        reload(audioIndex: plan.audioIndex, subtitleIndex: plan.subtitleIndex, forceTranscode: true)
    }

    func playNext(_ item: BaseItem) {
        countdownTask?.cancel()
        countdown = nil
        stop()
        onPlayNext?(item)
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdown = nil
        countdownDismissed = true
    }

    /// Stops the engine and tells the server where playback ended. Safe to call twice.
    func stop() {
        guard started else { return }
        started = false
        if Self.current === self { Self.current = nil }
        reportTimer?.cancel()
        countdownTask?.cancel()
        engine.stop()
        if let plan {
            let report = PlaybackReport(plan: plan, position: position, isPaused: isPaused)
            let client = client
            Task { await client.reportStopped(report) }
        }
        if isLocal {
            Outbox.shared.add(itemId: item.id, position: position, duration: duration)
            let client = client
            Task { await Outbox.shared.flush(client) }
        }
    }

    // MARK: - Engine events

    private func handle(_ event: PlayerEvent) {
        switch event {
        case let .position(seconds, duration):
            position = seconds
            if let duration, duration > 0 { self.duration = duration }
            isBuffering = false
            updateSegments()
            updateCountdown()
        case let .paused(paused):
            guard paused != isPaused else { return }
            isPaused = paused
            reportNow()
        case let .buffering(buffering):
            isBuffering = buffering
        case .ended:
            hasEnded = true
            if let next, autoplayNext, !countdownDismissed {
                playNext(next)
            } else {
                stop()
                onFinished?()
            }
        case let .failed(message):
            error = message
            Task { await Diagnostics.shared.record("playback", "engine: \(message)") }
        }
    }

    private func updateSegments() {
        let ticks = Ticks.from(seconds: position)
        let current = segments.first { ticks >= $0.startTicks && ticks < $0.endTicks - 5_000_000 }
        guard let current else {
            skippable = nil
            return
        }
        let action = segmentActions[current.type] ?? Self.defaultAction(for: current.type)
        switch action {
        case .skip where !autoSkipped.contains(current.startTicks):
            autoSkipped.insert(current.startTicks)
            if current.type == .outro, let next, autoplayNext {
                playNext(next)
            } else {
                seek(to: current.end)
            }
        case .ask where !dismissedSkip.contains(current.startTicks):
            skippable = current
        default:
            skippable = nil
        }
    }

    nonisolated static func defaultAction(for kind: MediaSegment.Kind) -> SegmentAction {
        switch kind {
        case .commercial: return .skip
        case .unknown: return .ignore
        default: return .ask
        }
    }

    /// When the next episode's card appears: at the credits if the server marked them,
    /// otherwise thirty seconds before the end.
    var countdownStart: Double? {
        guard next != nil, duration > 60 else { return nil }
        if let outro = segments.first(where: { $0.type == .outro }) { return outro.start }
        return duration - 30
    }

    private func updateCountdown() {
        guard autoplayNext, !countdownDismissed, countdownTask == nil, let start = countdownStart, position >= start, let next else { return }
        countdown = 10
        countdownTask = Task { [weak self] in
            for remaining in stride(from: 9, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.isPaused { continue }
                self.countdown = remaining
            }
            guard !Task.isCancelled, let self else { return }
            self.playNext(next)
        }
    }

    // MARK: - Reporting

    private func startReporting() {
        reportTimer?.cancel()
        reportTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.reportNow()
                if self.isPaused, self.plan?.method != .directPlay, let id = self.plan?.playSessionId {
                    let client = self.client
                    Task { await client.ping(playSessionId: id) }
                }
            }
        }
    }

    private func reportNow() {
        guard started, let plan else { return }
        // Kept as it goes, so a crash or a pulled plug still leaves the place.
        if isLocal { Outbox.shared.add(itemId: item.id, position: position, duration: duration) }
        let report = PlaybackReport(plan: plan, position: position, isPaused: isPaused)
        let client = client
        Task { await client.reportProgress(report) }
    }
}

struct TrickplayPreview: Sendable, Equatable {
    var tile: URL
    var frame: TrickplayFrame
}

/// Where a moment's thumbnail is in the server's trickplay tiles.
struct TrickplayFrame: Sendable, Equatable {
    var tileIndex: Int
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    /// The resolution nearest `targetWidth` among those the server made for a source.
    static func info(for item: BaseItem, mediaSourceId: String, targetWidth: Int = 320) -> TrickplayInfo? {
        guard let resolutions = item.trickplay?[mediaSourceId] ?? item.trickplay?.values.first else { return nil }
        return resolutions.values.min { abs($0.width - targetWidth) < abs($1.width - targetWidth) }
    }

    init(tileIndex: Int, x: Int, y: Int, width: Int, height: Int) {
        self.tileIndex = tileIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init?(info: TrickplayInfo, seconds: Double) {
        guard info.interval > 0, info.tileWidth > 0, info.tileHeight > 0, info.thumbnailCount > 0 else { return nil }
        let thumbnail = min(info.thumbnailCount - 1, max(0, Int(seconds * 1000) / info.interval))
        let perTile = info.tileWidth * info.tileHeight
        let inTile = thumbnail % perTile
        self.init(
            tileIndex: thumbnail / perTile,
            x: (inTile % info.tileWidth) * info.width,
            y: (inTile / info.tileWidth) * info.height,
            width: info.width,
            height: info.height
        )
    }
}
