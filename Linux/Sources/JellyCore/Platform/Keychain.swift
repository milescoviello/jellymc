import Foundation

/// The iPhone's Keychain wrapper, on the desktop: files only this user can read, beside the
/// preferences in ~/.local/share/jellymc. The desktop's keyring is not used: asking it
/// opens a wallet prompt (KWallet's first-use wizard on Plasma), on every start.
enum Keychain {
    static func save(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        write(data, to: sessionFile)
    }

    static func loadSession() -> StoredSession? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: sessionFile)
    }

    // MARK: - The app's PIN

    static func savePIN(_ pin: String?) {
        guard let pin else {
            try? FileManager.default.removeItem(at: pinFile)
            return
        }
        write(Data(pin.utf8), to: pinFile)
    }

    static func loadPIN() -> String? {
        (try? Data(contentsOf: pinFile)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: -

    // The names the keyring's fallback used, so a sign-in kept that way still counts.
    private static var sessionFile: URL { Paths.root.appendingPathComponent(".session.json") }
    private static var pinFile: URL { Paths.root.appendingPathComponent(".app-pin.json") }

    /// Written beside and moved into place, created readable by this user alone: there is
    /// no moment at which another user could read it, or a crash leave half of it.
    private static func write(_ data: Data, to url: URL) {
        let manager = FileManager.default
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            Task { await Diagnostics.shared.record("session", "could not write \(url.lastPathComponent)") }
            return
        }
        if rename(temporary.path, url.path) != 0 {
            try? manager.removeItem(at: temporary)
            Task { await Diagnostics.shared.record("session", "could not move \(url.lastPathComponent) into place") }
        }
    }
}
