import CGtk
import Foundation

/// Full-window video: mpv underneath, bars that appear on movement, the skip button and
/// the next episode's countdown, and mpv's keyboard.
///
/// One page and one engine for a whole sitting: going on to the next episode starts a new
/// `PlaybackSession` on the same engine.
@MainActor
final class PlayerPage {
    private(set) var root: Widget = Bin()
    private unowned let window: MainWindow
    private let client: JellyfinClient
    private let engine = MpvEngine()
    private var session: PlaybackSession?

    private var top: Revealer!
    private var bottom: Revealer!
    private let titleLabel = Label("", "title-4")
    private let subtitleLabel = Label("", "dim-label")
    private let seek = Scale(min: 0, max: 1, step: 1, value: 0)
    private let elapsed = Label("0:00", "player-time", "numeric")
    private let remaining = Label("0:00", "player-time", "numeric")
    private let playButton = Button(icon: "media-playback-pause-symbolic", "flat", "circular")
    private let skipButton = Button("Skip", "osd-pill")
    private let upNext = Box.vertical(spacing: 10).css("up-next")
    private let upNextTitle = Label("", "heading").wrap()
    private let upNextCount = Label("", "dim-label")
    private let spinner = Spinner().size(56)
    private let stats = Label("", "stats").selectable()
    private let errorBox = Box.vertical(spacing: 12).css("error-box")
    private let errorLabel = Label("").wrap().maxWidthChars(60)
    private var keyController: OpaquePointer?
    private var hideTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private let seekPreview = SeekPreview()
    private var scrubbing = false
    /// The bars stay while the pointer is on them: reading the seek preview, aiming at a
    /// button.
    private var pointerOnBars = false
    private var showsStats = false
    private var lastPointer: (Double, Double) = (0, 0)
    /// The session's idle inhibitor: no screen saver while a video is open.
    private var inhibitor: guint = 0

    init(window: MainWindow, client: JellyfinClient) {
        self.window = window
        self.client = client

        // Top: back, title.
        let back = Button(icon: "go-previous-symbolic", "flat", "circular")
        let topBar = Box.horizontal(spacing: 12) {
            back
            Box.vertical(spacing: 2) {
                titleLabel
                subtitleLabel
            }.valign(GTK_ALIGN_CENTER)
            Spacer()
        }.css("player-top")
        top = Revealer(topBar, transition: GTK_REVEALER_TRANSITION_TYPE_CROSSFADE)
        top.valign(GTK_ALIGN_START)

        // Bottom: seek bar, transport, tracks.
        let audio = MenuButton(icon: "audio-volume-high-symbolic", "flat", "circular") { [weak self] in self?.audioMenu() ?? Menu([]) }
        audio.tooltip("Audio")
        let subtitles = MenuButton(icon: "media-view-subtitles-symbolic", "flat", "circular") { [weak self] in self?.subtitleMenu() ?? Menu([]) }
        subtitles.tooltip("Subtitles")
        let speed = MenuButton(icon: "speedometer-symbolic", "flat", "circular") { [weak self] in self?.speedMenu() ?? Menu([]) }
        speed.tooltip("Speed")
        let info = Button(icon: "dialog-information-symbolic", "flat", "circular")
        info.tooltip("Playback Info (i)")
        let fullscreen = Button(icon: "view-fullscreen-symbolic", "flat", "circular")
        fullscreen.tooltip("Fullscreen (f)")
        let back10 = Button(icon: "media-seek-backward-symbolic", "flat", "circular")
        back10.tooltip("Back 10 s (←)")
        let forward30 = Button(icon: "media-seek-forward-symbolic", "flat", "circular")
        forward30.tooltip("Forward 30 s (→)")
        seek.hexpand()
        let bottomBar = Box.vertical(spacing: 6) {
            Box.horizontal(spacing: 12) {
                elapsed
                seek
                remaining
            }
            Box.horizontal(spacing: 6) {
                back10
                playButton
                forward30
                Spacer()
                audio
                subtitles
                speed
                info
                fullscreen
            }
        }.css("player-bottom")
        bottom = Revealer(bottomBar, transition: GTK_REVEALER_TRANSITION_TYPE_CROSSFADE)
        bottom.valign(GTK_ALIGN_END)
        for bar in [topBar, bottomBar] {
            let hover = gtk_event_controller_motion_new()!
            Signal.connect(hover, "enter", point: { [weak self] _, _ in self?.pointerOnBars = true })
            Signal.connect(hover, "leave") { [weak self] in
                self?.pointerOnBars = false
                self?.reveal()
            }
            gtk_widget_add_controller(bar.widget, hover)
        }

        // Up next.
        let playNow = Button("Play Now", "suggested-action", "pill")
        let cancel = Button("Cancel", "pill")
        upNext.append(Label("Up Next", "caption-heading", "dim-label"))
        upNext.append(upNextTitle)
        upNext.append(upNextCount)
        upNext.append(Box.horizontal(spacing: 8) {
            playNow
            cancel
        })
        upNext.size(width: 320).halign(GTK_ALIGN_END).valign(GTK_ALIGN_END).margins(bottom: 120, end: 32).visible(false)

        skipButton.halign(GTK_ALIGN_END).valign(GTK_ALIGN_END).margins(bottom: 120, end: 32).visible(false)
        spinner.halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER).canTarget(false)
        stats.halign(GTK_ALIGN_START).valign(GTK_ALIGN_START).margins(top: 90, start: 24).visible(false)

