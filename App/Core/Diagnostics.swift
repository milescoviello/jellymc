import Foundation

/// A short log of what happened, for the Diagnostics screen and for sending to the server,
/// where there is no debugger.
///
/// Tokens never reach it: anything that looks like an `ApiKey=` or `Token="…"` is cut out
/// before it is kept.
///
/// The screen reads the last few hundred entries from memory. Once `persist(in:)` is
/// called (the iPhone app does, at launch), every entry is also appended to a file until
/// it has been sent, so what happened before a crash or a force quit still reaches the
/// server on the next start.
actor Diagnostics {
    static let shared = Diagnostics()

    struct Entry: Sendable, Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let message: String
    }

    /// What has not been sent yet, and how many bytes of the file it is.
    struct Unsent: Sendable, Equatable {
        var text: String
        var bytes: Int
    }

    private(set) var entries: [Entry] = []
    private let limit = 400
    private var pendingFile: URL?
    /// Past this the oldest half is dropped: a phone offline for weeks keeps the recent past.
    private let pendingLimit = 1_000_000
    private let formatter = ISO8601DateFormatter()

    init() {}

    /// Keeps unsent entries in `directory`/diagnostics-unsent.log from now on.
    func persist(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pendingFile = directory.appendingPathComponent("diagnostics-unsent.log")
    }

    func record(_ category: String, _ message: String) {
        let entry = Entry(date: Date(), category: category, message: Self.scrub(message))
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        append(line(entry) + "\n")
        #if DEBUG || os(Linux)
        // stderr, not print: stdout is block-buffered when it is a file, and a crash takes
        // the buffer with it.
        FileHandle.standardError.write(Data("[\(category)] \(entry.message)\n".utf8))
        #endif
    }

    func text() -> String {
        entries.map { line($0) }.joined(separator: "\n")
    }

    /// Everything recorded and not yet sent, oldest first; nil when there is nothing.
    func unsent() -> Unsent? {
        guard let pendingFile, let data = try? Data(contentsOf: pendingFile), !data.isEmpty else { return nil }
        return Unsent(text: String(decoding: data, as: UTF8.self), bytes: data.count)
    }

    /// The first `bytes` of the unsent file reached the server. Entries recorded while it
    /// was being sent stay for the next time.
    func markSent(_ bytes: Int) {
        guard let pendingFile, let data = try? Data(contentsOf: pendingFile) else { return }
        let rest = data.count > bytes ? data.subdata(in: bytes ..< data.count) : Data()
        try? rest.write(to: pendingFile, options: .atomic)
    }

    private func line(_ entry: Entry) -> String {
        "\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.message)"
    }

    private func append(_ text: String) {
        guard let pendingFile else { return }
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: pendingFile) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: pendingFile, options: .atomic)
        }
        trimIfLarge()
    }

    private func trimIfLarge() {
        guard let pendingFile,
              let size = ((try? FileManager.default.attributesOfItem(atPath: pendingFile.path))?[.size] as? NSNumber)?.intValue,
              size > pendingLimit,
              let data = try? Data(contentsOf: pendingFile)
        else { return }
        // Cut at a line, so the file still starts with a whole entry.
        var start = data.count - pendingLimit / 2
        while start < data.count, data[start] != UInt8(ascii: "\n") { start += 1 }
        let kept = start < data.count ? data.subdata(in: (start + 1) ..< data.count) : Data()
        try? (Data("… older entries dropped: the log was not sent for too long\n".utf8) + kept).write(to: pendingFile, options: .atomic)
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

/// Sends the unsent log to the Jellyfin server (`POST /ClientLog/Document`) on its own:
/// after a video, when one fails, when the app goes to the background, and at launch for
/// whatever an earlier run could not send. The Music app's Send Logs, without the button.
///
/// The server keeps each upload as `upload_jellymc_*.log` in its own log folder.
actor LogUploader {
    static let shared = LogUploader()

    private var sending = false

    /// Sends what is pending, with `header` on top. Nothing pending, nothing sent; a
    /// failed send keeps the entries for the next try. Returns whether anything went.
    @discardableResult
    func send(reason: String, header: String, client: JellyfinClient, diagnostics: Diagnostics = .shared) async -> Bool {
        guard !sending else { return false }
        sending = true
        defer { sending = false }
        guard let unsent = await diagnostics.unsent() else { return false }
        let document = Self.document(reason: reason, header: header, body: unsent.text)
        do {
            try await client.sendLog(document)
            await diagnostics.markSent(unsent.bytes)
            return true
        } catch {
            return false
        }
    }

    static func document(reason: String, header: String, body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true).count
        return "Sent automatically: \(reason)\n\(header)\n\(lines) entr\(lines == 1 ? "y" : "ies") since the last log\n\n\(body)"
    }
}
