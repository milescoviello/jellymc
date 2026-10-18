import CGtk
import Foundation

/// The server's address, a name and a password.
@MainActor
final class SignInPage {
    private(set) var root: Widget = Bin()
    private let state: AppState
    private let address = EntryRow("Server", text: "")
    private let username = EntryRow("Username", text: "")
    private let password = EntryRow("Password", password: true)
    private let error = Label("", "error").wrap().visible(false)
    private let button = Button("Sign In", "suggested-action", "pill")
    private let spinner = Spinner().size(20).visible(false)

    init(state: AppState) {
        self.state = state
        address.inputPurpose(GTK_INPUT_PURPOSE_URL)
        let form = Box.vertical(spacing: 24) {
            Box.vertical(spacing: 6) {
                Icon("video-display-symbolic", size: 64).css("dim-label").halign(GTK_ALIGN_CENTER)
                Label("jellymc", "title-1").halign(GTK_ALIGN_CENTER)
                Label("Sign in to your Jellyfin server", "dim-label").halign(GTK_ALIGN_CENTER)
            }
            PreferencesGroup {
                address
                username
                password
            }
            error.halign(GTK_ALIGN_CENTER)
            Box.horizontal(spacing: 12) {
                spinner
                button
            }.halign(GTK_ALIGN_CENTER)
            Label("An address like 192.168.1.10, jellyfin.example.com or https://host/jellyfin", "dim-label", "caption").wrap().halign(GTK_ALIGN_CENTER)
        }
        let clamp = Clamp(form, maximum: 440)
        clamp.valign(GTK_ALIGN_CENTER).vexpand()
        let field = address
        clamp.onMap { field.grabFocus() }
        root = ToolbarView(content: clamp).top(HeaderBar().showsTitle(false))
        root.keep(self)

        button.onClicked { [weak self] in self?.submit() }
        for row in [address, username, password] {
            Signal.connect(row.widget, "entry-activated") { [weak self] in self?.submit() }
        }
    }

    private func submit() {
        let address = self.address.text.trimmingCharacters(in: .whitespaces)
        let username = self.username.text.trimmingCharacters(in: .whitespaces)
        let password = self.password.text
        guard !address.isEmpty, !username.isEmpty else {
            show("Enter the server's address and your username.")
            return
        }
        busy(true)
        Task {
            do {
                try await state.signIn(address: address, username: username, password: password)
                busy(false)
                error.visible(false)
            } catch {
                busy(false)
                show(error.localizedDescription)
            }
        }
    }

    private func busy(_ value: Bool) {
        spinner.visible(value)
        button.sensitive(!value)
    }

    private func show(_ message: String) {
        error.text = message
        error.visible(true)
    }
}
