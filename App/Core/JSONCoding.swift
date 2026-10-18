import Foundation

/// Jellyfin's JSON conventions, in one place: PascalCase keys and .NET dates.
enum JSONCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            AnyKey(lowercasingFirst(path.last!.stringValue))
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(string)"))
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { path in
            AnyKey(uppercasingFirst(path.last!.stringValue))
        }
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }

    /// The server writes seven fractional digits ("2026-10-18T19:12:34.1234567Z"), which
    /// Foundation's ISO 8601 parser rejects; the fraction is cut to milliseconds first.
    static func parseDate(_ string: String) -> Date? {
        var text = string
        if !text.hasSuffix("Z"), !text.contains("+"), text.count > 10, !text.dropFirst(10).contains("-") {
            text += "Z"
        }
        if let dot = text.firstIndex(of: ".") {
            let fraction = text[text.index(after: dot)...].prefix { $0.isNumber }
            let rest = text[text.index(after: dot)...].dropFirst(fraction.count)
            let millis = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text = String(text[..<dot]) + "." + millis + rest
            return fractional.date(from: text)
        }
        return whole.date(from: text)
    }

    static func formatDate(_ date: Date) -> String {
        fractional.string(from: date)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func lowercasingFirst(_ key: String) -> String {
        guard let first = key.first else { return key }
        // "LUFS" style all-caps keys would become "lUFS"; the app reads none of them.
        return first.lowercased() + key.dropFirst()
    }

    static func uppercasingFirst(_ key: String) -> String {
        guard let first = key.first else { return key }
        return first.uppercased() + key.dropFirst()
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Jellyfin's time unit: 100 ns, so ten million to the second.
enum Ticks {
    static let perSecond: Double = 10_000_000

    static func seconds(_ ticks: Int64) -> Double {
        Double(ticks) / perSecond
    }

    static func from(seconds: Double) -> Int64 {
        Int64((seconds * perSecond).rounded())
    }

    /// "1:42:05" or "42:05".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "1h 42m" or "42m": a runtime on a detail page.
    static func runtime(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(max(1, minutes))m"
    }
}
