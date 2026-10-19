import Foundation

/// The few MP4 boxes the app has to touch in a downloaded file.
enum MP4 {
    /// Sample entry types AVPlayer refuses, and the ones it opens instead. They differ only
    /// in whether parameter sets may also travel in the stream; ffmpeg writes the full set
    /// into `hvcC` either way, so the swap is what `-tag:v hvc1` does. Jellyfin's direct
    /// stream copies HEVC out of MKV as `hev1`, with no way to ask otherwise.
    static let appleTags: [String: String] = ["hev1": "hvc1", "dvhe": "dvh1"]

    /// Containers on the way from `moov` to the sample descriptions.
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    /// Retags the file's HEVC tracks in place, so AVPlayer will open it. Returns how many
    /// sample entries changed; a file with none, or not an MP4, is left as it is.
    @discardableResult
    static func retagHEVC(at url: URL) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= length {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16).map(Array.init), let box = boxHeader(header, at: 0, limit: length - offset) else { break }
            if box.type == "moov" {
                try handle.seek(toOffset: offset)
                guard var moov = try handle.read(upToCount: Int(box.size)).map(Array.init), moov.count == Int(box.size) else { break }
                let changed = retag(&moov, in: box.headerSize ..< moov.count)
                for position in changed {
                    try handle.seek(toOffset: offset + UInt64(position))
                    try handle.write(contentsOf: Data(moov[position ..< position + 4]))
                }
                return changed.count
            }
            offset += box.size
        }
        return 0
    }

    /// The same, for bytes already in memory: the positions of the types it rewrote.
    static func retag(_ bytes: inout [UInt8], in range: Range<Int>) -> [Int] {
        var changed: [Int] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            guard let box = boxHeader(bytes, at: offset, limit: UInt64(range.upperBound - offset)) else { break }
            let end = offset + Int(box.size)
            if containers.contains(box.type) {
                changed += retag(&bytes, in: offset + box.headerSize ..< end)
            } else if box.type == "stsd" {
                // A full box (version and flags), then the entry count, then the entries.
                var entry = offset + box.headerSize + 8
                while entry + 8 <= end, let sample = boxHeader(bytes, at: entry, limit: UInt64(end - entry)) {
                    if let tag = appleTags[sample.type] {
                        bytes.replaceSubrange(entry + 4 ..< entry + 8, with: Array(tag.utf8))
                        changed.append(entry + 4)
                    }
                    entry += Int(sample.size)
                }
            }
            offset = end
        }
        return changed
    }

    private struct BoxHeader {
        var type: String
        var size: UInt64
        var headerSize: Int
    }

    /// A box's type and size at `offset`; nil when it does not fit in what is left.
    private static func boxHeader(_ bytes: [UInt8], at offset: Int, limit: UInt64) -> BoxHeader? {
        guard bytes.count >= offset + 8 else { return nil }
        var size = UInt64(bigEndian: bytes, at: offset, width: 4)
        let type = String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self)
        var headerSize = 8
        if size == 1 {
            guard bytes.count >= offset + 16 else { return nil }
            size = UInt64(bigEndian: bytes, at: offset + 8, width: 8)
            headerSize = 16
        } else if size == 0 {
            size = limit
        }
        guard size >= UInt64(headerSize), size <= limit else { return nil }
        return BoxHeader(type: type, size: size, headerSize: headerSize)
    }
}

private extension UInt64 {
    init(bigEndian bytes: [UInt8], at offset: Int, width: Int) {
        self = bytes[offset ..< offset + width].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
