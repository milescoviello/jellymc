import SwiftUI

/// The server and account, playback, skipping, and what happened.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var newAddress = ""
    @State private var addressError: String?
    @State private var confirmSignOut = false
    @State private var sentLog = false

    private static let languages: [(code: String?, name: String)] = [
        (nil, "Server Default"), ("eng", "English"), ("jpn", "Japanese"), ("spa", "Spanish"), ("fre", "French"),
        ("ger", "German"), ("ita", "Italian"), ("kor", "Korean"), ("chi", "Chinese"),
    ]

    var body: some View {
        @Bindable var app = state
        Form {
            Section("Account") {
                LabeledContent(state.serverName, value: state.session?.serverVersion.map { "Jellyfin \($0)" } ?? "")
                LabeledContent("Signed In As", value: state.session?.userName ?? "")
                if let address = state.client?.baseURL.absoluteString {
                    LabeledContent("Connected To", value: address)
                }
            }

            Section {
                ForEach(state.session?.addresses ?? [], id: \.self) { address in
                    Text(address)
                        .swipeActions {
                            if (state.session?.addresses.count ?? 0) > 1 {
                                Button("Remove", role: .destructive) { state.removeAddress(address) }
                            }
                        }
                }
                HStack {
                    TextField("Add another address", text: $newAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addAddress)
                    Button("Add", action: addAddress).disabled(newAddress.isEmpty)
                }
            } header: {
                Text("Addresses")
            } footer: {
                Text(addressError ?? "Tried in order whenever the network changes: home first, then away.")
                    .foregroundStyle(addressError == nil ? Color.secondary : Color.red)
            }

            Section("Playback") {
                Picker("Quality at Home", selection: $app.preferences.localPlayback.maxBitrate) {
                    ForEach(PlaybackPreferences.bitrateChoices, id: \.bits) { Text($0.title).tag($0.bits) }
                }
                Picker("Quality Away", selection: $app.preferences.remotePlayback.maxBitrate) {
                    ForEach(PlaybackPreferences.bitrateChoices, id: \.bits) { Text($0.title).tag($0.bits) }
                }
                Toggle("Play Next Episode Automatically", isOn: $app.preferences.autoplayNext)
                Toggle("Keep Styled Subtitles", isOn: $app.preferences.localPlayback.keepASSStyling)
                Picker("Subtitles", selection: $app.preferences.subtitleMode) {
                    ForEach(Preferences.SubtitleMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Subtitle Size", selection: $app.preferences.subtitleSize) {
                    ForEach(Preferences.SubtitleSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Subtitle Language", selection: $app.preferences.preferredSubtitleLanguage) {
                    ForEach(Self.languages, id: \.name) { Text($0.name).tag($0.code) }
                }
                Picker("Audio Language", selection: $app.preferences.preferredAudioLanguage) {
                    ForEach(Self.languages, id: \.name) { Text($0.name).tag($0.code) }
                }
            }

            HomeLibrariesSection()

            PINSection()

            Section {
                ForEach([MediaSegment.Kind.intro, .recap, .preview, .outro, .commercial], id: \.self) { kind in
                    Picker(kind == .outro ? "Credits" : kind.rawValue, selection: Binding(
                        get: { state.preferences.action(for: kind) },
                        set: { state.preferences.segmentActions[kind] = $0 }
                    )) {
                        ForEach(SegmentAction.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Skipping")
            } footer: {
                Text("For intros, recaps and credits the server has marked, with a plugin such as Intro Skipper.")
            }

            Section("Diagnostics") {
                NavigationLink("Recent Events") { DiagnosticsView() }
                Button(sentLog ? "Sent to the Server" : "Send Log to Server") {
                    Task {
                        guard let client = state.client else { return }
                        try? await client.sendLog(await Diagnostics.shared.text())
                        sentLog = true
                    }
                }
                LabeledContent("Version", value: "\(DeviceInfo.appVersion) (\(DeviceInfo.build))")
            }

            Section {
                Button("Sign Out", role: .destructive) { confirmSignOut = true }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await state.signOut() } }
        } message: {
            Text("The server forgets this device.")
        }
    }

    private func addAddress() {
        let text = newAddress
        Task {
            do {
                try await state.addAddress(text)
                newAddress = ""
                addressError = nil
            } catch {
                addressError = error.localizedDescription
            }
        }
    }
}

/// What played how, and what went wrong: the debugger this phone does not have.
struct DiagnosticsView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Nothing yet." : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Recent Events")
        .toolbar {
            ShareLink(item: text)
        }
        .task { text = await Diagnostics.shared.text() }
    }
}

/// Which libraries have a Recently Added row on Home: Plex's Pin to Home, kept on the
/// server so every app shows the same.
private struct HomeLibrariesSection: View {
    @Environment(AppState.self) private var state
    @State private var loaded = false

    var body: some View {
        let home = state.home
        let libraries = home.libraries.filter(HomeModel.showsLatest)
        if !libraries.isEmpty {
            Section {
                if loaded {
                    ForEach(libraries) { library in
                        Toggle(library.title, isOn: Binding(
                            get: { !home.hiddenFromHome.contains(library.id) },
                            set: { shown in
                                guard let client = state.client else { return }
                                Task { await home.setOnHome(library, shown, client: client) }
                            }
                        ))
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Home")
            } footer: {
                Text("Libraries with a Recently Added row on Home. Kept on the server, so every app shows the same.")
            }
            .task {
                if let client = state.client { await home.loadHomeSettings(client) }
                loaded = true
            }
        }
    }
}

/// The PIN asked for when the app opens.
private struct PINSection: View {
    @Environment(AppState.self) private var state
    @State private var sheet: SetPINView.Mode?

    var body: some View {
        let lock = state.lock
        Section {
            Toggle("Require PIN", isOn: Binding(get: { lock.isEnabled }, set: { sheet = $0 ? .new : .turnOff }))
            if lock.isEnabled {
                Button("Change PIN") { sheet = .change }
                Picker("Ask Again", selection: Binding(get: { lock.settings.delay }, set: { lock.setDelay($0) })) {
                    ForEach(AppLock.Delay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("PIN")
        } footer: {
            Text("Asked for when jellymc opens, and when you come back to it, so whoever picks up your phone can’t look through it. Forgot it? The lock screen takes your Jellyfin password instead.")
        }
        .sheet(item: $sheet) { mode in
            SetPINView(mode: mode)
        }
    }
}
