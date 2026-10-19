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
