import CGtk
import CMpv
import Foundation

/// The one window: signing in, the library, and the player over everything.
@MainActor
final class MainWindow {
    let state = AppState()
    let window: UnsafeMutablePointer<GtkWidget>
    let reachability = Reachability()
    private let stack = Stack()
    /// The app, or the PIN over all of it.
    private let top = Stack()
    private let toasts: ToastOverlay
    private var lockPage: LockPage?
    private var lockKeys: OpaquePointer?
    private var shell: Shell?
    private var player: PlayerPage?

    init(application: OpaquePointer) {
        window = adw_application_window_new(application.cast())!
        gtk_window_set_title(window.cast(), "jellymc")
        gtk_window_set_default_size(window.cast(), 1360, 860)
        Style.install()
        Icons.install()

        top.add(stack, name: "app")
        toasts = ToastOverlay(top)
        adw_application_window_set_content(window.cast(), toasts.widget)

        let starting = Box.vertical {
            Spinner().size(48).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER).vexpand()
        }
        stack.add(starting, name: "starting")
        stack.add(SignInPage(state: state).root, name: "signin")

        stack.observe { [weak self] in
            guard let self else { return }
            switch self.state.phase {
            case .starting:
                self.stack.visibleName = "starting"
            case .signedOut:
                self.dropShell()
                self.stack.visibleName = "signin"
            case .signedIn:
                self.showShell()
            }
        }

        installLock()

        reachability.onNetworkChange = { [weak self] in
            guard let self else { return }
            Task { await self.state.reconnect() }
        }
        installRemoteControl()

        gtk_window_present(window.cast())
        Task { await state.restore() }
    }

    // MARK: - PIN

    /// The PIN over the whole window: when the app opens, and when the window comes back to
    /// the front after being away longer than Settings says. Signed out there is nothing to
    /// hide; while a video plays nothing locks.
    private func installLock() {
        top.observe { [weak self] in
            guard let self else { return }
            self.setLocked(self.state.lock.isLocked && self.state.phase != .signedOut)
        }
        Signal.connect(window, "notify::is-active", pointer: { [weak self] _ in
            guard let self else { return }
            let playing = PlaybackSession.current != nil
            if gtk_window_is_active(self.window.cast()) != 0 {
                self.state.lock.becameActive(playing: playing)
            } else {
                self.state.lock.wentAway()
            }
        })
    }

    private func setLocked(_ locked: Bool) {
        if locked, lockPage == nil {
            let page = LockPage(state: state)
            lockPage = page
            top.add(page.root, name: "lock")
            top.visibleName = "lock"
            // Every key goes to the PIN while it is up, before the shell's and the player's.
            let controller = gtk_event_controller_key_new()!
            gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
            Signal.connect(controller, "key-pressed", key: { [weak self] keyval, _, modifiers in
                guard let self, let page = self.lockPage else { return false }
                let control = modifiers.rawValue & GDK_CONTROL_MASK.rawValue != 0
                if control, Int32(keyval) == GDK_KEY_q { return false }
                // A dialog over the lock (Forgot PIN) types for itself.
                if adw_application_window_get_visible_dialog(self.window.cast()) != nil { return false }
                _ = page.key(keyval)
                return true
            })
            gtk_widget_add_controller(window, controller)
            lockKeys = controller
        } else if !locked, let page = lockPage {
            lockPage = nil
            top.visibleName = "app"
            top.remove(page.root)
            if let lockKeys { gtk_widget_remove_controller(window, lockKeys.cast()) }
            lockKeys = nil
        }
    }

    func toast(_ message: String) {
        toasts.show(message, timeout: 3)
    }

    /// Another device (a phone, the web app) plays something here or controls the player.
    private func installRemoteControl() {
        state.onRemotePlay = { [weak self] item, request in
            guard let self, self.state.phase == .signedIn else { return }
            self.play(item, from: request.start, audioIndex: request.audioStreamIndex, subtitleIndex: request.subtitleStreamIndex, mediaSourceId: request.mediaSourceId)
            gtk_window_present(self.window.cast())
        }
        state.onRemoteMessage = { [weak self] header, text in
            self?.toasts.show([header, text].filter { !$0.isEmpty }.joined(separator: ": "), timeout: 6)
        }
        state.onRemoteCommand = { [weak self] command in
            guard let self else { return }
            if command.name == "ToggleFullscreen" {
                self.toggleFullscreen()
            } else {
                self.player?.remote(command)
            }
        }
    }

    private func showShell() {
        if shell == nil {
            let shell = Shell(window: self)
            self.shell = shell
            stack.add(shell.root, name: "shell")
        }
        if player == nil { stack.visibleName = "shell" }
    }

    private func dropShell() {
        closePlayer()
        guard let shell else { return }
        shell.detach()
        stack.remove(shell.root)
        self.shell = nil
    }

    // MARK: - Player

    func play(
        _ item: BaseItem, from start: Double? = nil, audioIndex: Int? = nil, subtitleIndex: Int? = nil,
        mediaSourceId: String? = nil, queue: [BaseItem] = []
    ) {
        guard let client = state.client else { return }
        let continuing = PlaybackSession.Continuation(queue: queue)
        if let player {
            player.start(item, from: start, audioIndex: audioIndex, subtitleIndex: subtitleIndex, mediaSourceId: mediaSourceId, continuing: continuing)
            return
        }
        let page = PlayerPage(window: self, client: client)
        player = page
        stack.add(page.root, name: "player")
        stack.visibleName = "player"
        page.start(item, from: start, audioIndex: audioIndex, subtitleIndex: subtitleIndex, mediaSourceId: mediaSourceId, continuing: continuing)
    }

    func closePlayer() {
        guard let player else { return }
        self.player = nil
        player.close()
        if gtk_window_is_fullscreen(window.cast()) != 0 { gtk_window_unfullscreen(window.cast()) }
        stack.visibleName = shell == nil ? "signin" : "shell"
        stack.remove(player.root)
        Task {
            await self.state.playbackEnded()
            self.shell?.refreshVisible()
            // A film's decoding buffers are hundreds of megabytes, freed by now but kept by
            // the allocator for next time; it hands them back to the system.
            cmpv_release_free_memory()
        }
    }

    func toggleFullscreen() {
        if gtk_window_is_fullscreen(window.cast()) != 0 {
            gtk_window_unfullscreen(window.cast())
        } else {
            gtk_window_fullscreen(window.cast())
        }
    }

    var isFullscreen: Bool { gtk_window_is_fullscreen(window.cast()) != 0 }

    /// The playback settings for where the server is being reached from right now.
    var playbackPreferences: PlaybackPreferences {
        state.playbackPreferences(network: reachability.network)
    }
}
