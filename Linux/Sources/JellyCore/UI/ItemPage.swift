import CGtk
import Foundation

/// A film, a series and its seasons, an episode, a collection, a person: artwork, what it is,
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
        let generation = shell.state.playbackGeneration
        root.observe { [weak self] in
            guard let self, self.shell.state.playbackGeneration != generation, let client = self.shell.state.client else { return }
            Task { await self.model.load(client) }
        }
    }

    // MARK: - Rendering

    private func render() {
        guard let item = model.item, let client = shell.state.client else { return }
        backdrop.load(Artwork.backdrop(item, client, width: 1920) ?? Artwork.primary(item, client, width: 1280))
        if let url = Artwork.logo(item, client, width: 420) {
            logo.load(url)
            logo.visible(true)
            titleLabel.visible(false)
        } else {
            logo.visible(false)
            titleLabel.visible(true)
        }
        titleLabel.text = item.type == .episode ? "\(item.seriesName ?? "") — \(item.title)" : item.title
        meta.text = Presentation.metaLine(item)
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

    private func renderActions(_ item: BaseItem) {
        actions.removeAll()
        if let playable = model.playable {
            let resume = playable.resumeSeconds
            let label = Presentation.playLabel(for: playable, on: item)
            actions.append(Button(label, icon: "media-playback-start-symbolic", "suggested-action", "pill") { [weak self] in
                self?.play(playable)
            })
            if resume > 0 {
                actions.append(Button("From the Start", icon: "media-skip-backward-symbolic", "pill") { [weak self] in
                    self?.play(playable, from: 0)
                })
            }
        }
        if item.type != .person {
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
        if item.type?.isVideo == true, item.mediaSources != nil {
            actions.append(downloadButton(for: item))
        }
        if item.type == .series || item.type == .season, !model.episodes.isEmpty {
            let episodes = model.episodes
            let downloads = shell.state.downloads
            actions.append(Button("Download Season", icon: "folder-download-symbolic", "pill", "flat") {
                Task { await downloads.download(episodes, for: .mpv) }
                Desktop.main?.toast("Downloading \(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
            })
        }
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

    /// Download, its progress, or Remove: one button that says where the file is.
    private func downloadButton(for item: BaseItem) -> Widget {
        let downloads = shell.state.downloads
        switch downloads.record(for: item.id)?.state {
        case .done?:
            let button = Button("Downloaded", icon: "emblem-ok-symbolic", "pill", "flat") {
                Dialogs.alert("Remove the download?", body: item.title, responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("remove", "Remove", ADW_RESPONSE_DESTRUCTIVE)]) { response in
                    if response == "remove" { downloads.remove(item.id) }
                }
            }
            return button.tooltip("Saved on this computer. Click to remove.")
        case .queued?, .downloading?:
            let percent = Int((downloads.record(for: item.id)?.progress ?? 0) * 100)
            return Button("\(percent)%", icon: "process-stop-symbolic", "pill", "flat") { downloads.remove(item.id) }
                .tooltip("Downloading. Click to cancel.")
        case .failed?:
            return Button("Retry Download", icon: "view-refresh-symbolic", "pill", "flat") { downloads.retry(item.id) }
        case nil:
            return Button("Download", icon: "folder-download-symbolic", "pill", "flat") { [weak self] in self?.download(item) }
        }
    }

    private func download(_ item: BaseItem) {
        let downloads = shell.state.downloads
        Task { await downloads.download(item, for: .mpv) }
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
        let row = CardRow(title: item.type == .person ? "Filmography" : "In This Collection", style: .poster) { [weak self] child in
            self?.shell.open(child)
        }
        row.show(list, client: client)
        children.append(row.root.margins(start: -24, end: -24))
    }

    private func renderInfo(_ item: BaseItem) {
        info.removeAll()
        guard let source = item.mediaSources?.first(where: { $0.id == versionChoice }) ?? item.mediaSources?.first else { return }
        let group = PreferencesGroup("Media")
        for row in Presentation.mediaRows(source) {
            group.add(ActionRow(row.title, subtitle: row.value))
        }
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
            row.show(people.map(BaseItem.init(person:)), client: client)
            extra.append(row.root)
        }
        if !model.similar.isEmpty {
            let row = CardRow(title: "More Like This", style: .poster) { [weak self] other in self?.shell.open(other) }
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
