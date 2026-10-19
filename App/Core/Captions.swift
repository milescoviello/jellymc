import Foundation

/// Text subtitles the app draws itself: what AVPlayer cannot load from a sidecar file,
/// so the iPhone shows a direct-played film's SRT the way mpv shows it on the desktop.
///
/// The server converts any text format on request (`Stream.vtt`), so only WebVTT is
/// parsed — and SRT, which differs only in its header and its decimal comma.
struct Captions: Sendable, Equatable {
    struct Cue: Sendable, Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    let cues: [Cue]

    init(cues: [Cue]) {
        self.cues = cues.sorted { $0.start < $1.start }
    }

    init(parsing source: String) {
        var cues: [Cue] = []
        let blocks = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = Self.seconds(parts[0]),
                  let end = Self.seconds(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            else { continue }
            let text = lines[(timing + 1)...]
                .map(Self.stripTags)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !text.isEmpty { cues.append(Cue(start: start, end: end, text: text)) }
        }
        self.init(cues: cues)
    }

    /// The text on screen at `time`; overlapping cues stack, earliest first.
    func text(at time: Double) -> String? {
        let showing = cues.filter { $0.start <= time && time < $0.end }
        guard !showing.isEmpty else { return nil }
        return showing.map(\.text).joined(separator: "\n")
    }

    /// "01:02:03.456", "02:03.456" or SRT's "01:02:03,456".
    static func seconds(_ text: String) -> Double? {
        let clean = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = clean.split(separator: ":").map(String.init)
        guard (2 ... 3).contains(fields.count), let last = Double(fields[fields.count - 1]) else { return nil }
        var total = last
        var multiplier = 60.0
        for field in fields.dropLast().reversed() {
            guard let value = Double(field) else { return nil }
            total += value * multiplier
            multiplier *= 60
        }
        return total
    }

    /// `<i>`, `<c.yellow>`, `{\an8}`: styling the overlay does not draw.
    static func stripTags(_ line: String) -> String {
        var result = ""
        var depth = 0
        var inBrace = false
        for character in line {
            switch character {
            case "<": depth += 1
            case ">": depth = max(0, depth - 1)
            case "{" where !inBrace: inBrace = true
            case "}" where inBrace: inBrace = false
            default:
                if depth == 0 && !inBrace { result.append(character) }
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

extension ExternalSubtitle {
    /// The same stream as WebVTT, whatever it is on disk: the server converts it.
    var webVTTURL: URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var path = components.path
        if let dot = path.range(of: ".", options: .backwards), path[dot.upperBound...].contains("/") == false {
            path = String(path[..<dot.lowerBound]) + ".vtt"
        }
        components.path = path
        return components.url ?? url
    }
}
