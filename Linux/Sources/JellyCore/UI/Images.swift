import CGtk
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Artwork from the server, decoded once and kept.
///
/// Jellyfin's image URLs carry the image's tag, a hash of its content, so a URL never
/// changes meaning: what is on disk is good forever, and only space evicts it.
@MainActor
final class Images {
    static let shared = Images()

    private var memory: [URL: Texture] = [:]
    private var order: [URL] = []
    private var inFlight: [URL: [(Texture?) -> Void]] = [:]
    private let limit = 400
    private let directory: URL = {
        let url = Paths.cache.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func cached(_ url: URL) -> Texture? { memory[url] }

    /// Calls back on the main actor with the texture, or nil if there is none.
    func load(_ url: URL, _ done: @escaping @MainActor (Texture?) -> Void) {
        if let texture = memory[url] {
            done(texture)
            return
        }
        if inFlight[url] != nil {
            inFlight[url]?.append(done)
            return
        }
        inFlight[url] = [done]
        // A picture saved with a download is read where it is.
        let file = url.isFileURL ? url : directory.appendingPathComponent(Self.key(url))
        Task.detached(priority: .utility) {
            var texture: Texture?
            if let data = try? Data(contentsOf: file) {
                texture = Texture(data: data)
            }
            if texture == nil, !url.isFileURL, let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                texture = Texture(data: data)
                if texture != nil { try? data.write(to: file, options: .atomic) }
            }
            let result = Unchecked(texture)
            await MainActor.run { Images.shared.finish(url, result.value) }
        }
    }

    private func finish(_ url: URL, _ texture: Texture?) {
        if let texture {
            memory[url] = texture
            order.append(url)
            if order.count > limit {
                memory[order.removeFirst()] = nil
            }
        }
        let waiting = inFlight.removeValue(forKey: url) ?? []
        for done in waiting { done(texture) }
    }

    private static func key(_ url: URL) -> String {
        // FNV-1a: stable across runs, unlike Swift's hashValue.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

extension Picture {
    /// Shows `url`'s image once loaded, unless the picture has been given another since.
    func load(_ url: URL?) {
        let pointer = widget
        g_object_set_data(pointer.gobject, "jellymc-url", nil)
        guard let url else {
            set(nil)
            return
        }
        if let texture = Images.shared.cached(url) {
            set(texture)
            return
        }
        set(nil)
        let token = Unmanaged.passRetained(url.absoluteString as NSString)
        g_object_set_data_full(pointer.gobject, "jellymc-url", token.toOpaque()) { data in
            guard let data else { return }
            Unmanaged<NSString>.fromOpaque(data).release()
        }
        let weak = WeakObject(pointer)
        Images.shared.load(url) { texture in
            weak.withObject { object in
                guard let data = g_object_get_data(object.assumingMemoryBound(to: GObject.self), "jellymc-url"),
                      Unmanaged<NSString>.fromOpaque(data).takeUnretainedValue() as String == url.absoluteString
                else { return }
                gtk_picture_set_paintable(OpaquePointer(object), texture?.paintable)
            }
        }
    }
}

