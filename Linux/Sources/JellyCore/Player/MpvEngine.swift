import CGtk
import CMpv
import Foundation

/// libmpv, drawn into a GtkGLArea through mpv's render API: the desktop's player.
///
/// mpv decodes (VA-API where the GPU can), renders into the area's framebuffer whenever it
/// has a new frame, and reports what changes through observed properties. Everything mpv
/// tells us arrives on its own threads and is posted to GTK's (see CMpv.h), so every method
/// here runs on the main actor.
///
/// One engine lives as long as the player page; each `PlaybackSession` loads its plan
/// into it, so going on to the next episode keeps the same window and surface.
@MainActor
final class MpvEngine: PlayerEngine {
    let kind: PlayerKind = .mpv
    var onEvent: (@MainActor (PlayerEvent) -> Void)?
    /// Called on every mpv log line at warn or above, for Diagnostics.
    var onLog: (@MainActor (String) -> Void)?

    /// The GtkGLArea video is drawn into.
    let view: Widget

    private var handle: OpaquePointer?
    private var render: OpaquePointer?
    private var wakeup: UnsafeMutablePointer<cmpv_wakeup>?
    private var plan: PlaybackPlan?
    private var lastReported = Date.distantPast
    private var duration: Double?
    private var ended = false
    private var pendingSubtitle: Int?

    private(set) var volume: Double = 100
    private(set) var isMuted = false

    /// Holds the engine weakly for mpv's wakeups, which may arrive after it has gone.
    private final class Box: @unchecked Sendable {
        weak var engine: MpvEngine?
        init(_ engine: MpvEngine) { self.engine = engine }
    }

    init() {
        let area = gtk_gl_area_new()!
        view = Widget(area).hexpand().vexpand()
        gtk_gl_area_set_auto_render(area.cast(), 0)

        // GTK sets the locale from the environment; libmpv refuses to start unless numbers
        // are formatted the C way ("Non-C locale detected"), so that one category goes back.
        setlocale(LC_NUMERIC, "C")
        guard let handle = mpv_create() else {
            Task { @MainActor [weak self] in self?.onEvent?(.failed("mpv could not start")) }
            return
        }
        self.handle = handle
        for (name, value) in [
            ("vo", "libmpv"),
            ("hwdec", "auto-safe"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("terminal", "no"),
            ("msg-level", "all=warn"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "150MiB"),
            ("demuxer-readahead-secs", "30"),
            ("sub-auto", "no"),
            ("ytdl", "no"),
            ("hr-seek", "yes"),
            ("user-agent", "jellymc/\(DeviceInfo.appVersion)"),
            ("audio-client-name", "jellymc"),
            ("screenshot-directory", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures").path),
        ] {
            mpv_set_option_string(handle, name, value)
        }
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            self.handle = nil
            return
        }
        mpv_request_log_messages(handle, "warn")
        for (name, format) in [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG), ("seeking", MPV_FORMAT_FLAG),
        ] {
            mpv_observe_property(handle, 0, name, format)
        }

        let drain: cmpv_drain = { data in
            guard let data else { return }
            let box = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { box.engine?.drainEvents() }
        }
        wakeup = cmpv_wakeup_install(handle, drain, Unmanaged.passRetained(Box(self)).toOpaque())

        Signal.connect(area, "realize") { [weak self] in self?.realize() }
        Signal.connect(area, "unrealize") { [weak self] in self?.unrealize() }
        Signal.connectHandled(area, "render", pointer: { [weak self] _ in self?.draw() ?? false })
    }

    // MARK: - Surface

    private func realize() {
        let area: UnsafeMutablePointer<GtkGLArea> = view.widget.cast()
        gtk_gl_area_make_current(area)
        if let error = gtk_gl_area_get_error(area) {
            let message = String(cString: error.pointee.message)
            onEvent?(.failed("OpenGL: \(message)"))
            return
        }
        guard let handle, render == nil else { return }
        render = cmpv_render_context_create(handle, cmpv_wayland_display(view.widget))
        let api = gtk_gl_area_get_api(area) == GDK_GL_API_GLES ? "GLES" : "GL"
        Task { await Diagnostics.shared.record("mpv", "render context \(self.render == nil ? "failed" : "created") on \(api)") }
        if let render {
            cmpv_set_update_area(render, view.widget)
        } else {
            onEvent?(.failed("mpv could not draw into this window"))
        }
    }

