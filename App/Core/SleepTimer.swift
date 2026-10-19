import Foundation
import Observation

/// Plex's sleep timer: pause after so many minutes, or at the end of what is playing.
@MainActor
@Observable
final class SleepTimer {
    enum Choice: String, CaseIterable, Sendable {
        case off, fifteen, thirty, fortyFive, sixty, ninety, endOfItem

        var title: String {
            switch self {
            case .off: return "Off"
            case .fifteen: return "15 Minutes"
            case .thirty: return "30 Minutes"
            case .fortyFive: return "45 Minutes"
            case .sixty: return "1 Hour"
            case .ninety: return "1 Hour 30 Minutes"
            case .endOfItem: return "End of Episode or Film"
            }
        }

        var seconds: Double? {
            switch self {
            case .fifteen: return 15 * 60
            case .thirty: return 30 * 60
            case .fortyFive: return 45 * 60
            case .sixty: return 60 * 60
            case .ninety: return 90 * 60
            case .off, .endOfItem: return nil
            }
        }
    }

    private(set) var choice: Choice = .off
    /// When a timed choice runs out.
    private(set) var deadline: Date?
    /// Called when it is time: the player pauses.
    @ObservationIgnored var onFire: (@MainActor () -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    func set(_ choice: Choice, now: Date = Date()) {
        task?.cancel()
        task = nil
        self.choice = choice
        deadline = choice.seconds.map { now.addingTimeInterval($0) }
        guard let seconds = choice.seconds else { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.fire()
        }
    }

    /// What is playing has ended. True when the timer stops here, instead of going on to
    /// the next.
    func itemEnded() -> Bool {
        guard choice == .endOfItem else { return false }
        fire()
        return true
    }

    private func fire() {
        choice = .off
        deadline = nil
        task = nil
        onFire?()
    }
}
