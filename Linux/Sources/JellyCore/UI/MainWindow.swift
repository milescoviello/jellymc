import CGtk
import Foundation

/// The one window: signing in, the library, and the player over everything.
@MainActor
final class MainWindow {
    let state = AppState()
    let window: UnsafeMutablePointer<GtkWidget>
    let reachability = Reachability()
    private let stack = Stack()
    private let toasts: ToastOverlay
    private var shell: Shell?
    private var player: PlayerPage?

    init(application: OpaquePointer) {
        window = adw_application_window_new(application.cast())!
        gtk_window_set_title(window.cast(), "jellymc")
        gtk_window_set_default_size(window.cast(), 1360, 860)
        Style.install()

        toasts = ToastOverlay(stack)
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

        reachability.onNetworkChange = { [weak self] in
            guard let self else { return }
            Task { await self.state.reconnect() }
        }

        gtk_window_present(window.cast())
        Task { await state.restore() }
    }

    func toast(_ message: String) {
        toasts.show(message, timeout: 3)
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
        stack.remove(shell.root)
        self.shell = nil
    }

    // MARK: - Player

    func play(_ item: BaseItem, from start: Double? = nil, audioIndex: Int? = nil, subtitleIndex: Int? = nil, mediaSourceId: String? = nil) {
        guard let client = state.client else { return }
        if let player {
            player.start(item, from: start, audioIndex: audioIndex, subtitleIndex: subtitleIndex, mediaSourceId: mediaSourceId)
            return
        }
        let page = PlayerPage(window: self, client: client)
        player = page
        stack.add(page.root, name: "player")
        stack.visibleName = "player"
        page.start(item, from: start, audioIndex: audioIndex, subtitleIndex: subtitleIndex, mediaSourceId: mediaSourceId)
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
