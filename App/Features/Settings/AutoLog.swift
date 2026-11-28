import SwiftUI
import UIKit

/// The log, sent to the server without anyone asking (see `LogUploader`): after each video,
/// when one fails, and when the app goes to the background. Whatever an earlier run could
/// not send (a crash, no network) goes with the next one.
@MainActor
enum AutoLog {
    /// Starts keeping the log on disk until it is sent. Called once, at launch, before
    /// anything is recorded; what an earlier run left unsent goes with the next send.
    static func start() async {
        await Diagnostics.shared.persist(in: Paths.root)
    }

    static func send(_ reason: String, state: AppState) {
        guard let client = state.client else { return }
        let header = header()
        // A few seconds more in the background to finish sending; iOS ends them early if
        // it must, and the log then waits for the next time.
        let task = BackgroundTask(name: "Send log")
        Task {
            await LogUploader.shared.send(reason: reason, header: header, client: client)
            task.end()
        }
    }

    /// The app's version and build, the phone's model and system, and this install's id.
    static func header() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let device = UIDevice.current
        return "jellymc \(DeviceInfo.appVersion), build \(DeviceInfo.build), \(machine), \(device.systemName) \(device.systemVersion), device \(DeviceInfo.id)"
    }
}

/// `beginBackgroundTask`, ended exactly once: by the work finishing or by iOS running out
/// of patience, whichever comes first.
@MainActor
private final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
