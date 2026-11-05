import Foundation

/// Home videos go by their file's name, and a recorder's name for a file says nothing to a
/// person: "Escape From Tarkov 2025.10.19 - 20.44.49.11.DVR", or a phone's hex. A clip
/// someone named keeps that name. The files and the server are left alone, so a new clip is
/// worded this way the moment it appears.
enum Clips {
    /// When a clip was made, down to the minute.
    struct Moment: Equatable {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int

        private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

        var date: String { "\(Self.months[month - 1]) \(day), \(year)" }

        var time: String {
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            return "\(twelve):\(minute < 10 ? "0" : "")\(minute) \(hour < 12 ? "AM" : "PM")"
        }

        var text: String { "\(date) · \(time)" }
    }

    /// The game and time a recorder wrote into a name. The time is the recording machine's
    /// own, so it is shown as written, in no time zone. NVIDIA, SteelSeries, OBS and Steam
    /// each write it differently; "Base Profile" and "Desktop" are NVIDIA not knowing the game.
    static func stamp(in name: String) -> (game: String?, moment: Moment)? {
        let pattern = #"\d{4}[-.]\d{2}[-.]\d{2}[ _-]+\d{2}[-._]\d{2}[-._]\d{2}"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        let numbers = name[range].split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count == 6, (1 ... 12).contains(numbers[1]), numbers[3] < 24 else { return nil }
        var hour = numbers[3]
        let after = name[range.upperBound...].lowercased()
        if after.hasPrefix("_pm") || after.hasPrefix(" pm"), hour < 12 { hour += 12 }
        if after.hasPrefix("_am") || after.hasPrefix(" am"), hour == 12 { hour = 0 }
        let words = name[..<range.lowerBound]
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        let game = ["", "Base Profile", "Desktop"].contains(words) ? nil : words
        return (game, Moment(year: numbers[0], month: numbers[1], day: numbers[2], hour: hour, minute: numbers[4]))
    }

    /// A name no person chose: a phone's or a website's id for the file.
    static func isAnonymous(_ name: String) -> Bool {
        let patterns = [
            #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#,
            #"^[0-9A-Fa-f]{16,}(\(\d+\))?$"#,
            #"^(IMG|VID|MOV)_\d+"#,
            #"^RPReplay_"#,
            #"^ScreenRec"#,
            #"^recorded-\d+"#,
            #"^tinywow_"#,
            #"^Untitled( video)?(_\d+)?$"#,
        ]
        if patterns.contains(where: { name.range(of: $0, options: .regularExpression) != nil }) { return true }
        // A file host's seven characters: "KiUHZBx". "zoomies" and "Beamer1" are words.
        return name.range(of: #"^[A-Za-z0-9]{7}$"#, options: .regularExpression) != nil
            && name.range(of: #"^([A-Z]?[a-z]+|[A-Z]+)[0-9]*$"#, options: .regularExpression) == nil
    }

    /// What is left of a name once an editor's mark is off it.
    private static func cleaned(_ name: String) -> String {
        name.replacingOccurrences(of: " - Made with Clipchamp", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// When a clip was made, as near as the server knows. Its premiere date is January 1st
    /// of any year it finds in a name, so that one only counts with a time on it.
    static func date(of item: BaseItem) -> Date? {
        if let premiere = item.premiereDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
            let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: premiere)
            if !(parts.month == 1 && parts.day == 1 && parts.hour == 0 && parts.minute == 0) { return premiere }
        }
        return item.dateCreated
    }

    /// When to sort a clip by: a recorder's stamp, which no copy of the file can change,
    /// before anything the server has.
    static func made(_ item: BaseItem) -> Date {
        if let name = item.name, let moment = stamp(in: name)?.moment {
            let parts = DateComponents(year: moment.year, month: moment.month, day: moment.day, hour: moment.hour, minute: moment.minute)
            if let date = Calendar(identifier: .gregorian).date(from: parts) { return date }
        }
        return date(of: item) ?? .distantPast
    }

    static func newestFirst(_ items: [BaseItem]) -> [BaseItem] {
        items.map { ($0, made($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func moment(of item: BaseItem) -> Moment? {
        guard let date = date(of: item) else { return nil }
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let hour = parts.hour, let minute = parts.minute else { return nil }
        return Moment(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    static func title(_ item: BaseItem) -> String {
        guard let name = item.name else { return "Untitled" }
        if let stamp = stamp(in: name) { return stamp.moment.text }
        if isAnonymous(cleaned(name)) || isAnonymous(name) { return moment(of: item)?.text ?? "Untitled Clip" }
        return cleaned(name)
    }

    /// The card's second line: what the title leaves out, and how long it runs.
    static func subtitle(_ item: BaseItem) -> String? {
        let length = item.runtime.map(Ticks.clock)
        guard let name = item.name else { return length }
        let context: String?
        if let stamp = stamp(in: name) {
            context = stamp.game
        } else if isAnonymous(cleaned(name)) || isAnonymous(name) {
            context = nil
        } else {
            context = moment(of: item)?.date
        }
        let parts = [context, length].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

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
