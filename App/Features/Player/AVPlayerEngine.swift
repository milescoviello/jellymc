import AVFoundation
import Observation

/// AVPlayer as a `PlayerEngine`: the iPhone's player.
///
/// It plays what the device profile let the server send — MP4 as it is, everything else
/// as HLS — so Picture in Picture, AirPlay, Dolby Vision and the lock screen are the
/// system's own. Subtitles sent beside the file (a direct-played film's SRT) are drawn by
/// the app, since AVPlayer cannot load a sidecar; subtitles inside an HLS stream are
/// AVPlayer's.
///
/// Status is polled on the main actor rather than observed with KVO, which would arrive
/// on AVFoundation's queues and need an unsafe hop under strict concurrency — the Music
/// app's reasoning, kept.
@MainActor
@Observable
final class AVPlayerEngine: PlayerEngine {
    let kind: PlayerKind = .avPlayer
    @ObservationIgnored var onEvent: (@MainActor (PlayerEvent) -> Void)?
    @ObservationIgnored let player = AVPlayer()

    /// The sidecar subtitle on screen now, drawn over the video by the player view.
    private(set) var caption: String?

    @ObservationIgnored private var plan: PlaybackPlan?
    @ObservationIgnored private var captions: Captions?
    @ObservationIgnored private var captionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStart: Double?
    @ObservationIgnored private var pendingLegible: MediaStream?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastStatus: AVPlayer.TimeControlStatus?
    @ObservationIgnored private var reportedFailure = false

    init() {
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.poll()
            }
        }
    }

    // MARK: - PlayerEngine

    func load(_ plan: PlaybackPlan) {
        self.plan = plan
        captions = nil
        caption = nil
        captionTask?.cancel()
        reportedFailure = false
        lastStatus = nil

        var options: [String: Any] = [:]
        if !plan.httpHeaders.isEmpty {
            // Not public API, but the only way to give AVURLAsset headers; the app is
            // sideloaded, and the ApiKey in the URL covers authorization anyway.
            options["AVURLAssetHTTPHeaderFieldsKey"] = plan.httpHeaders
        }
        let asset = AVURLAsset(url: plan.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        pendingStart = plan.startSeconds > 1 ? plan.startSeconds : nil
        pendingLegible = nil

        if let index = plan.subtitleIndex {
            if let sidecar = plan.externalSubtitles.first(where: { $0.streamIndex == index }) {
                loadCaptions(sidecar)
            } else {
                pendingLegible = plan.subtitleStreams.first { $0.index == index }
            }
        }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.ended) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(value: 1, timescale: 2))
        updateCaption(seconds)
    }

    func setRate(_ rate: Double) {
        player.defaultRate = Float(rate)
        if player.timeControlStatus != .paused { player.rate = Float(rate) }
    }

    /// AVPlayer gets one audio track from the server's stream; another means a new one.
    func selectAudio(_ streamIndex: Int, in plan: PlaybackPlan) -> Bool { false }

    func selectSubtitle(_ streamIndex: Int?, in plan: PlaybackPlan) -> Bool {
        guard let streamIndex else {
            captions = nil
            caption = nil
            selectLegible(nil)
            return true
        }
        if let sidecar = plan.externalSubtitles.first(where: { $0.streamIndex == streamIndex }) {
            selectLegible(nil)
            loadCaptions(sidecar)
            return true
        }
        // Burnt in, or not in this stream's manifest: the server makes a new stream.
        return false
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        plan = nil
        captions = nil
        caption = nil
        captionTask?.cancel()
    }

    /// The page calls this when it closes; the engine is unusable after it.
    func shutdown() {
        stop()
        pollTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    // MARK: - Ticking

    private func tick(_ time: CMTime) {
        guard plan != nil, pendingStart == nil else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        let duration = player.currentItem?.duration.seconds
        onEvent?(.position(seconds, duration: duration.flatMap { $0.isFinite ? $0 : nil }))
        updateCaption(seconds)
    }

    private func poll() {
        guard plan != nil, let item = player.currentItem else { return }
        switch item.status {
        case .failed:
            if !reportedFailure {
                reportedFailure = true
                onEvent?(.failed(item.error?.localizedDescription ?? "AVPlayer could not play this"))
            }
            return
        case .readyToPlay:
            if let start = pendingStart {
                pendingStart = nil
                seek(to: start)
            }
            if let stream = pendingLegible {
                pendingLegible = nil
                selectLegible(matching: stream, in: item)
            }
        default:
            break
        }
        let status = player.timeControlStatus
        guard status != lastStatus else { return }
        lastStatus = status
        switch status {
        case .paused:
            onEvent?(.paused(true))
        case .playing:
            onEvent?(.buffering(false))
            onEvent?(.paused(false))
        case .waitingToPlayAtSpecifiedRate:
            onEvent?(.buffering(true))
        @unknown default:
            break
        }
    }

    // MARK: - Subtitles

    private func loadCaptions(_ sidecar: ExternalSubtitle) {
        captionTask?.cancel()
        let url = sidecar.webVTTURL
        captionTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
            let parsed = Captions(parsing: String(decoding: data, as: UTF8.self))
            self.captions = parsed
            self.updateCaption(self.player.currentTime().seconds)
        }
    }

    private func updateCaption(_ seconds: Double) {
        let text = captions?.text(at: seconds)
        if text != caption { caption = text }
    }

    /// The HLS stream's own subtitle rendition for `stream`: the server names each after
    /// its language, so the language is what is matched.
    ///
    /// The synchronous, deprecated lookup on purpose: by `readyToPlay` the stream's
    /// selection groups are loaded, and the async form would send a non-Sendable item
    /// across an await.
    private func selectLegible(matching stream: MediaStream, in item: AVPlayerItem) {
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        let options = group.options
        let wanted = stream.language.map { Locale.LanguageCode($0) }
        let option = options.first { option in
            guard let wanted, let code = option.locale?.language.languageCode else { return false }
            return code == wanted || code.identifier(.alpha3) == wanted.identifier
        } ?? options.first
        item.select(option, in: group)
    }

    private func selectLegible(_ option: AVMediaSelectionOption?) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
        else { return }
        item.select(option, in: group)
    }
}
