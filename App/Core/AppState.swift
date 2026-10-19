import Foundation
import Observation

/// The signed-in server and user, as kept in the Keychain (libsecret on Linux).
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
        didSet { if preferences != oldValue { preferences.save() } }
    }

    let device: DeviceIdentity
    let home = HomeModel()
    let search = SearchModel()

    init() {
        preferences = Preferences.load()
        device = DeviceIdentity(deviceName: DeviceInfo.name, deviceId: DeviceInfo.id, version: DeviceInfo.appVersion)
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
        guard var stored = session else { return }
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
            isOffline = false
            await Diagnostics.shared.record("session", "connected to \(info.serverName ?? "server") \(info.version ?? "") at \(address)")
            await client.registerCapabilities(playableMediaTypes: ["Video"], commands: ["Play", "Playstate", "SetAudioStreamIndex", "SetSubtitleStreamIndex", "DisplayMessage"])
            return
        }
        isOffline = true
        await Diagnostics.shared.record("session", "no address answered; offline")
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
            client = probe.signedIn(token: result.accessToken, userId: result.user.id)
            isOffline = false
            phase = .signedIn
            await Diagnostics.shared.record("session", "signed in to \(info.serverName ?? "server") \(info.version ?? "") as \(username)")
            return
        }
        throw lastError
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
        Task.detached { Keychain.clear() }
        ResponseCache.clear()
        session = nil
        client = nil
        home.reset()
        phase = .signedOut
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
    /// The keyring can be slow, or wait on a prompt (a desktop's first-use wallet wizard),
    /// so it is never asked from the main actor.
    nonisolated static func persist(_ session: StoredSession) {
        Task.detached(priority: .utility) { Keychain.save(session) }
    }
}