    private func unrealize() {
        guard let render else { return }
        gtk_gl_area_make_current(view.widget.cast())
        cmpv_set_update_area(render, nil)
        mpv_render_context_free(render)
        self.render = nil
    }

    private var draws = 0

    private func draw() -> Bool {
        guard let render else { return false }
        let scale = gtk_widget_get_scale_factor(view.widget)
        let result = cmpv_render(render, view.width * scale, view.height * scale)
        draws += 1
        if draws == 1 || result < 0 {
            let size = "\(view.width * scale)x\(view.height * scale)"
            Task { await Diagnostics.shared.record("mpv", "frame \(self.draws) at \(size): \(result < 0 ? String(cString: mpv_error_string(result)) : "ok")") }
        }
        return true
    }

    // MARK: - PlayerEngine

    func load(_ plan: PlaybackPlan) {
        self.plan = plan
        ended = false
        duration = nil
        setProperty("start", plan.startSeconds > 1 ? String(format: "%.3f", plan.startSeconds) : "none")
        setProperty("pause", "no")
        if plan.method == .directPlay, let audio = plan.audioIndex, let id = audioId(audio, in: plan) {
            setProperty("aid", String(id))
        } else {
            setProperty("aid", "auto")
        }
        // External subtitles are added once the file is open; until then, none.
        pendingSubtitle = plan.subtitleIndex
        if let index = plan.subtitleIndex, !plan.externalSubtitles.contains(where: { $0.streamIndex == index }),
           plan.method == .directPlay, let id = embeddedSubtitleId(index, in: plan) {
            setProperty("sid", String(id))
            pendingSubtitle = nil
        } else {
            setProperty("sid", "no")
        }
        let headers = plan.httpHeaders.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        setProperty("http-header-fields", headers)
        command(["loadfile", plan.url.absoluteString, "replace"])
    }

    func play() { setProperty("pause", "no") }
    func pause() { setProperty("pause", "yes") }

    func seek(to seconds: Double) {
        ended = false
        command(["seek", String(format: "%.3f", seconds), "absolute"])
    }

    func setRate(_ rate: Double) { setProperty("speed", String(rate)) }

    func setVolume(_ volume: Double) {
        self.volume = max(0, min(130, volume))
        setProperty("volume", String(self.volume))
    }

    func toggleMute() {
        isMuted.toggle()
        setProperty("mute", isMuted ? "yes" : "no")
    }

    func cycleSubtitles() { command(["cycle", "sub"]) }

    func screenshot() { command(["screenshot", "subtitles"]) }

    func selectAudio(_ streamIndex: Int, in plan: PlaybackPlan) -> Bool {
        guard plan.method == .directPlay, let id = audioId(streamIndex, in: plan) else { return false }
        setProperty("aid", String(id))
        return true
    }

    func selectSubtitle(_ streamIndex: Int?, in plan: PlaybackPlan) -> Bool {
        guard let streamIndex else {
            setProperty("sid", "no")
            return true
        }
        guard let id = subtitleId(streamIndex, in: plan) else { return false }
        setProperty("sid", String(id))
        return true
    }

    func stop() {
        command(["stop"])
        plan = nil
    }

    /// Frees mpv. The page calls this when it closes; the engine is unusable after it.
    func shutdown() {
        unrealize()
        guard let handle else { return }
        self.handle = nil
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
        if let wakeup {
            let release: cmpv_release = { data in
                guard let data else { return }
                Unmanaged<Box>.fromOpaque(data).release()
            }
            cmpv_wakeup_retire(wakeup, release)
            self.wakeup = nil
        }
    }

    // MARK: - Tracks

    // mpv numbers each kind of track from 1 in file order, embedded first, then each
    // `sub-add` in turn. Jellyfin numbers every stream, and lists external subtitles
    // before the file's own, so the two are matched by position within a kind.

