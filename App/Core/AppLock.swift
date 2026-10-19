import Foundation
import Observation

/// The app's PIN: asked for when the app opens, and when it comes back after a while
/// away, so whoever picks up the phone cannot look through the library. It only hides
/// the app; nothing is signed out.
///
/// The PIN is in the Keychain (a private file on Linux), with the sign-in. The rest is this
/// device's alone, in its own file: it is not among the settings that follow you.
@MainActor
@Observable
final class AppLock {
    static let length = 4
    /// Wrong PINs allowed before each further one has to wait.
    static let freeTries = 5

    /// How long the app may be away before it asks again.
    enum Delay: Int, Codable, CaseIterable, Sendable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var title: String {
            switch self {
            case .immediately: return "Immediately"
            case .oneMinute: return "After 1 Minute"
            case .fiveMinutes: return "After 5 Minutes"
            case .fifteenMinutes: return "After 15 Minutes"
            }
        }
    }

    struct Settings: Codable, Equatable, Sendable {
        var delay: Delay = .oneMinute
        /// Wrong PINs in a row, kept across launches: quitting does not start the count again.
        var failures = 0
        var blockedUntil: Date?
    }

    /// Where the PIN and the settings are kept; tests keep them in memory.
    struct Storage {
        var loadPIN: @MainActor () -> String?
        var savePIN: @MainActor (String?) -> Void
        var file: URL

        static let device = Storage(
            loadPIN: { Keychain.loadPIN() },
            savePIN: { Keychain.savePIN($0) },
            file: Paths.root.appendingPathComponent("app-lock.json")
        )
    }

    enum Attempt: Equatable {
        case unlocked
        /// Wrong; this many more before having to wait.
        case wrong(triesLeft: Int)
        case wait(until: Date)
    }

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    /// Away from the screen (the app switcher, another app): what the app shows is hidden.
    private(set) var isCovered = false
    private(set) var settings: Settings {
        didSet { if settings != oldValue { save() } }
    }

    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored var now: () -> Date = Date.init

    init(storage: Storage = .device) {
        self.storage = storage
        let enabled = storage.loadPIN() != nil
        isEnabled = enabled
        isLocked = enabled
        settings = (try? Data(contentsOf: storage.file)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    /// Whether the lock screen or the cover is up.
    var isShown: Bool { isLocked || isCovered }

    static func isValid(_ pin: String) -> Bool {
        pin.count == length && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Turns the lock on, or changes the PIN.
    func setPIN(_ pin: String) {
        guard Self.isValid(pin) else { return }
        storage.savePIN(pin)
        isEnabled = true
        isLocked = false
        settings.failures = 0
        settings.blockedUntil = nil
    }

    func turnOff() {
        storage.savePIN(nil)
        isEnabled = false
        isLocked = false
        isCovered = false
        settings.failures = 0
        settings.blockedUntil = nil
    }

    func setDelay(_ delay: Delay) {
        settings.delay = delay
    }

    /// The lock screen's PIN: right unlocks; wrong counts, and past the free tries each
    /// one waits twice as long as the last, from 30 seconds up to 15 minutes.
    func attempt(_ pin: String) -> Attempt {
        let attempt = check(pin)
        if attempt == .unlocked { isLocked = false }
        return attempt
    }

    /// The same, without unlocking: Settings asks for the PIN before changing it.
    func check(_ pin: String) -> Attempt {
        if let until = waitUntil { return .wait(until: until) }
        if let stored = storage.loadPIN(), Self.matches(pin, stored) {
            settings.failures = 0
            settings.blockedUntil = nil
            return .unlocked
        }
        settings.failures += 1
        let over = settings.failures - Self.freeTries
        guard over >= 0 else { return .wrong(triesLeft: Self.freeTries - settings.failures) }
        let until = now().addingTimeInterval(min(30 * pow(2, Double(over)), 900))
        settings.blockedUntil = until
        return .wait(until: until)
    }

    /// When the next try is allowed, while it is not yet.
    var waitUntil: Date? {
        guard let until = settings.blockedUntil, until > now() else { return nil }
        return until
    }

    // MARK: - The app coming and going

    /// Not in front for a moment (the app switcher, a call, Control Center): hidden.
    ///
    /// While a video plays nothing is hidden or locked: it goes on in Picture in Picture,
    /// which shows it anyway, and coming back to it is not asked for the PIN.
    func becameInactive(playing: Bool = false) {
        if isEnabled, !playing { isCovered = true }
    }

    func enteredBackground(playing: Bool = false) {
        guard isEnabled else { return }
        if !playing { isCovered = true }
        if leftAt == nil { leftAt = now() }
    }

    /// A desktop window losing the focus: away, with nothing to hide (no app switcher
    /// shows it).
    func wentAway() {
        guard isEnabled else { return }
        if leftAt == nil { leftAt = now() }
    }

    /// In front again: locked if it was away long enough.
    func becameActive(playing: Bool = false) {
        defer {
            leftAt = nil
            isCovered = false
        }
        guard isEnabled, !playing, let leftAt else { return }
        if now().timeIntervalSince(leftAt) >= Double(settings.delay.rawValue) { isLocked = true }
    }

    // MARK: -

    /// Every digit compared, so how long a wrong PIN takes says nothing about it.
    private static func matches(_ entered: String, _ stored: String) -> Bool {
        let a = Array(entered.utf8), b = Array(stored.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { try? data.write(to: storage.file, options: .atomic) }
    }
}
