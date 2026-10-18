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
        let stored = withDeadline(false) {
            let attributes = attributesTable(account)
            defer { g_hash_table_unref(attributes) }
            var error: UnsafeMutablePointer<GError>?
            let ok = secret_password_storev_sync(csecret_jellymc_schema(), attributes, "default", label, secret, nil, &error)
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
        // The file exists only because the keyring failed before; asking it again would
        // mean waiting out the same failure on every launch.
        if let data = try? Data(contentsOf: fallbackFile(account)) { return data }
        return withDeadline(nil) { () -> Data? in
            let attributes = attributesTable(account)
            defer { g_hash_table_unref(attributes) }
            var error: UnsafeMutablePointer<GError>?
            let password = secret_password_lookupv_sync(csecret_jellymc_schema(), attributes, nil, &error)
            if let error { g_error_free(error) }
            guard let password else { return nil }
            defer { secret_password_free(password) }
            return Data(String(cString: password).utf8)
        }
    }

    private static func delete(account: String) {
        try? FileManager.default.removeItem(at: fallbackFile(account))
        withDeadline(()) {
            let attributes = attributesTable(account)
            defer { g_hash_table_unref(attributes) }
            var error: UnsafeMutablePointer<GError>?
            secret_password_clearv_sync(csecret_jellymc_schema(), attributes, nil, &error)
            if let error { g_error_free(error) }
        }
    }

    /// The item's attributes, owning their strings: a call that outlives its deadline
    /// keeps using them.
    private static func attributesTable(_ account: String) -> OpaquePointer? {
        let table = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free)
        g_hash_table_insert(table, g_strdup("account"), g_strdup(account))
        return table
    }

    private final class Outcome<Value: Sendable>: @unchecked Sendable {
        var value: Value?
        let done = DispatchSemaphore(value: 0)
    }

    /// Runs a keyring call on a thread of its own and waits five seconds for it.
    ///
    /// KDE's ksecretd answers libsecret's first-use prompt (the wallet wizard) with a reply
    /// libsecret does not expect, and the synchronous call then never returns, cancellable
    /// or not. Past the deadline the call is abandoned, its thread left to it, and the
    /// caller goes on as if there were no keyring.
    @discardableResult
    private static func withDeadline<Value: Sendable>(_ fallback: Value, _ call: @escaping @Sendable () -> Value) -> Value {
        let outcome = Outcome<Value>()
        Thread {
            outcome.value = call()
            outcome.done.signal()
        }.start()
        guard outcome.done.wait(timeout: .now() + 5) == .success else {
            Task { await Diagnostics.shared.record("keyring", "the Secret Service did not answer within 5 s") }
            return fallback
        }
        return outcome.value ?? fallback
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