    private func audioId(_ streamIndex: Int, in plan: PlaybackPlan) -> Int? {
        let embedded = plan.audioStreams.filter { $0.isExternal != true }.sorted { $0.index < $1.index }
        return embedded.firstIndex { $0.index == streamIndex }.map { $0 + 1 }
    }

    private func embeddedSubtitleId(_ streamIndex: Int, in plan: PlaybackPlan) -> Int? {
        guard plan.method == .directPlay else { return nil }
        let embedded = plan.subtitleStreams.filter { $0.isExternal != true && $0.deliveryMethod != "External" }.sorted { $0.index < $1.index }
        return embedded.firstIndex { $0.index == streamIndex }.map { $0 + 1 }
    }

    private func subtitleId(_ streamIndex: Int, in plan: PlaybackPlan) -> Int? {
        if let id = embeddedSubtitleId(streamIndex, in: plan) { return id }
        guard let position = plan.externalSubtitles.firstIndex(where: { $0.streamIndex == streamIndex }) else { return nil }
        let embeddedCount = plan.method == .directPlay
            ? plan.subtitleStreams.filter { $0.isExternal != true && $0.deliveryMethod != "External" }.count : 0
        return embeddedCount + position + 1
    }

    // MARK: - Events

    private func drainEvents() {
        guard let handle else { return }
        while true {
            guard let event = mpv_wait_event(handle, 0) else { return }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { return }
            switch id {
            case MPV_EVENT_PROPERTY_CHANGE:
                propertyChanged(cmpv_event_property(event).pointee)
            case MPV_EVENT_FILE_LOADED:
                fileLoaded()
            case MPV_EVENT_END_FILE:
                let end = cmpv_event_end_file(event).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(end.error))
                    onEvent?(.failed("mpv: \(message)"))
                }
            case MPV_EVENT_LOG_MESSAGE:
                let log = cmpv_event_log(event).pointee
                let text = "\(String(cString: log.prefix)): \(String(cString: log.text))".trimmingCharacters(in: .whitespacesAndNewlines)
                onLog?(text)
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
        }
    }

    private func fileLoaded() {
        setProperty("start", "none")
        guard let plan else { return }
        for subtitle in plan.externalSubtitles {
            let flag = subtitle.streamIndex == pendingSubtitle ? "select" : "auto"
            command(["sub-add", subtitle.url.absoluteString, flag, subtitle.title, subtitle.language ?? ""])
        }
        pendingSubtitle = nil
    }

    private func propertyChanged(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        switch (name, property.format) {
        case ("time-pos", MPV_FORMAT_DOUBLE):
            guard let data = property.data else { return }
            let seconds = data.assumingMemoryBound(to: Double.self).pointee
            // Several times a frame is far more than a seek bar needs.
            guard Date().timeIntervalSince(lastReported) >= 0.25 else { return }
            lastReported = Date()
            onEvent?(.position(seconds, duration: duration))
        case ("duration", MPV_FORMAT_DOUBLE):
            guard let data = property.data else { return }
            duration = data.assumingMemoryBound(to: Double.self).pointee
        case ("pause", MPV_FORMAT_FLAG):
            guard let data = property.data else { return }
            onEvent?(.paused(data.assumingMemoryBound(to: Int32.self).pointee != 0))
        case ("paused-for-cache", MPV_FORMAT_FLAG), ("seeking", MPV_FORMAT_FLAG):
            guard let data = property.data else { return }
            onEvent?(.buffering(data.assumingMemoryBound(to: Int32.self).pointee != 0))
        case ("eof-reached", MPV_FORMAT_FLAG):
            guard let data = property.data, data.assumingMemoryBound(to: Int32.self).pointee != 0, !ended, plan != nil else { return }
            ended = true
            onEvent?(.ended)
        default:
            break
        }
    }

    // MARK: - Plumbing

    private func setProperty(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func command(_ arguments: [String]) {
        guard let handle else { return }
        var strings: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        strings.append(nil)
        defer { strings.forEach { free($0) } }
        strings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                _ = mpv_command_async(handle, 0, pointer)
            }
        }
    }
}
