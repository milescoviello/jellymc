import CGtk
import Foundation

/// A film, a series and its seasons, an episode, an album, a person: artwork, what it is,
/// how to play it, and what goes with it.
@MainActor
final class ItemPage {
    private(set) var root: Widget = Bin()
    private unowned let shell: Shell
    private let model: ItemModel
    private let backdrop = Picture()
    private let logo = Picture().fit(GTK_CONTENT_FIT_CONTAIN)
    private let titleLabel = Label("", "title-1").wrap()
    private let meta = Label("", "dim-label").wrap()
    private let genres = Label("", "dim-label", "caption").wrap()
    private let tagline = Label("", "heading").wrap()
    private let overview = Label("").wrap().selectable().maxWidthChars(110)
    private let actions = Box.horizontal(spacing: 10)
    private let tracks = Box.horizontal(spacing: 10)
    private let seasonBar = Box.horizontal(spacing: 0).css("linked")
    private let episodes = ListBox()
    private let children = Box.vertical(spacing: 0)
    private let info = Box.vertical(spacing: 12)
    private let extra = Box.vertical(spacing: 30)
    private var audioChoice: Int?
    private var subtitleChoice: Int??
    private var versionChoice: String?
    private var shownSeasons: [String] = []
    private var shownEpisodes: [String] = []
    private var shownChildren: [String] = []
    private var shownExtras = ""

    init(shell: Shell, item: BaseItem) {
        self.shell = shell
        model = ItemModel(id: item.id, placeholder: item)

        backdrop.size(height: 420).hexpand()
        logo.size(width: 380, height: 120).halign(GTK_ALIGN_START)
        let shade = Box.vertical().css("hero-shade").hexpand().vexpand().canTarget(false)
        let heading = Box.vertical(spacing: 10) {
            logo
            titleLabel
            meta
            genres
            actions.margins(top: 8)
            tracks
        }.valign(GTK_ALIGN_END).margins(bottom: 24, start: 36, end: 36)
        let hero = Overlay(backdrop).add(shade).add(heading)
        hero.size(height: 420)

        let body = Box.vertical(spacing: 24) {
            hero
            Box.vertical(spacing: 8) {
                tagline
                overview
            }.margins(start: 36, end: 36)
            Box.vertical(spacing: 12) {
                seasonBar.halign(GTK_ALIGN_START)
                episodes
            }.margins(start: 36, end: 36)
            children.margins(start: 36, end: 36)
            info.margins(start: 36, end: 36)
            extra.margins(bottom: 36)
        }
        let header = HeaderBar().showsTitle(false)
        let toolbar = ToolbarView(content: ScrolledWindow(body).vexpand()).top(header).extendsContentToTop()
        toolbar.topStyle(ADW_TOOLBAR_FLAT)
        root = toolbar
        root.keep(self)

        root.observe { [weak self] in self?.render() }
        if let client = shell.state.client {
            Task { await model.load(client) }
        }
    }

    // MARK: - Rendering

    private func render() {
        guard let item = model.item, let client = shell.state.client else { return }
        backdrop.load(Artwork.backdrop(item, client, width: 1920) ?? Artwork.primary(item, client, width: 1280))
        if let url = Artwork.logo(item, client, width: 800) {
            logo.load(url)
            logo.visible(true)
            titleLabel.visible(false)
        } else {
            logo.visible(false)
            titleLabel.visible(true)
        }
        titleLabel.text = item.type == .episode ? "\(item.seriesName ?? "") — \(item.title)" : item.title
        meta.text = metaLine(item)
        genres.text = (item.genres ?? []).prefix(5).joined(separator: " · ")
        genres.visible(!(item.genres ?? []).isEmpty)
        tagline.text = item.taglines?.first ?? ""
        tagline.visible(item.taglines?.first != nil)
        overview.text = item.overview ?? ""
        overview.visible(item.overview != nil)

        renderActions(item)
        renderTracks(item)
        renderSeasons()
        renderEpisodes(client)
        renderChildren(item, client)
        renderInfo(item)
        renderExtras(item, client)
    }

