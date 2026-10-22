import Foundation
import Observation

/// Casting's other half: what this user's other apps are playing, and simple control of
/// it from here — play and pause, seek, skip, the next episode, stop.
///
/// The server's sessions are read every few seconds while watched. An app reports at once
/// on a pause or a seek and every ten seconds otherwise, so between reports the position
/// is counted on from the last one. What is asked here shows straight away, until a report
/// agrees or a few seconds pass.
@MainActor
@Observable
final class RemoteControl {
    /// What is playing elsewhere: the one Play On sent to, else the newest.
    private(set) var session: RemoteSession?
    /// Play On has just asked a device to play this; it shows until the device reports.
    private(set) var starting: (session: RemoteSession, item: BaseItem)?
    private var pendingPause: (paused: Bool, at: Date)?
    private var pendingPosition: (seconds: Double, at: Date)?

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var followed: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored var now: () -> Date = Date.init

    /// Every five seconds, or every second and a half while a remote is on screen.
    var isOnScreen = false {
        didSet { if isOnScreen, !oldValue { refreshSoon(after: 0) } }
    }

    var item: BaseItem? { session?.nowPlayingItem ?? starting?.item }
    var deviceName: String { (session ?? starting?.session)?.deviceName ?? "the other device" }
    var isShown: Bool { session != nil || starting != nil }
    var duration: Double { item?.runtime ?? 0 }

    var isPaused: Bool {
        if let pendingPause, now().timeIntervalSince(pendingPause.at) < 6 { return pendingPause.paused }
        return session?.playState?.isPaused ?? false
    }

    /// Where it is now: the last report, counted on while playing.
    func position(at date: Date? = nil) -> Double {
        let date = date ?? now()
        if let pendingPosition, date.timeIntervalSince(pendingPosition.at) < 6 {
            return clamp(pendingPosition.seconds + (isPaused ? 0 : date.timeIntervalSince(pendingPosition.at)))
        }
        guard let session else { return 0 }
        let reported = Ticks.seconds(session.playState?.positionTicks ?? 0)
        guard !isPaused, let checkIn = session.lastPlaybackCheckIn else { return clamp(reported) }
        // A report is at most ten seconds old; more than that is a clock that disagrees.
        return clamp(reported + min(max(0, date.timeIntervalSince(checkIn)), 15))
    }

    // MARK: - Watching

    /// Starts reading the server's sessions; `stop` ends it.
    func start(_ client: JellyfinClient) {
        self.client = client
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.read()
                let wait = self.isOnScreen || self.starting != nil ? 1.5 : 5
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        session = nil
        starting = nil
    }

    /// Play On sent something to `session`: follow it, and show it starting.
    func follow(_ remote: RemoteSession, playing item: BaseItem) {
        followed = remote.id
        starting = (remote, item)
        startedAt = now()
        refreshSoon(after: 1)
    }

    // MARK: - Control

    func togglePause() {
        guard let session else { return }
        let paused = !isPaused
        // Held where it is now, then counted on (or not) by the new state.
        pendingPosition = (position(), now())
        pendingPause = (paused, now())
        send(paused ? "Pause" : "Unpause", to: session)
    }

    func seek(to seconds: Double) {
        guard let session else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        pendingPosition = (target, now())
        send("Seek", to: session, seekTo: target)
    }

    func skip(by seconds: Double) {
        seek(to: position() + seconds)
    }

    func next() {
        guard let session else { return }
        send("NextTrack", to: session)
    }

    func stopPlayback() {
        guard let session else { return }
        send("Stop", to: session)
        self.session = nil
    }

    // MARK: -

    private func send(_ command: String, to session: RemoteSession, seekTo seconds: Double? = nil) {
        guard let client else { return }
        Task {
            do {
                try await client.sendPlaystate(command, to: session.id, seekTo: seconds)
            } catch {
                await Diagnostics.shared.record("remote", "\(command) on \(session.deviceName ?? session.id) failed: \(error.localizedDescription)")
            }
            refreshSoon(after: 0.8)
        }
    }

    private func refreshSoon(after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self?.read()
        }
    }

    private func read() async {
        guard let client, let sessions = try? await client.playingSessions() else { return }
        apply(sessions)
    }

    /// The newest reading: the followed device if it plays, else the newest that does.
    func apply(_ sessions: [RemoteSession]) {
        let chosen = sessions.first { $0.id == followed } ?? sessions.first
        if let chosen, let starting, chosen.id == starting.session.id { self.starting = nil }
        // A device that never started playing is given up on after twenty seconds.
        if let starting, now().timeIntervalSince(startedAt ?? now()) > 20, chosen?.id != starting.session.id { self.starting = nil }
        // A report that agrees with what was asked ends the wait for it.
        if let pendingPause, chosen?.playState?.isPaused == pendingPause.paused { self.pendingPause = nil }
        if pendingPosition != nil, chosen?.lastPlaybackCheckIn != session?.lastPlaybackCheckIn { pendingPosition = nil }
        session = chosen
        if chosen == nil, starting == nil { followed = nil }
    }

    private func clamp(_ seconds: Double) -> Double {
        duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
    }
}
