import Foundation

/// What a detail page says about an item, worded once for both apps.
enum Presentation {
    /// "2010 · PG-13 · ★ 7.4 · 1h 45m · ends at 22:15" — or a series' run and seasons.
    static func metaLine(_ item: BaseItem, now: Date = Date()) -> String {
        var parts: [String] = []
        if let label = item.episodeLabel { parts.append(label) }
        if let year = item.productionYear {
            if item.type == .series, item.status == "Continuing" {
                parts.append("\(year)–")
            } else {
                parts.append(String(year))
            }
        }
        if let rating = item.officialRating { parts.append(rating) }
        if let score = item.communityRating { parts.append(String(format: "★ %.1f", score)) }
        if let runtime = item.runtime, item.type != .series {
            parts.append(Ticks.runtime(runtime))
            if item.type?.isVideo == true {
                parts.append("ends at \(clock(now.addingTimeInterval(runtime - item.resumeSeconds)))")
            }
        }
        if item.type == .series, let count = item.childCount {
            parts.append("\(count) season\(count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// The play button's words: "Resume 42:10", "Play S1:E3", "Play".
    static func playLabel(for playable: BaseItem, on page: BaseItem) -> String {
        let resume = playable.resumeSeconds
        if page.type == .series || page.type == .season, let episode = playable.episodeLabel {
            return resume > 0 ? "Resume \(episode)" : "Play \(episode)"
        }
        return resume > 0 ? "Resume \(Ticks.clock(resume))" : "Play"
    }

    /// The media panel's rows: what is in the file.
    static func mediaRows(_ source: MediaSource) -> [(title: String, value: String)] {
        var rows: [(String, String)] = []
        if let video = source.videoStream {
            var parts = [video.codec?.uppercased()]
            if let width = video.width, let height = video.height { parts.append("\(width)×\(height)") }
            if let range = video.videoRangeType, range != "SDR", range != "Unknown" { parts.append(range) }
            parts.append(video.bitDepth.map { "\($0)-bit" })
            rows.append(("Video", parts.compactMap { $0 }.joined(separator: " · ")))
        }
        for audio in source.audioStreams {
            rows.append(("Audio", audio.label))
        }
        for subtitle in source.subtitleStreams {
            rows.append(("Subtitles", subtitle.label + (subtitle.isExternal == true ? " (external)" : "")))
        }
        var file = [source.container?.uppercased()]
        if let size = source.size { file.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let bitrate = source.bitrate { file.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)) }
        rows.append(("File", file.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")))
        return rows
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

extension BaseItem {
    /// A cast or crew member as a card: the role is the card's second line.
    init(person: Person) {
        self.init(id: person.id)
        name = person.name
        type = .person
        imageTags = person.primaryImageTag.map { ["Primary": $0] }
        role = person.role ?? person.type
    }
}