    private func metaLine(_ item: BaseItem) -> String {
        var parts: [String] = []
        if let label = item.episodeLabel { parts.append(label) }
        if let year = item.productionYear {
            if item.type == .series, let status = item.status {
                parts.append(status == "Continuing" ? "\(year)–" : "\(year)")
            } else {
                parts.append(String(year))
            }
        }
        if let rating = item.officialRating { parts.append(rating) }
        if let score = item.communityRating { parts.append(String(format: "★ %.1f", score)) }
        if let runtime = item.runtime, item.type != .series {
            parts.append(Ticks.runtime(runtime))
            let remaining = runtime - item.resumeSeconds
            let ends = Date().addingTimeInterval(remaining)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            parts.append("ends at \(formatter.string(from: ends))")
        }
        if item.type == .series, let count = item.childCount { parts.append("\(count) season\(count == 1 ? "" : "s")") }
        if item.type == .musicAlbum, let artist = item.albumArtist { parts.insert(artist, at: 0) }
        return parts.joined(separator: "  ·  ")
    }

    private func renderActions(_ item: BaseItem) {
        actions.removeAll()
        if let playable = model.playable {
            let resume = playable.resumeSeconds
            let label: String
            if item.type == .series || item.type == .season, let episode = playable.episodeLabel {
                label = resume > 0 ? "Resume \(episode)" : "Play \(episode)"
            } else {
                label = resume > 0 ? "Resume \(Ticks.clock(resume))" : "Play"
            }
            actions.append(Button(label, icon: "media-playback-start-symbolic", "suggested-action", "pill") { [weak self] in
                self?.play(playable)
            })
            if resume > 0 {
                actions.append(Button("From the Start", icon: "media-skip-backward-symbolic", "pill") { [weak self] in
                    self?.play(playable, from: 0)
                })
            }
        } else if item.type == .musicAlbum || item.type == .playlist, let first = model.children.first {
            actions.append(Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill") { [weak self] in
                self?.shell.window.play(first)
            })
        }
        if item.type != .person, item.type != .musicArtist {
            let played = Button(icon: item.isPlayed ? "object-select-symbolic" : "object-select-symbolic", "circular", item.isPlayed ? "accent" : "flat") { [weak self] in
                Task { await self?.model.togglePlayed() }
            }
            played.tooltip(item.isPlayed ? "Mark Unplayed" : "Mark Played")
            if item.isPlayed { played.css("played-on") }
            actions.append(played)
        }
        let favourite = Button(icon: item.isFavorite ? "starred-symbolic" : "non-starred-symbolic", "circular", "flat") { [weak self] in
            Task { await self?.model.toggleFavorite() }
        }
        favourite.tooltip(item.isFavorite ? "Remove from Favourites" : "Add to Favourites")
        actions.append(favourite)
        if let trailer = item.remoteTrailers?.first?.url, let url = URL(string: trailer) {
            actions.append(Button("Trailer", icon: "video-x-generic-symbolic", "pill", "flat") {
                gtk_show_uri(Desktop.window?.cast(), url.absoluteString, guint32(GDK_CURRENT_TIME))
            })
        }
    }

    /// Audio, subtitle and version pickers, for what the play button starts.
    private func renderTracks(_ item: BaseItem) {
        tracks.removeAll()
        guard model.playable?.id == item.id, let sources = item.mediaSources, let source = sources.first(where: { $0.id == versionChoice }) ?? sources.first else {
            tracks.visible(false)
            return
        }
        tracks.visible(true)
        let initial = shell.state.preferences.initialTracks(for: source)
        let audio = audioChoice ?? initial.audio
        let subtitle = subtitleChoice ?? initial.subtitle

        if sources.count > 1 {
            tracks.append(MenuButton(icon: "media-optical-symbolic", label: source.name ?? "Version", "flat") {
                Menu([[.choice("Version", options: sources.map { ($0.id, $0.name ?? $0.id) }, selected: source.id) { [weak self] id in
                    self?.versionChoice = id
                    self?.audioChoice = nil
                    self?.subtitleChoice = nil
                    self?.render()
                }]])
            })
        }
        if source.audioStreams.count > 1 {
            let current = source.audioStreams.first { $0.index == audio }?.label ?? "Audio"
            tracks.append(MenuButton(icon: "audio-volume-high-symbolic", label: current, "flat") {
                Menu([[.choice("Audio", options: source.audioStreams.map { (String($0.index), $0.label) }, selected: audio.map(String.init)) { [weak self] id in
                    self?.audioChoice = Int(id)
                    self?.render()
                }]])
            })
        }
        if !source.subtitleStreams.isEmpty {
            let current = subtitle.flatMap { index in source.subtitleStreams.first { $0.index == index }?.label } ?? "Subtitles Off"
            tracks.append(MenuButton(icon: "media-view-subtitles-symbolic", label: current, "flat") {
                Menu([[.choice("Subtitles", options: [("off", "Off")] + source.subtitleStreams.map { (String($0.index), $0.label) }, selected: subtitle.map(String.init) ?? "off") { [weak self] id in
                    self?.subtitleChoice = .some(Int(id))
                    self?.render()
                }]])
            })
        }
    }

    private func renderSeasons() {
        let ids = model.seasons.map(\.id)
        guard ids != shownSeasons else {
            highlightSeason()
            return
        }
        shownSeasons = ids
        seasonBar.removeAll()
        seasonBar.visible(model.seasons.count > 0)
        var first: ToggleButton?
        for season in model.seasons {
            let button = ToggleButton(season.title) { [weak self] active in
                if active { self?.model.selectedSeasonId = season.id }
            }
            button.name("season-\(season.id)")
            if let first { button.group(with: first) } else { first = button }
            seasonBar.append(button)
        }
        highlightSeason()
    }

    private func highlightSeason() {
        var child = gtk_widget_get_first_child(seasonBar.widget)
        while let widget = child {
            let name = String(cString: gtk_widget_get_name(widget))
            let active = name == "season-\(model.selectedSeasonId ?? "")"
            if active, gtk_toggle_button_get_active(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkToggleButton.self)) == 0 {
                gtk_toggle_button_set_active(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkToggleButton.self), 1)
            }
            child = gtk_widget_get_next_sibling(widget)
        }
    }

    private func renderEpisodes(_ client: JellyfinClient) {
        let list = model.episodes
        let key = list.map { "\($0.id):\($0.isPlayed):\($0.userData?.playbackPositionTicks ?? 0)" }
        guard key != shownEpisodes else { return }
        shownEpisodes = key
        episodes.removeAll()
        episodes.visible(!list.isEmpty)
        for episode in list {
            let still = Picture()
            still.size(width: 220, height: 124).css("card-art")
            still.load(Artwork.primary(episode, client, width: 440))
            let progress = ProgressBar().css("card-progress")
            progress.fraction = episode.progress ?? 0
            progress.visible(episode.progress != nil)
            let number = episode.indexNumber.map { "\($0). " } ?? ""
            let titleRow = Box.horizontal(spacing: 8) {
                Label(number + episode.title, "heading").ellipsize()
                Spacer()
                Label(episode.runtime.map(Ticks.runtime) ?? "", "dim-label", "caption")
            }
            if episode.isPlayed {
                titleRow.append(Icon("object-select-symbolic").css("accent"))
            }
            let row = Box.horizontal(spacing: 18) {
                Overlay(still).add(progress.valign(GTK_ALIGN_END).margins(bottom: 6, start: 8, end: 8))
                Box.vertical(spacing: 6) {
                    titleRow
                    Label(episode.overview ?? "", "dim-label").wrap().lines(3).ellipsize()
                }.valign(GTK_ALIGN_CENTER).hexpand()
            }.margin(10)
            row.contextMenu { [weak self] in
                Menu([[
                    .action("Play") { self?.play(episode) },
                    .action("Play from the Start") { self?.play(episode, from: 0) },
                    .action(episode.isPlayed ? "Mark Unplayed" : "Mark Played") {
                        Task { await self?.model.setEpisodePlayed(episode, !episode.isPlayed) }
                    },
                    .action("Episode Details") { self?.shell.open(episode) },
                ]])
            }
            episodes.append(row) { [weak self] in self?.play(episode) }
        }
    }

    private func renderChildren(_ item: BaseItem, _ client: JellyfinClient) {
        let list = model.children
        let key = list.map(\.id)
        guard key != shownChildren else { return }
        shownChildren = key
        children.removeAll()
        guard !list.isEmpty else { return }
        if item.type == .musicAlbum || item.type == .playlist {
            let rows = ListBox()
            for track in list {
                let number = track.indexNumber.map(String.init) ?? ""
                rows.append(Box.horizontal(spacing: 14) {
                    Label(number, "dim-label", "numeric").size(width: 28)
                    Box.vertical(spacing: 2) {
                        Label(track.title).ellipsize()
                        Label(track.artists?.joined(separator: ", ") ?? "", "dim-label", "caption").ellipsize()
                    }.hexpand()
                    Label(track.runtime.map(Ticks.clock) ?? "", "dim-label", "numeric")
                }.margin(horizontal: 12, vertical: 8)) { [weak self] in self?.shell.window.play(track) }
            }
            children.append(rows)
        } else {
            let style: CardStyle = item.type == .musicArtist ? .square : .poster
            let row = CardRow(title: item.type == .person ? "Filmography" : "Items", style: style) { [weak self] child in
                self?.shell.open(child)
            }
            row.show(list, client: client)
            children.append(row.root.margins(start: -24, end: -24))
        }
    }

    private func renderInfo(_ item: BaseItem) {
        info.removeAll()
        guard let source = item.mediaSources?.first(where: { $0.id == versionChoice }) ?? item.mediaSources?.first else { return }
        let group = PreferencesGroup("Media")
        if let video = source.videoStream {
            var parts = [video.codec?.uppercased(), video.width.flatMap { width in video.height.map { "\(width)×\($0)" } }]
            parts.append(video.videoRangeType.flatMap { $0 == "SDR" ? nil : $0 })
            parts.append(video.bitDepth.map { "\($0)-bit" })
            group.add(ActionRow("Video", subtitle: parts.compactMap { $0 }.joined(separator: " · ")))
        }
        for audio in source.audioStreams {
            group.add(ActionRow("Audio", subtitle: audio.label))
        }
        for subtitle in source.subtitleStreams {
            group.add(ActionRow("Subtitles", subtitle: subtitle.label + (subtitle.isExternal == true ? " (external)" : "")))
        }
        var file: [String] = [source.container?.uppercased() ?? ""]
        if let size = source.size { file.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let bitrate = source.bitrate { file.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)) }
        group.add(ActionRow("File", subtitle: file.filter { !$0.isEmpty }.joined(separator: " · ")))
        info.append(group)
    }

    private func renderExtras(_ item: BaseItem, _ client: JellyfinClient) {
        let people = (item.people ?? []).prefix(30)
        let key = people.map(\.id).joined() + "|" + model.similar.map(\.id).joined()
        guard key != shownExtras else { return }
        shownExtras = key
        extra.removeAll()
        if !people.isEmpty {
            let row = CardRow(title: "Cast & Crew", style: .poster) { [weak self] person in self?.shell.open(person) }
            let asItems = people.map { person in
                BaseItem(id: person.id, name: person.name, type: .person, imageTags: person.primaryImageTag.map { ["Primary": $0] }, roleLabel: person.role ?? person.type)
            }
            row.show(asItems, client: client)
            extra.append(row.root)
        }
        if !model.similar.isEmpty {
            let row = CardRow(title: "More Like This", style: item.type == .musicAlbum ? .square : .poster) { [weak self] other in self?.shell.open(other) }
            row.show(model.similar, client: client)
            extra.append(row.root)
        }
    }

    // MARK: - Playing

    private func play(_ playable: BaseItem, from start: Double? = nil) {
        let isThis = playable.id == model.item?.id
        let subtitle: Int?? = isThis ? subtitleChoice : nil
        shell.window.play(
            playable, from: start,
            audioIndex: isThis ? audioChoice : nil,
            subtitleIndex: subtitle ?? nil,
            mediaSourceId: isThis ? versionChoice : nil
        )
    }
}

extension BaseItem {
    /// A person shown as a card: the role is the card's second line.
    init(id: String, name: String?, type: ItemKind, imageTags: [String: String]?, roleLabel: String?) {
        self.init(id: id)
        self.name = name
        self.type = type
        self.imageTags = imageTags
        self.role = roleLabel
    }
}
