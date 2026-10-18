import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The device as the server's dashboard names it, and the id it is known by.
enum DeviceInfo {
    /// Made once per install. Each install is its own device to the server, with its own
    /// session and token.
    static let id: String = {
        let key = "device.id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let made = UUID().uuidString.lowercased()
        UserDefaults.standard.set(made, forKey: key)
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
