import CGtk
import Foundation

/// The server and account, playback, skipping, and what happened.
@MainActor
final class SettingsPage {
    let root: Widget
    private unowned let shell: Shell

    init(shell: Shell) {
        self.shell = shell
        let state = shell.state
        let page = PreferencesPage(title: "Settings")

        // Account
        let session = state.session
        let account = PreferencesGroup("Account")
        account.add(ActionRow(state.serverName, subtitle: [session?.serverVersion.map { "Jellyfin \($0)" }, state.client?.baseURL.absoluteString].compactMap { $0 }.joined(separator: " · "), icon: "network-server-symbolic"))
        account.add(ActionRow(session?.userName ?? "", subtitle: state.isAdministrator ? "Administrator" : "User", icon: "avatar-default-symbolic"))
        account.add(ButtonRow("Sign Out", icon: "system-log-out-symbolic", destructive: true) {
            Dialogs.alert("Sign out?", body: "Downloads and settings stay; the server forgets this device.", responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("out", "Sign Out", ADW_RESPONSE_DESTRUCTIVE)]) { response in
                guard response == "out" else { return }
                Task { await state.signOut() }
            }
        })
        page.add(account)

        // Addresses
        let addresses = PreferencesGroup("Addresses", description: "Tried in order whenever the network changes: home first, then away.")
        for address in session?.addresses ?? [] {
            let row = ActionRow(address, icon: "network-wired-symbolic")
            if (session?.addresses.count ?? 0) > 1 {
                row.suffix(Button(icon: "list-remove-symbolic", "flat", "circular") {
                    state.removeAddress(address)
                    shell.select("settings")
                }.valign(GTK_ALIGN_CENTER))
            }
            addresses.add(row)
        }
        let add = EntryRow("Add another address")
        add.onApply { text in
            Task {
                do {
                    try await state.addAddress(text)
                    shell.select("settings")
                } catch {
                    Desktop.main?.toast(error.localizedDescription)
                }
            }
        }
        addresses.add(add)
        page.add(addresses)

        // Playback
        let playback = PreferencesGroup("Playback")
        let bitrates = PlaybackPreferences.bitrateChoices
        func bitrateRow(_ title: String, _ subtitle: String, _ keyPath: WritableKeyPath<Preferences, PlaybackPreferences>) -> ComboRow {
            let current = state.preferences[keyPath: keyPath].maxBitrate
            let selected = bitrates.firstIndex { $0.bits == current } ?? 0
            return ComboRow(title, subtitle: subtitle, options: bitrates.map(\.title), selected: selected) { index in
                state.preferences[keyPath: keyPath].maxBitrate = bitrates[index].bits
            }
        }
        playback.add(bitrateRow("Quality at Home", "On the home network", \.localPlayback))
        playback.add(bitrateRow("Quality Away", "Remote or metered connections", \.remotePlayback))
        playback.add(SwitchRow("Play Next Episode Automatically", isOn: state.preferences.autoplayNext) { state.preferences.autoplayNext = $0 })
        let modes = Preferences.SubtitleMode.allCases
        playback.add(ComboRow("Subtitles", options: modes.map(\.title), selected: modes.firstIndex(of: state.preferences.subtitleMode) ?? 0) { index in
            state.preferences.subtitleMode = modes[index]
        })
        let languages: [(String?, String)] = [(nil, "Server default"), ("eng", "English"), ("jpn", "Japanese"), ("spa", "Spanish"), ("fre", "French"), ("ger", "German"), ("ita", "Italian"), ("kor", "Korean"), ("chi", "Chinese")]
        playback.add(ComboRow("Subtitle Language", options: languages.map(\.1), selected: languages.firstIndex { $0.0 == state.preferences.preferredSubtitleLanguage } ?? 0) { index in
            state.preferences.preferredSubtitleLanguage = languages[index].0
        })
        playback.add(ComboRow("Audio Language", options: languages.map(\.1), selected: languages.firstIndex { $0.0 == state.preferences.preferredAudioLanguage } ?? 0) { index in
            state.preferences.preferredAudioLanguage = languages[index].0
        })
        page.add(playback)

        // Skipping
        let skipping = PreferencesGroup("Skipping", description: "For intros, recaps and credits the server has marked, with a plugin such as Intro Skipper.")
        let actions = SegmentAction.allCases
        for kind in [MediaSegment.Kind.intro, .recap, .preview, .outro, .commercial] {
            let title = kind == .outro ? "Credits" : kind.rawValue
            skipping.add(ComboRow(title, options: actions.map(\.title), selected: actions.firstIndex(of: state.preferences.action(for: kind)) ?? 0) { index in
                state.preferences.segmentActions[kind] = actions[index]
            })
        }
        page.add(skipping)

        // Diagnostics
        let diagnostics = PreferencesGroup("Diagnostics")
        diagnostics.add(ActionRow("Recent Events", subtitle: "What played how, and what went wrong", icon: "utilities-terminal-symbolic") {
            Task {
                let text = await Diagnostics.shared.text()
                let label = Label(text.isEmpty ? "Nothing yet." : text, "monospace").wrap().selectable()
                Dialogs.sheet("Recent Events", content: ScrolledWindow(label.margin(16)).vexpand(), width: 760, height: 560)
            }
        }.chevron())
        diagnostics.add(ButtonRow("Send Log to Server", icon: "mail-send-symbolic") {
            Task {
                guard let client = state.client else { return }
                do {
                    try await client.sendLog(await Diagnostics.shared.text())
                    Desktop.main?.toast("Sent to the server's log")
                } catch {
                    Desktop.main?.toast(error.localizedDescription)
                }
            }
        })
        diagnostics.add(ActionRow("Version", subtitle: "\(DeviceInfo.appVersion) · device \(DeviceInfo.id.prefix(8))"))
        page.add(diagnostics)

        root = ToolbarView(content: page).top(HeaderBar())
        root.keep(self)
    }
}
