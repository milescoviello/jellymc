import Foundation

/// What a detail page says about an item, worded once for both apps.
enum Presentation {
    /// Plex's line under the title: "2010 · 1h 45m · PG-13", and when it would end; a
    /// series' run and its seasons. The ratings have a line of their own.
    static func metaLine(_ item: BaseItem, now: Date = Date(), episodeLabel: Bool = true) -> String {
        var parts: [String] = []
        if episodeLabel, let label = item.episodeLabel { parts.append(label) }
        if let year = item.productionYear {
            if item.type == .series, item.status == "Continuing" {
                parts.append("\(year)–")
            } else {
                parts.append(String(year))
            }
        }
        if let runtime = item.runtime, item.type != .series { parts.append(Ticks.runtime(runtime)) }
        if item.type == .series, let count = item.childCount {
            parts.append("\(count) Season\(count == 1 ? "" : "s")")
        }
        if let rating = item.officialRating { parts.append(rating) }
        if let runtime = item.runtime, item.type?.isVideo == true {
            parts.append("Ends at \(clock(now.addingTimeInterval(runtime - item.resumeSeconds)))")
        }
        return parts.joined(separator: " · ")
    }

    /// A card's two lines, as Plex words them. An episode on a poster is its show, with
    /// where it falls ("S2 · E4"); on a still, the show and then the episode. A season is its
    /// show and which season.
    /// `onParent`: the card is on its show's page, where the show's name says nothing.
    static func cardLines(_ item: BaseItem, style: CardStyle, onParent: Bool = false) -> (title: String, subtitle: String) {
        switch item.type {
        case .episode?:
            let place = [item.parentIndexNumber.map { "S\($0)" }, item.indexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: " · ")
            if style == .poster {
                return (item.seriesName ?? item.title, place.isEmpty ? item.title : place)
            }
            return (item.seriesName ?? item.title, [place.isEmpty ? nil : place, item.name].compactMap { $0 }.joined(separator: " · "))
        case .season?:
            let count = (item.childCount ?? item.recursiveItemCount).map { "\($0) episode\($0 == 1 ? "" : "s")" }
            if onParent { return (item.title, count ?? "") }
            return (item.seriesName ?? item.title, [item.title, count].compactMap { $0 }.joined(separator: " · "))
        default:
            return (item.title, item.subtitle ?? "")
        }
    }

    /// A summary as text: servers keep some as HTML from where they came, with <br> for a
    /// break and &amp; for &.
    static func plainText(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [(#"(?i)<br\s*/?>"#, "\n"), (#"(?i)</p>\s*<p[^>]*>"#, "\n\n"), (#"<[^>]+>"#, "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, character) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // At most one blank line between paragraphs, and none at the ends: Windows line
        // ends and spaces around the breaks count as nothing.
        text = text.replacingOccurrences(of: "\r", with: "")
        text = text.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The audience's score and the critics': "★ 7.4", "🍅 85%".
    static func ratings(_ item: BaseItem) -> [String] {
        var ratings: [String] = []
        if let score = item.communityRating, score > 0 { ratings.append(String(format: "★ %.1f", score)) }
        if let critics = item.criticRating, critics > 0 { ratings.append("\(critics >= 60 ? "🍅" : "🤢") \(Int(critics))%") }
        return ratings
    }

    /// Plex's credit lines under the summary: who directed, who wrote, which studio.
    static func credits(_ item: BaseItem) -> [(title: String, names: String)] {
        let people = item.people ?? []
        func names(_ type: String) -> String {
            people.filter { $0.type == type }.compactMap(\.name).prefix(4).joined(separator: ", ")
        }
        var lines: [(String, String)] = []
        let directors = names("Director")
        if !directors.isEmpty { lines.append(("Directed by", directors)) }
        let writers = names("Writer")
        if !writers.isEmpty { lines.append(("Written by", writers)) }
        let studios = (item.studios ?? []).compactMap(\.name).prefix(3).joined(separator: ", ")
        if !studios.isEmpty { lines.append(("Studio", studios)) }
        return lines
    }

    /// Cast first, in billing order, then the crew: Plex's Cast & Crew row.
    static func castAndCrew(_ item: BaseItem) -> [Person] {
        let people = item.people ?? []
        let cast = people.filter { $0.type == "Actor" || $0.type == "GuestStar" }
        let crew = people.filter { $0.type != "Actor" && $0.type != "GuestStar" }
        return Array((cast + crew).prefix(40))
    }

    /// What a card's corner says about how much is left to watch: nothing once watched, a
    /// count of unwatched episodes on a show, Plex's unwatched mark on a film or episode.
    enum Unwatched: Equatable {
        case none
        case mark
        case count(Int)
    }

    static func unwatched(_ item: BaseItem) -> Unwatched {
        if item.isPlayed { return .none }
        switch item.type {
        case .series?, .season?, .boxSet?:
            guard let count = item.userData?.unplayedItemCount, count > 0 else { return .none }
            return .count(count)
        case .movie?, .episode?, .video?:
            return (item.userData?.playbackPositionTicks ?? 0) > 0 ? .none : .mark
        default:
            return .none
        }
    }

    /// The play button's words: "Resume 42:10", "Play S1:E3", "Play".
    static func playLabel(for playable: BaseItem, on page: BaseItem) -> String {
        let resume = playable.resumeSeconds
        if page.type == .series || page.type == .season, let episode = playable.episodeLabel {
            return resume > 0 ? "Resume \(episode)" : "Play \(episode)"
        }
        if page.type == .boxSet {
            return resume > 0 ? "Resume \(playable.title)" : "Play \(playable.title)"
        }
        if page.type == .playlist { return "Play" }
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