        let retry = Button("Try Transcoding", "suggested-action", "pill")
        let close = Button("Close", "pill")
        errorBox.append(Label("Playback failed", "title-3"))
        errorBox.append(errorLabel)
        errorBox.append(Box.horizontal(spacing: 8) {
            retry
            close
        }.halign(GTK_ALIGN_CENTER))
        errorBox.halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER).visible(false)

        let overlay = Overlay(engine.view)
            .add(spinner)
            .add(top)
            .add(bottom)
            .add(seekPreview.root)
            .add(stats)
            .add(skipButton)
            .add(upNext)
            .add(errorBox)
        overlay.css("player").focusable(true)
        root = overlay
        root.keep(self)

        back.onClicked { [weak self] in self?.window.closePlayer() }
        close.onClicked { [weak self] in self?.window.closePlayer() }
        retry.onClicked { [weak self] in self?.session?.retryWithTranscode() }
        playButton.onClicked { [weak self] in self?.session?.togglePause() }
        back10.onClicked { [weak self] in self?.session?.skip(by: -10) }
        forward30.onClicked { [weak self] in self?.session?.skip(by: 30) }
        fullscreen.onClicked { [weak self] in self?.window.toggleFullscreen() }
        info.onClicked { [weak self] in self?.toggleStats() }
        skipButton.onClicked { [weak self] in self?.session?.skipSegment() }
        playNow.onClicked { [weak self] in
            guard let session = self?.session, let next = session.next else { return }
            session.playNext(next)
        }
        cancel.onClicked { [weak self] in self?.session?.cancelCountdown() }
        seek.onUserChange { [weak self] value in self?.scrub(to: value) }

        installPointer(overlay)
        installSeekPreview()
        installKeys()
        if let application = Desktop.application {
            inhibitor = gtk_application_inhibit(application.cast(), window.window.cast(), GTK_APPLICATION_INHIBIT_IDLE, "Playing video")
        }
        engine.onLog = { line in Task { await Diagnostics.shared.record("mpv", line) } }
        reveal()
    }

    // MARK: - Sessions

    func start(_ item: BaseItem, from start: Double? = nil, audioIndex: Int? = nil, subtitleIndex: Int? = nil, mediaSourceId: String? = nil) {
        session?.stop()
        let state = window.state
        let session = PlaybackSession(
            item: item, client: client, engine: engine,
            preferences: window.playbackPreferences,
            segmentActions: state.preferences.segmentActions,
            autoplayNext: state.preferences.autoplayNext
        )
        self.session = session
        session.onPlayNext = { [weak self] next in self?.start(next, from: 0) }
        session.onFinished = { [weak self] in self?.window.closePlayer() }
        connectMediaControls(session)
        root.observe { [weak self, weak session] in
            guard let self, let session, session === self.session else { return }
            self.update(from: session)
        }
        let tracks: (audio: Int?, subtitle: Int?)
        if audioIndex == nil, subtitleIndex == nil, let source = item.mediaSources?.first(where: { $0.id == mediaSourceId }) ?? item.mediaSources?.first {
            tracks = state.preferences.initialTracks(for: source)
        } else {
            tracks = (audioIndex, subtitleIndex)
        }
        // A downloaded copy plays from disk, online or not.
        let local = state.downloads.localPlan(for: item.id, start: start ?? item.resumeSeconds)
        Task {
            await session.start(at: start, audioIndex: tracks.audio, subtitleIndex: tracks.subtitle, mediaSourceId: mediaSourceId, local: local)
        }
        root.grabFocus()
        reveal()
    }

    func close() {
        session?.stop()
        session = nil
        hideTask?.cancel()
        seekTask?.cancel()
        if let keyController, let window = Desktop.window {
            gtk_widget_remove_controller(window, keyController.cast())
            self.keyController = nil
        }
        setCursor(visible: true)
        MediaControls.shared.clear()
        if inhibitor != 0, let application = Desktop.application {
            gtk_application_uninhibit(application.cast(), inhibitor)
            inhibitor = 0
        }
        engine.shutdown()
    }

    // MARK: - State to widgets

    private func update(from session: PlaybackSession) {
        titleLabel.text = session.title
        subtitleLabel.text = session.subtitle ?? ""
        gtk_window_set_title(window.window.cast(), session.title)

        let duration = max(session.duration, 1)
        gtk_range_set_range(seek.widget.cast(), 0, duration)
        if !scrubbing { seek.value = session.position }
        elapsed.text = Ticks.clock(session.position)
        remaining.text = "-" + Ticks.clock(max(0, session.duration - session.position))
        playButton.icon = session.isPaused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic"
        spinner.visible(session.isBuffering && session.error == nil)

        if let segment = session.skippable {
            skipButton.label = segment.type == .outro && session.next != nil ? "Next Episode" : segment.type.skipLabel
            skipButton.visible(true)
        } else {
            skipButton.visible(false)
        }

        if let countdown = session.countdown, let next = session.next {
            upNextTitle.text = [next.episodeLabel, next.name].compactMap { $0 }.joined(separator: " · ")
            upNextCount.text = "Starting in \(countdown) s"
            upNext.visible(true)
        } else {
            upNext.visible(false)
        }

        if let error = session.error {
            errorLabel.text = error
            errorBox.visible(true)
            reveal(autohide: false)
        } else {
            errorBox.visible(false)
        }

        if showsStats { stats.text = statsText(session) }
        if session.isPaused { reveal(autohide: false) }

        MediaControls.shared.update(
            track: MediaControls.Track(
                id: session.item.id,
                title: session.item.title,
                artist: session.item.type == .episode ? session.item.seriesName : session.item.productionYear.map(String.init),
                album: session.item.type == .episode ? session.item.seasonName : nil,
                duration: session.duration
            ),
            elapsed: session.position,
            isPlaying: !session.isPaused,
            canGoNext: session.next != nil
        )
    }

    /// The desktop's media keys, Plasma's applet and KDE Connect drive this session.
    private func connectMediaControls(_ session: PlaybackSession) {
        let controls = MediaControls.shared
        controls.onToggle = { [weak session] in session?.togglePause() }
        controls.onPlay = { [weak session] in if session?.isPaused == true { session?.togglePause() } }
        controls.onPause = { [weak session] in if session?.isPaused == false { session?.togglePause() } }
        controls.onNext = { [weak session] in
            guard let session, let next = session.next else { return }
            session.playNext(next)
        }
        controls.onPrevious = { [weak session] in session?.seek(to: 0) }
        controls.onSeek = { [weak session] seconds in session?.seek(to: seconds) }
        if let url = Artwork.primary(session.item, client, width: 600) {
            let id = session.item.id
            Images.shared.load(url) { texture in
                guard let texture else { return }
                MediaControls.shared.setArtwork(texture, for: id)
            }
        }
    }

    private func statsText(_ session: PlaybackSession) -> String {
        guard let plan = session.plan else { return "Starting…" }
        var lines = [
            "Method     \(plan.methodTitle)",
            "Container  \(plan.source.container ?? "?")",
        ]
        if let video = plan.source.videoStream {
            let size = video.width.flatMap { width in video.height.map { "\(width)×\($0)" } } ?? ""
            lines.append("Video      \(video.codec ?? "?") \(size) \(video.videoRangeType ?? "") \(video.bitDepth.map { "\($0)-bit" } ?? "")")
        }
        if let audio = plan.audioStreams.first(where: { $0.index == plan.audioIndex }) {
            lines.append("Audio      \(audio.label)")
        }
        if let index = plan.subtitleIndex, let subtitle = plan.subtitleStreams.first(where: { $0.index == index }) {
            lines.append("Subtitles  \(subtitle.label)")
        }
        if let bitrate = plan.source.bitrate {
            lines.append(String(format: "Bitrate    %.1f Mbps", Double(bitrate) / 1_000_000))
        }
        if !plan.transcodeReasons.isEmpty {
            lines.append("Because    \(plan.reasonSummary)")
        }
        lines.append("Position   \(Ticks.clock(session.position)) / \(Ticks.clock(session.duration))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Menus

    private func audioMenu() -> Menu {
        guard let session, let plan = session.plan, !plan.audioStreams.isEmpty else { return Menu([[.action("No audio tracks", enabled: false) {}]]) }
        return Menu([plan.audioStreams.map { stream in
            .toggle(stream.label, isOn: stream.index == plan.audioIndex) { _ in session.selectAudio(stream.index) }
        }])
    }

    private func subtitleMenu() -> Menu {
        guard let session, let plan = session.plan else { return Menu([]) }
        var items: [Menu.Item] = [.toggle("Off", isOn: plan.subtitleIndex == nil) { _ in session.selectSubtitle(nil) }]
        for stream in plan.subtitleStreams {
            items.append(.toggle(stream.label, isOn: stream.index == plan.subtitleIndex) { _ in session.selectSubtitle(stream.index) })
        }
        return Menu([items])
    }

    private func speedMenu() -> Menu {
        Menu([[0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map { rate in
            .action(rate == 1 ? "Normal" : String(format: "%.2g×", rate)) { [weak self] in self?.session?.setRate(rate) }
        }])
    }

    // MARK: - Pointer and keys

    private func installPointer(_ overlay: Widget) {
        let motion = gtk_event_controller_motion_new()!
        Signal.connect(motion, "motion", point: { [weak self] x, y in
            guard let self else { return }
            // Wayland sends motion for a still pointer when the surface changes under it.
            if abs(x - self.lastPointer.0) < 1, abs(y - self.lastPointer.1) < 1 { return }
            self.lastPointer = (x, y)
            self.reveal()
        })
        gtk_widget_add_controller(overlay.widget, motion)

        let click = gtk_gesture_click_new()!
        Signal.connect(click, "pressed", press: { [weak self] count, _, _ in
            guard let self else { return }
            if count == 2 { self.window.toggleFullscreen() }
        })
        gtk_widget_add_controller(engine.view.widget, click.cast())

        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        Signal.connect(scroll, "scroll", scroll: { [weak self] _, dy in
            guard let self else { return false }
            self.engine.setVolume(self.engine.volume - dy * 5)
            return true
        })
        gtk_widget_add_controller(engine.view.widget, scroll)
    }

    /// The thumbnail and time over the seek bar, following the pointer along it.
    private func installSeekPreview() {
        let motion = gtk_event_controller_motion_new()!
        Signal.connect(motion, "motion", point: { [weak self] x, _ in self?.previewSeek(at: x) })
        Signal.connect(motion, "leave") { [weak self] in self?.seekPreview.hide() }
        gtk_widget_add_controller(seek.widget, motion)
    }

    private func previewSeek(at x: Double) {
        guard let session, session.duration > 0 else { return }
        var trough = GdkRectangle()
        gtk_range_get_range_rect(seek.widget.cast(), &trough)
        let fraction = max(0, min(1, (x - Double(trough.x)) / Double(max(1, trough.width))))
        let seconds = fraction * session.duration
        var point = graphene_point_t(x: Float(x), y: 0)
        var inPage = graphene_point_t()
        guard gtk_widget_compute_point(seek.widget, root.widget, &point, &inPage) != 0 else { return }
        seekPreview.show(
            seconds: seconds, preview: session.preview(at: seconds), x: Double(inPage.x),
            bottom: Double(root.height) - Double(inPage.y) + 6, width: Double(root.width)
        )
    }

    private func installKeys() {
        guard let window = Desktop.window else { return }
        let controller = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        Signal.connect(controller, "key-pressed", key: { [weak self] keyval, _, modifiers in
            self?.key(keyval, modifiers) ?? false
        })
        gtk_widget_add_controller(window, controller)
        keyController = controller
    }

    /// mpv's own keys, where they make sense here.
    private func key(_ keyval: UInt32, _ modifiers: GdkModifierType) -> Bool {
        guard let session else { return false }
        let shift = modifiers.rawValue & GDK_SHIFT_MASK.rawValue != 0
        switch Int32(keyval) {
        case GDK_KEY_space, GDK_KEY_k, GDK_KEY_p:
            session.togglePause()
        case GDK_KEY_Left, GDK_KEY_j:
            session.skip(by: shift ? -60 : -10)
        case GDK_KEY_Right, GDK_KEY_l:
            session.skip(by: shift ? 60 : 30)
        case GDK_KEY_Up:
            engine.setVolume(engine.volume + 5)
        case GDK_KEY_Down:
            engine.setVolume(engine.volume - 5)
        case GDK_KEY_m:
            engine.toggleMute()
        case GDK_KEY_f, GDK_KEY_F11:
            window.toggleFullscreen()
        case GDK_KEY_s:
            engine.screenshot()
            Desktop.main?.toast("Screenshot saved to Pictures")
        case GDK_KEY_v:
            cycleSubtitles(session)
        case GDK_KEY_i:
            toggleStats()
        case GDK_KEY_Return, GDK_KEY_KP_Enter:
            if session.skippable != nil { session.skipSegment() } else { return false }
        case GDK_KEY_n:
            if let next = session.next { session.playNext(next) }
        case GDK_KEY_Escape:
            if window.isFullscreen { window.toggleFullscreen() } else { window.closePlayer() }
        case GDK_KEY_q:
            window.closePlayer()
        default:
            return false
        }
        reveal()
        return true
    }

    /// What another device can do to this player beyond what the session does itself.
    func remote(_ command: RemoteCommand) {
        switch command.name {
        case "VolumeUp": engine.setVolume(engine.volume + 5)
        case "VolumeDown": engine.setVolume(engine.volume - 5)
        case "SetVolume": if let volume = command.argument("Volume").flatMap(Double.init) { engine.setVolume(volume) }
        case "Mute": if !engine.isMuted { engine.toggleMute() }
        case "Unmute": if engine.isMuted { engine.toggleMute() }
        case "ToggleMute": engine.toggleMute()
        case "TakeScreenshot": engine.screenshot()
        default: return
        }
        reveal()
    }

    private func cycleSubtitles(_ session: PlaybackSession) {
        guard let plan = session.plan else { return }
        let indices: [Int?] = [nil] + plan.subtitleStreams.map(\.index)
        let position = indices.firstIndex { $0 == plan.subtitleIndex } ?? 0
        session.selectSubtitle(indices[(position + 1) % indices.count])
    }

    private func toggleStats() {
        showsStats.toggle()
        stats.visible(showsStats)
        if showsStats, let session { stats.text = statsText(session) }
    }

    private func scrub(to value: Double) {
        scrubbing = true
        elapsed.text = Ticks.clock(value)
        // Seeking on every pixel of a drag would restart a transcode each time; seek once
        // the drag has rested. A task of its own: the pointer moving resets the bars'.
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.session?.seek(to: value)
            self.scrubbing = false
            self.reveal()
        }
    }

    private func reveal(autohide: Bool = true) {
        top.isRevealed = true
        bottom.isRevealed = true
        setCursor(visible: true)
        hideTask?.cancel()
        guard autohide else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, let session = self.session, !session.isPaused, session.error == nil,
                  !self.scrubbing, !self.pointerOnBars else { return }
            self.top.isRevealed = false
            self.bottom.isRevealed = false
            self.seekPreview.hide()
            self.setCursor(visible: false)
        }
    }

    private func setCursor(visible: Bool) {
        gtk_widget_set_cursor_from_name(root.widget, visible ? nil : "none")
    }
}
