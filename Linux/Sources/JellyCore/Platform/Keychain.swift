import CGtk
import CSecret
import Foundation

/// The iPhone's Keychain wrapper, on the desktop's keyring.
///
/// libsecret talks to whatever implements the Secret Service — GNOME Keyring, or KWallet
/// on Plasma — so the token lives where the desktop keeps every other password. The same
/// item as on the phone, as JSON, under the same name.
///
/// With no keyring at all it falls back to a file only this user can read: signing in on
/// every launch would be worse, and the fallback is recorded in Diagnostics.
enum Keychain {
    private static let account = "session"

    static func save(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        write(data, account: account, label: "jellymc: Jellyfin sign-in")
    }

    static func loadSession() -> StoredSession? {
        guard let data = read(account: account) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    static func clear() {
        delete(account: account)
    }

    // MARK: - Plumbing

    private static func write(_ data: Data, account: String, label: String) {
        let secret = String(decoding: data, as: UTF8.self)
        let stored = withAttributes(account) { attributes in
            var error: UnsafeMutablePointer<GError>?
            let ok = secret_password_storev_sync(
                csecret_jellymc_schema(), attributes, "default", label, secret, nil, &error
            )
            if let error { g_error_free(error) }
            return ok != 0
        }
        if stored {
            try? FileManager.default.removeItem(at: fallbackFile(account))
            return
        }
        writeFallback(data, account: account)
    }

    private static func read(account: String) -> Data? {
        let found: Data? = withAttributes(account) { attributes in
            var error: UnsafeMutablePointer<GError>?
            let password = secret_password_lookupv_sync(csecret_jellymc_schema(), attributes, nil, &error)
            if let error { g_error_free(error) }
            guard let password else { return nil }
            defer { secret_password_free(password) }
            return Data(String(cString: password).utf8)
        }
        return found ?? (try? Data(contentsOf: fallbackFile(account)))
    }

    private static func delete(account: String) {
        withAttributes(account) { attributes in
            var error: UnsafeMutablePointer<GError>?
            secret_password_clearv_sync(csecret_jellymc_schema(), attributes, nil, &error)
            if let error { g_error_free(error) }
        }
        try? FileManager.default.removeItem(at: fallbackFile(account))
    }

    private static func withAttributes<T>(_ account: String, _ body: (OpaquePointer?) -> T) -> T {
        let table = g_hash_table_new(g_str_hash, g_str_equal)
        defer { g_hash_table_unref(table) }
        return "account".withCString { key in
            account.withCString { value in
                g_hash_table_insert(table, UnsafeMutableRawPointer(mutating: key), UnsafeMutableRawPointer(mutating: value))
                return body(table)
            }
        }
    }

    // MARK: - Without a keyring

    private static func fallbackFile(_ account: String) -> URL {
        Paths.root.appendingPathComponent(".\(account).json")
    }

    private static func writeFallback(_ data: Data, account: String) {
        let url = fallbackFile(account)
        _ = FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        Task { await Diagnostics.shared.record("keyring", "no Secret Service; \(account) kept in a private file") }
    }
}
