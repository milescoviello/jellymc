import Foundation

/// Where the app keeps its files: Application Support on iOS, `$XDG_DATA_HOME/jellymc` on
/// Linux. Created on first use.
enum Paths {
    static let root: URL = {
        #if os(Linux)
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let url = base.appendingPathComponent("jellymc", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("jellymc", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let cache: URL = {
        #if os(Linux)
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let url = base.appendingPathComponent("jellymc", isDirectory: true)
        #else
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("jellymc", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func cacheFile(_ name: String) -> URL {
        cache.appendingPathComponent(name)
    }
}
