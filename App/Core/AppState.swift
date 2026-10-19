import Foundation
import Observation

/// The signed-in server and user, as kept in the Keychain (a private file on Linux).
struct StoredSession: Codable, Sendable, Equatable {
    /// Every address the server has been reached at, the last one that worked first.
    var addresses: [String]
    var serverId: String
    var serverName: String?
    var serverVersion: String?
    var userId: String
    var userName: String?
    var userImageTag: String?
    var isAdministrator: Bool?
    var token: String
}

/// The app's root state: who is signed in where, the preferences, and the screens' models.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case starting
        case signedOut
        case signedIn
    }

    private(set) var phase: Phase = .starting
    private(set) var client: JellyfinClient?
    private(set) var session: StoredSession?
    /// True when no address of the server answers; the app shows what it has cached.
    private(set) var isOffline = false
    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save()
            if preferences.shared != oldValue.shared, !isApplyingRoaming { scheduleRoamingSave() }
        }
    }
    @ObservationIgnored private var isApplyingRoaming = false
    /// Goes up when settings arrive from the server, for a Settings page to redraw.
    private(set) var settingsGeneration = 0
    @ObservationIgnored private var roamingSave: Task<Void, Never>?

    let device: DeviceIdentity
    let home = HomeModel()
    let search = SearchModel()
    let downloads = DownloadStore()
    let realtime = Realtime()
    /// The PIN asked for when the app opens.
    let lock = AppLock()
    /// Goes up when what pages show may have changed: the player here closed, or the
    /// server says something changed. Pages showing progress or watched marks reload.
    private(set) var dataGeneration = 0

    /// Another device asked this one to play an item; the app opens its player.
    @ObservationIgnored var onRemotePlay: (@MainActor (BaseItem, RemotePlay) -> Void)?
    /// Another device sent a message to show: a header, and the text.
    @ObservationIgnored var onRemoteMessage: (@MainActor (String, String) -> Void)?
    /// A remote command only the platform can carry out: the volume, full screen.
    @ObservationIgnored var onRemoteCommand: (@MainActor (RemoteCommand) -> Void)?
    @ObservationIgnored private var refresh: Task<Void, Never>?

    @ObservationIgnored private var isReconnecting = false
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: Double = 15

    init() {
        preferences = Preferences.load()
        device = DeviceIdentity(deviceName: DeviceInfo.name, deviceId: DeviceInfo.id, version: DeviceInfo.appVersion)
        realtime.onMessage = { [weak self] message in self?.handle(message) }
    }

    var serverName: String { session?.serverName ?? "Jellyfin" }
    var isAdministrator: Bool { session?.isAdministrator ?? false }

    // MARK: - Session

    /// Signs back in with the stored token, at whichever address answers.
    func restore() async {
        let loaded = await Task.detached { Keychain.loadSession() }.value
        guard let stored = loaded, let first = stored.addresses.first.flatMap(URL.init(string:)) else {
            phase = .signedOut
            return
        }
        session = stored
        client = JellyfinClient(baseURL: first, device: device, token: stored.token, userId: stored.userId)
        phase = .signedIn
        await reconnect()
    }

    /// Tries each known address in order and keeps the first that answers. Called at
    /// start and whenever the network changes: home Wi-Fi to cellular, a VPN coming up.
    func reconnect() async {
        guard var stored = session, !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        retry?.cancel()
        retry = nil
        for address in stored.addresses {
            guard let url = URL(string: address) else { continue }
            let probe = JellyfinClient(baseURL: url, device: device)
            guard let info = try? await probe.publicInfo(), info.id == stored.serverId else { continue }
            if address != stored.addresses.first {
                stored.addresses.removeAll { $0 == address }
                stored.addresses.insert(address, at: 0)
            }
            stored.serverVersion = info.version
            stored.serverName = info.serverName ?? stored.serverName
            let client = probe.signedIn(token: stored.token, userId: stored.userId)
            do {
                let user = try await client.currentUser()
                stored.userName = user.name
                stored.userImageTag = user.primaryImageTag
                stored.isAdministrator = user.policy?.isAdministrator
            } catch let error as JellyfinError where error.isUnauthorized {
                await Diagnostics.shared.record("session", "token refused; signing out")
                await signOut(tellServer: false)
                return
            } catch {}
            self.client = client
            self.session = stored
            Self.persist(stored)
            let wasOffline = isOffline
            retryDelay = 15
            await Diagnostics.shared.record("session", "connected to \(info.serverName ?? "server") \(info.version ?? "") at \(address)")
            await connected(client)
            // What was shown came from the cache; the server's is newer, and has whatever
            // was watched offline.
            if wasOffline { Task { await home.load(client, force: true) } }
            return
        }
        realtime.disconnect()
        isOffline = true
        await Diagnostics.shared.record("session", "no address answered; offline, trying again in \(Int(retryDelay)) s")
        scheduleRetry()
    }

    /// The network can be fine while the server is not: restarting, or the machine asleep.
    /// So an offline app keeps asking, less often the longer it has been, up to every five
    /// minutes.
    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isOffline else { return }
            await self.reconnect()
        }
    }

    /// Checks the address, signs in, and keeps the session.
    func signIn(address: String, username: String, password: String) async throws {
        let candidates = JellyfinClient.candidates(for: address)
        guard !candidates.isEmpty else {
            throw JellyfinError(kind: .badURL, message: "Enter the server's address, like 192.168.1.10 or jellyfin.example.com.")
        }
        var lastError: Error = JellyfinError(kind: .transport, message: "No server answered at that address.")
        for url in candidates {
            let probe = JellyfinClient(baseURL: url, device: device)
            let info: PublicSystemInfo
            do {
                info = try await probe.publicInfo()
            } catch {
                lastError = error
                continue
            }
            let result = try await probe.authenticate(username: username, password: password)
            let stored = StoredSession(
                addresses: [url.absoluteString],
                serverId: info.id ?? result.serverId ?? "",
                serverName: info.serverName,
                serverVersion: info.version,
                userId: result.user.id,
                userName: result.user.name,
                userImageTag: result.user.primaryImageTag,
                isAdministrator: result.user.policy?.isAdministrator,
                token: result.accessToken
            )
            Self.persist(stored)
            session = stored
            let client = probe.signedIn(token: result.accessToken, userId: result.user.id)
            self.client = client
            phase = .signedIn
            await Diagnostics.shared.record("session", "signed in to \(info.serverName ?? "server") \(info.version ?? "") as \(username)")
            await connected(client)
            return
        }
        throw lastError
    }

    /// A forgotten PIN: the account's Jellyfin password, checked by the server, turns the
    /// lock off. Nothing is signed out. Signing in again from this device replaces its
    /// token on the server, so the new one is kept and everything moves to it.
    func unlockWithPassword(_ password: String) async throws {
        guard var stored = session, let client else { throw JellyfinError(kind: .http(401), message: "Not signed in.") }
        let probe = JellyfinClient(baseURL: client.baseURL, device: device)
        let result = try await probe.authenticate(username: stored.userName ?? "", password: password)
        guard result.user.id == stored.userId else {
            throw JellyfinError(kind: .http(401), message: "That password is for a different account.")
        }
        stored.token = result.accessToken
        session = stored
        Self.persist(stored)
        let signedIn = probe.signedIn(token: result.accessToken, userId: result.user.id)
        self.client = signedIn
        lock.turnOff()
        await Diagnostics.shared.record("session", "PIN reset with the account's password")
        await connected(signedIn)
    }

    /// Adds another way to reach the same server, tried when the current one fails.
    func addAddress(_ text: String) async throws {
        guard var stored = session else { return }
        for url in JellyfinClient.candidates(for: text) {
            let info = try? await JellyfinClient(baseURL: url, device: device).publicInfo()
            guard let info else { continue }
            guard info.id == stored.serverId else {
                throw JellyfinError(kind: .notJellyfin, message: "That address is a different Jellyfin server.")
            }
            if !stored.addresses.contains(url.absoluteString) { stored.addresses.append(url.absoluteString) }
            session = stored
            Self.persist(stored)
            return
        }
        throw JellyfinError(kind: .transport, message: "Nothing answered at that address.")
    }

    func removeAddress(_ address: String) {
        guard var stored = session, stored.addresses.count > 1 else { return }
        stored.addresses.removeAll { $0 == address }
        session = stored
        Self.persist(stored)
    }

    func signOut(tellServer: Bool = true) async {
        if tellServer { await client?.logout() }
        realtime.disconnect()
        retry?.cancel()
        retry = nil
        isOffline = false
        Task.detached { Keychain.clear() }
        ResponseCache.clear()
        session = nil
        client = nil
        home.reset()
        phase = .signedOut
    }

    /// Reached the server, at sign-in or since: what waited for it goes, and it learns
    /// this device can be played to and controlled.
    private func connected(_ client: JellyfinClient) async {
        isOffline = false
        Task { await loadPlaylists() }
        Task { await pullRoamingSettings(client) }
        downloads.connect(client)
        realtime.connect(client)
        await Outbox.shared.flush(client)
        await client.registerCapabilities(playableMediaTypes: ["Video"], commands: Self.remoteCommands)
    }

    /// The player has closed. The server takes a moment with the final position, so the
    /// home rows and open pages catch up after one.
    func playbackEnded() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let client { await home.load(client, force: true) }
        dataGeneration += 1
    }

    // MARK: - Settings that follow you

    /// The server's copy wins at connect: it is what another device last chose. With none
    /// there yet, this device's settings go up as the first.
    private func pullRoamingSettings(_ client: JellyfinClient) async {
        do {
            if let data = try await client.roamingSettings(), let shared = try? JSONCoding.decoder().decode(Preferences.Shared.self, from: data) {
                guard shared != preferences.shared else { return }
                isApplyingRoaming = true
                preferences.shared = shared
                isApplyingRoaming = false
                settingsGeneration += 1
                await Diagnostics.shared.record("settings", "took the settings from the server")
            } else {
                try await client.saveRoamingSettings(JSONCoding.encoder().encode(preferences.shared))
            }
        } catch {
            await Diagnostics.shared.record("settings", "could not sync settings: \(error.localizedDescription)")
        }
    }

    /// A second after the last change, so a run of them is one write.
    private func scheduleRoamingSave() {
        roamingSave?.cancel()
        let shared = preferences.shared
        roamingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let client = self?.client, let data = try? JSONCoding.encoder().encode(shared) else { return }
            do {
                try await client.saveRoamingSettings(data)
            } catch {
                await Diagnostics.shared.record("settings", "could not save settings to the server: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - What a card's menu does, in both apps

    /// Marks watched or not, then has every page catch up.
    func setPlayed(_ item: BaseItem, _ played: Bool) async {
        guard let client else { return }
        _ = try? await client.setPlayed(played, itemId: item.id)
        await changedHere()
    }

    /// Plex's "Remove from Continue Watching": the place is forgotten, not the item.
    func removeFromContinueWatching(_ item: BaseItem) async {
        guard let client else { return }
        try? await client.setPosition(0, played: item.isPlayed, lastPlayed: item.userData?.lastPlayedDate ?? Date(), itemId: item.id)
        await changedHere()
    }

    /// The user's playlists, for "Add to Playlist"; kept from the last time asked.
    private(set) var playlists: [BaseItem] = []
    /// What "New Playlist…" was chosen for, while its name is asked (iOS asks from the root).
    var namingPlaylistFor: BaseItem?

    func loadPlaylists() async {
        guard let client else { return }
        if let found = try? await client.playlists() { playlists = found }
    }

    func add(_ item: BaseItem, to playlist: BaseItem) async {
        guard let client else { return }
        try? await client.addToPlaylist(playlist.id, ids: [item.id])
        await Diagnostics.shared.record("playlists", "added \(item.title) to \(playlist.title)")
        dataGeneration += 1
    }

    func newPlaylist(_ name: String, with item: BaseItem) async {
        guard let client, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        _ = try? await client.createPlaylist(name: name, ids: [item.id])
        await loadPlaylists()
        await changedHere()
    }

    private func changedHere() async {
        if let client { await home.load(client, force: true) }
        dataGeneration += 1
    }

    // MARK: - From the server

    /// What other devices can ask of this one (GeneralCommandType names; Play and PlayState
    /// are the Play and Playstate messages).
    static var remoteCommands: [String] {
        var commands = ["Play", "PlayState", "SetAudioStreamIndex", "SetSubtitleStreamIndex", "DisplayMessage"]
        #if !os(iOS)
        // An iPhone's volume and screen are its own.
        commands += ["VolumeUp", "VolumeDown", "SetVolume", "Mute", "Unmute", "ToggleMute", "ToggleFullscreen", "TakeScreenshot"]
        #endif
        return commands
    }

    private func handle(_ message: ServerMessage) {
        let session = PlaybackSession.current
        switch message {
        case let .userDataChanged(changes):
            // This device's own reports come back too; what is playing knows its place.
            guard changes.contains(where: { $0.itemId != session?.item.id }) else { return }
            scheduleRefresh()
        case .libraryChanged:
            scheduleRefresh()
        case let .play(request):
            guard request.playCommand == nil || ["PlayNow", "PlayNext", "PlayLast"].contains(request.playCommand),
                  let id = request.itemId, let client
            else { return }
            Task {
                guard let item = try? await client.item(id) else { return }
                await Diagnostics.shared.record("realtime", "asked to play \(item.title)")
                onRemotePlay?(item, request)
            }
        case let .playstate(request):
            guard let session else { return }
            switch request.command {
            case "Stop": session.end()
            case "Pause": session.setPaused(true)
            case "Unpause": session.setPaused(false)
            case "PlayPause": session.togglePause()
            case "Seek": if let ticks = request.seekPositionTicks { session.seek(to: Ticks.seconds(ticks)) }
            case "Rewind": session.skip(by: -10)
            case "FastForward": session.skip(by: 30)
            case "NextTrack": if let next = session.next { session.playNext(next) }
            case "PreviousTrack": session.seek(to: 0)
            default: break
            }
        case let .command(command):
            switch command.name {
            case "SetAudioStreamIndex":
                if let index = command.argument("Index").flatMap(Int.init) { session?.selectAudio(index) }
            case "SetSubtitleStreamIndex":
                // -1 is off.
                if let index = command.argument("Index").flatMap(Int.init) { session?.selectSubtitle(index < 0 ? nil : index) }
            case "DisplayMessage":
                onRemoteMessage?(command.argument("Header") ?? "", command.argument("Text") ?? "")
            default:
                onRemoteCommand?(command)
            }
        case .forceKeepAlive, .other:
            break
        }
    }

    /// Changes come in bursts, and while something plays here the pages wait: closing the
    /// player reloads them anyway.
    private func scheduleRefresh() {
        refresh?.cancel()
        refresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, PlaybackSession.current == nil, let client = self.client else { return }
            await Diagnostics.shared.record("realtime", "changed on the server; reloading")
            await self.home.load(client, force: true)
            self.dataGeneration += 1
        }
    }

    // MARK: - Playback settings

    /// Home network or away: a LAN address is home, anything else (or a metered
    /// connection) is away.
    func playbackPreferences(network: NetworkKind) -> PlaybackPreferences {
        if network == .cellular { return preferences.remotePlayback }
        guard let host = client?.baseURL.host else { return preferences.localPlayback }
        return Self.isLocal(host: host) ? preferences.localPlayback : preferences.remotePlayback
    }

    nonisolated static func isLocal(host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16 ... 31): return true
        default: return false
        }
    }
}

extension AppState {
    /// Written off the main actor: the Keychain and the disk can both be slow.
    nonisolated static func persist(_ session: StoredSession) {
        Task.detached(priority: .utility) { Keychain.save(session) }
    }
}
