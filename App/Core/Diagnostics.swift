import Foundation

/// A short log of what happened, for the Diagnostics screen and for sending to the server
/// when something goes wrong on the phone, where there is no debugger.
///
/// Tokens never reach it: anything that looks like an `ApiKey=` or `Token="…"` is cut out
/// before it is kept.
actor Diagnostics {
    static let shared = Diagnostics()

    struct Entry: Sendable, Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let limit = 400

    func record(_ category: String, _ message: String) {
        let entry = Entry(date: Date(), category: category, message: Self.scrub(message))
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        #if DEBUG || os(Linux)
        print("[\(category)] \(entry.message)")
        #endif
    }

    func text() -> String {
        let formatter = ISO8601DateFormatter()
        return entries.map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)" }.joined(separator: "\n")
    }

    static func scrub(_ text: String) -> String {
        var result = text
        for pattern in [#"(?i)(api_?key=)[^&\s"]+"#, #"(Token=\")[^\"]*"#] {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: "$1…")
            }
        }
        return result
    }
}
