import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The device as the server's dashboard names it, and the id it is known by.
enum DeviceInfo {
    /// Made once per install. Each install is its own device to the server, with its own
    /// session and token.
    ///
    /// Kept in a file: in UserDefaults it was lost at every start on Linux, whose Foundation
    /// never writes them out, and each start became another device on the server.
    static let id: String = {
        let file = Paths.root.appendingPathComponent("device-id")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        let made = UserDefaults.standard.string(forKey: "device.id") ?? UUID().uuidString.lowercased()
        try? made.write(to: file, atomically: true, encoding: .utf8)
        return made
    }()

    @MainActor
    static var name: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        let host = ProcessInfo.processInfo.hostName
        return host.isEmpty || host == "localhost" ? "Linux" : host
        #endif
    }

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    static var build: String {
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
        let commit = (Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String) ?? "local"
        return "\(build) (\(commit))"
    }
}
