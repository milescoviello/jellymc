import Foundation

/// The last answer to a request, on disk, so a screen can show something the moment it
/// opens — and something at all when the server cannot be reached.
enum ResponseCache {
    private static var directory: URL {
        let url = Paths.cache.appendingPathComponent("responses", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? JSONCoding.decoder().decode(T.self, from: data)
    }

    static func store<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONCoding.encoder().encode(value) else { return }
        try? data.write(to: file(key), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
