import CGtk
import Foundation

/// Plex's pre-play screen: a film, a show and its seasons, a season and its episodes, an
/// episode, a collection, a person. Artwork and what it is, how to play it, and what goes
/// with it.
@MainActor
final class ItemPage {
    private(set) var root: Widget = Bin()
    private unowned let shell: Shell
    private let model: ItemModel
    private let backdrop = Picture()
    private let poster = FixedPicture(width: 220, height: 330)
    private let logo = Picture().fit(GTK_CONTENT_FIT_CONTAIN)
    private let parent = Button("", "flat", "heading")
    // A wrapping label asks for its whole text on one line unless told a width: a long
    // episode title ran off the window.
    private let titleLabel = Label("", "title-1").wrap().maxWidthChars(34)
    private let episodeLine = Label("", "title-4").wrap()
    private let meta = Label("", "dim-label").wrap()
    private let ratings = Box.horizontal(spacing: 14)
    private let genres = Label("", "dim-label").wrap()
    private let actions = Box.horizontal(spacing: 10)
    private let tracks = Box.horizontal(spacing: 10)
    private let tagline = Label("", "heading").wrap()
    private let overview = Label("").wrap().selectable().maxWidthChars(110)
    private let credits = Grid(rowSpacing: 4, columnSpacing: 18)
    private let seasons = Box.vertical(spacing: 0)
    private let episodes = ListBox()
    private let children = Box.vertical(spacing: 0)
    private let extra = Box.vertical(spacing: 30)
    private let info = Box.vertical(spacing: 12)
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

        backdrop.size(height: 520).hexpand()
        poster.css("detail-poster").valign(GTK_ALIGN_END)
        logo.size(width: 380, height: 110).halign(GTK_ALIGN_START)
        parent.halign(GTK_ALIGN_START)
        let shade = Box.vertical().css("hero-shade").hexpand().vexpand().canTarget(false)
        let heading = Box.vertical(spacing: 8) {
            parent
            logo
            titleLabel
            episodeLine
            meta
            ratings
            genres
            actions.margins(top: 10)
            tracks
        }.valign(GTK_ALIGN_END).hexpand()
        let hero = Overlay(backdrop).add(shade).add(Box.horizontal(spacing: 32) {
            poster
            heading
        }.valign(GTK_ALIGN_END).margins(bottom: 24, start: 36, end: 36))
        hero.size(height: 520)

        let body = Box.vertical(spacing: 26) {
            hero
            Box.vertical(spacing: 10) {
                tagline
                overview
                credits.margins(top: 6)
            }.margins(start: 36, end: 36)
            seasons
            episodes.margins(start: 36, end: 36)
            children
            extra
            info.margins(bottom: 36, start: 36, end: 36)
        }
        let header = HeaderBar().showsTitle(false)
        let toolbar = ToolbarView(content: ScrolledWindow(body).vexpand()).top(header).extendsContentToTop()
        toolbar.topStyle(ADW_TOOLBAR_FLAT)
        root = toolbar
        root.keep(self)

        parent.onClicked { [weak self] in self?.openParent() }
        root.observe { [weak self] in self?.render() }
        if let client = shell.state.client {
            Task { await model.load(client) }
        }
        // Back from the player, or changed elsewhere: progress and watched marks.
        let generation = shell.state.dataGeneration
        root.observe { [weak self] in
            guard let self, self.shell.state.dataGeneration != generation, let client = self.shell.state.client else { return }
            Task { await self.model.load(client) }
        }
    }

    // MARK: - Rendering

    private func render() {
        guard let item = model.item, let client = shell.state.client else { return }
        // A collection with no art of its own borrows its first film's, as Plex's does.
        let lead = model.children.first
        backdrop.load(Artwork.backdrop(item, client, width: 1920) ?? lead.flatMap { Artwork.backdrop($0, client, width: 1920) } ?? Artwork.primary(item, client, width: 1280))
        let isEpisode = item.type == .episode
        let posterURL = isEpisode ? Artwork.primary(item, client, width: 600) : Artwork.poster(item, client, width: 440)
        if isEpisode {
            poster.resize(width: 300, height: 169)
        } else {
            poster.resize(width: 220, height: 330)
        }
        poster.picture.load(posterURL)
        poster.visible(posterURL != nil)

        // An episode or season leads back to its show.
        if (isEpisode || item.type == .season), let show = item.seriesName {
            parent.label = show
            parent.visible(true)
        } else {
            parent.visible(false)
        }
        let logoURL = isEpisode || item.type == .season ? nil : Artwork.logo(item, client, width: 420)
        if let logoURL {
            logo.load(logoURL)
            logo.visible(true)
            titleLabel.visible(false)
        } else {
            logo.visible(false)
            titleLabel.visible(true)
        }
        titleLabel.text = isEpisode ? item.title : item.title
        episodeLine.text = isEpisode ? [item.seasonName, item.indexNumber.map { "Episode \($0)" }].compactMap { $0 }.joined(separator: " · ") : ""
        episodeLine.visible(isEpisode)
        meta.text = Presentation.metaLine(item, episodeLabel: !isEpisode)
        ratings.removeAll()
        for rating in Presentation.ratings(item) { ratings.append(Label(rating, "rating")) }
        ratings.visible(!Presentation.ratings(item).isEmpty)
        genres.text = (item.genres ?? []).prefix(5).joined(separator: ", ")
        genres.visible(!(item.genres ?? []).isEmpty)
        tagline.text = item.taglines?.first ?? ""
        tagline.visible(item.taglines?.first != nil)
        overview.text = item.overview.map(Presentation.plainText) ?? ""
        overview.visible(item.overview != nil)
        credits.removeAll()
        for (row, credit) in Presentation.credits(item).enumerated() {
            credits.attach(Label(credit.title, "credit-title").halign(GTK_ALIGN_START), column: 0, row: Int32(row))
            credits.attach(Label(credit.names).wrap().halign(GTK_ALIGN_START), column: 1, row: Int32(row))
        }

        renderActions(item)
        renderTracks(item)
        renderSeasons(client)
        renderEpisodes(client)
        renderChildren(item, client)
        renderExtras(item, client)
        renderInfo(item)
    }

    private func renderActions(_ item: BaseItem) {
        actions.removeAll()
        if let playable = model.playable {
            let resume = playable.resumeSeconds
            let label = Presentation.playLabel(for: playable, on: item)
            actions.append(Button(label, icon: "media-playback-start-symbolic", "suggested-action", "pill") { [weak self] in
                self?.play(playable, queue: self?.model.queueAfterPlayable ?? [])
            })
            if resume > 0 {
                actions.append(Button(icon: "media-skip-backward-symbolic", "circular") { [weak self] in
                    self?.play(playable, from: 0)
                }.tooltip("Play from Beginning"))
            }
        }
        if model.canShuffle {
            actions.append(Button(icon: "media-playlist-shuffle-symbolic", "circular") { [weak self] in
                guard let self else { return }
                let model = self.model
                let window = self.shell.window
                Task {
                    let order = await model.shuffled()
                    guard let first = order.first else { return }
                    window.play(first, from: 0, queue: Array(order.dropFirst()))
                }
            }.tooltip("Shuffle"))
        }
        if let trailer = item.remoteTrailers?.first?.url, let url = URL(string: trailer) {
            actions.append(Button(icon: "video-x-generic-symbolic", "circular") {
                gtk_show_uri(Desktop.window?.cast(), url.absoluteString, guint32(GDK_CURRENT_TIME))
            }.tooltip("Play Trailer"))
        } else if let local = model.extras.first(where: { $0.type == .trailer }) {
            actions.append(Button(icon: "video-x-generic-symbolic", "circular") { [weak self] in
                self?.shell.window.play(local)
            }.tooltip("Play Trailer"))
        }
        if item.type != .person, item.type != .boxSet {
            let played = Button(icon: "object-select-symbolic", "circular") { [weak self] in
                Task { await self?.model.togglePlayed() }
            }
            played.tooltip(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched")
            if item.isPlayed { played.css("played-on") }
            actions.append(played)
        }
        let favourite = Button(icon: item.isFavorite ? "starred-symbolic" : "non-starred-symbolic", "circular") { [weak self] in
            Task { await self?.model.toggleFavorite() }
        }
        favourite.tooltip(item.isFavorite ? "Remove from Favourites" : "Add to Favourites")
        if item.isFavorite { favourite.css("played-on") }
        actions.append(favourite)
        if item.type?.isVideo == true, item.mediaSources != nil {
            actions.append(downloadButton(for: item))
        }
        if item.type == .season, !model.episodes.isEmpty {
            let episodes = model.episodes
            let downloads = shell.state.downloads
            actions.append(Button(icon: "folder-download-symbolic", "circular") {
                Task { await downloads.download(episodes, for: .mpv) }
                Desktop.main?.toast("Downloading \(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
            }.tooltip("Download Season"))
        }
    }

    /// Version, audio and subtitle pickers, for what the play button starts.
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

        if let video = source.videoStream {
            let label = sources.count > 1 ? (source.name ?? video.label) : video.label
            tracks.append(MenuButton(icon: "video-display-symbolic", label: label, "flat") {
                Menu([[.choice("Version", options: sources.map { ($0.id, $0.name ?? $0.videoStream?.label ?? $0.id) }, selected: source.id) { [weak self] id in
                    self?.versionChoice = id
                    self?.audioChoice = nil
                    self?.subtitleChoice = nil
                    self?.render()
                }]])
            }.tooltip("Video"))
        }
        if !source.audioStreams.isEmpty {
            let current = source.audioStreams.first { $0.index == audio }?.label ?? "Audio"
            tracks.append(MenuButton(icon: "audio-volume-high-symbolic", label: current, "flat") {
                Menu([[.choice("Audio", options: source.audioStreams.map { (String($0.index), $0.label) }, selected: audio.map(String.init)) { [weak self] id in
                    self?.audioChoice = Int(id)
                    self?.render()
                }]])
            }.tooltip("Audio"))
        }
        let current = subtitle.flatMap { index in source.subtitleStreams.first { $0.index == index }?.label } ?? "None"
        tracks.append(MenuButton(icon: "media-view-subtitles-symbolic", label: current, "flat") {
            Menu([[.choice("Subtitles", options: [("off", "None")] + source.subtitleStreams.map { (String($0.index), $0.label) }, selected: subtitle.map(String.init) ?? "off") { [weak self] id in
                self?.subtitleChoice = .some(Int(id))
                self?.render()
            }]])
        }.tooltip("Subtitles"))
    }

    /// Download, its progress, or Remove: one button that says where the file is.
    private func downloadButton(for item: BaseItem) -> Widget {
        let downloads = shell.state.downloads
        switch downloads.record(for: item.id)?.state {
        case .done?:
            let button = Button(icon: "emblem-ok-symbolic", "circular", "played-on") {
                Dialogs.alert("Remove the download?", body: item.title, responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("remove", "Remove", ADW_RESPONSE_DESTRUCTIVE)]) { response in
                    if response == "remove" { downloads.remove(item.id) }
                }
            }
            return button.tooltip("Downloaded. Click to remove.")
        case .queued?, .downloading?:
            let percent = Int((downloads.record(for: item.id)?.progress ?? 0) * 100)
            return Button("\(percent)%", icon: "process-stop-symbolic", "pill") { downloads.remove(item.id) }
                .tooltip("Downloading. Click to cancel.")
        case .failed?:
            return Button(icon: "view-refresh-symbolic", "circular") { downloads.retry(item.id) }.tooltip("Retry Download")
        case nil:
            return Button(icon: "folder-download-symbolic", "circular") { [weak self] in self?.download(item) }.tooltip("Download")
        }
    }

    private func download(_ item: BaseItem) {
        let downloads = shell.state.downloads
        Task { await downloads.download(item, for: .mpv) }
    }

    /// A show's seasons, as Plex shows them: a row of posters.
    private func renderSeasons(_ client: JellyfinClient) {
        let list = model.seasons
        let key = list.map { "\($0.id):\($0.userData?.unplayedItemCount ?? -1)" }
        guard key != shownSeasons else { return }
        shownSeasons = key
        seasons.removeAll()
        guard !list.isEmpty else { return }
        let row = CardRow(
            title: "\(list.count) Season\(list.count == 1 ? "" : "s")", style: .poster, onParent: true,
            activate: { [weak self] season in self?.shell.open(season) },
            menu: { [weak self] season in self.flatMap { ItemMenu.make(season, shell: $0.shell) } }
        )
        row.show(list, client: client)
        seasons.append(row.root)
    }

    /// A season's episodes: still, number and title, length, summary, progress.
    private func renderEpisodes(_ client: JellyfinClient) {
        let list = model.episodes
        let key = list.map { "\($0.id):\($0.isPlayed):\($0.userData?.playbackPositionTicks ?? 0)" }
        guard key != shownEpisodes else { return }
        shownEpisodes = key
        episodes.removeAll()
        episodes.visible(!list.isEmpty)
        for episode in list {
            let still = Picture()
            still.size(width: 240, height: 135).css("card-art")
            still.load(Artwork.primary(episode, client, width: 480))
            let progress = ProgressBar().css("card-progress")
            progress.fraction = episode.progress ?? 0
            progress.visible(episode.progress != nil)
            let unwatched = Presentation.unwatched(episode) == .mark
            let corner = DrawingArea(width: 22, height: 22) { cairo, width, height in
                cairo.color(red: 0.898, green: 0.627, blue: 0.051)
                cairo.move(0, 0)
                cairo.line(width, 0)
                cairo.line(width, height)
                cairo.close()
                cairo.fill()
            }.halign(GTK_ALIGN_END).valign(GTK_ALIGN_START).visible(unwatched).canTarget(false)
            let art = Overlay(still)
                .add(progress.valign(GTK_ALIGN_END).margins(bottom: 6, start: 8, end: 8))
                .add(corner)
            art.clipped().css("card-art")
            let number = episode.indexNumber.map { "\($0). " } ?? ""
            let titleRow = Box.horizontal(spacing: 8) {
                Label(number + episode.title, "heading").ellipsize()
                Spacer()
                Label(episode.runtime.map(Ticks.runtime) ?? "", "dim-label", "caption")
            }
            let row = Box.horizontal(spacing: 18) {
                art
                Box.vertical(spacing: 6) {
                    titleRow
                    Label(episode.overview.map(Presentation.plainText) ?? "", "dim-label").wrap().lines(3).ellipsize()
                }.valign(GTK_ALIGN_CENTER).hexpand()
            }.margin(10)
            row.contextMenu { [weak self] in
                guard let self else { return nil }
                return Menu([[
                    .action(episode.resumeSeconds > 0 ? "Resume" : "Play") { self.play(episode) },
                    .action("Play from Beginning") { self.play(episode, from: 0) },
                    .action("More Info") { self.shell.open(episode) },
                ], [
                    .action(episode.isPlayed ? "Mark as Unwatched" : "Mark as Watched") {
                        Task { await self.model.setEpisodePlayed(episode, !episode.isPlayed) }
                    },
                ]])
            }
            // Plex: an episode in the list opens its page; play is there, or on the menu.
            episodes.append(row) { [weak self] in self?.shell.open(episode) }
        }
    }

    private func renderChildren(_ item: BaseItem, _ client: JellyfinClient) {
        let list = model.children
        let key = list.map(\.id)
        guard key != shownChildren else { return }
        shownChildren = key
        children.removeAll()
        guard !list.isEmpty else { return }
        let row = CardRow(
            title: item.type == .person ? "Filmography" : "\(list.count) Item\(list.count == 1 ? "" : "s")", style: .poster,
            activate: { [weak self] child in self?.shell.open(child) },
            menu: { [weak self] child in self.flatMap { ItemMenu.make(child, shell: $0.shell) } }
        )
        row.show(list, client: client)
        children.append(row.root)
    }

    private func renderExtras(_ item: BaseItem, _ client: JellyfinClient) {
        let people = Presentation.castAndCrew(item)
        let key = people.map(\.id).joined() + "|" + model.extras.map(\.id).joined() + "|" + model.similar.map(\.id).joined()
        guard key != shownExtras else { return }
        shownExtras = key
        extra.removeAll()
        if !people.isEmpty {
            extra.append(CastRow(people: people, client: client) { [weak self] person in self?.shell.open(person) }.root)
        }
        if !model.extras.isEmpty {
            let row = CardRow(title: "Extras", style: .landscape, activate: { [weak self] extra in self?.shell.window.play(extra) })
            row.show(model.extras, client: client)
            extra.append(row.root)
        }
        if !model.similar.isEmpty {
            let row = CardRow(
                title: "More Like This", style: .poster,
                activate: { [weak self] other in self?.shell.open(other) },
                menu: { [weak self] other in self.flatMap { ItemMenu.make(other, shell: $0.shell) } }
            )
            row.show(model.similar, client: client)
            extra.append(row.root)
        }
    }

    private func renderInfo(_ item: BaseItem) {
        info.removeAll()
        guard let source = item.mediaSources?.first(where: { $0.id == versionChoice }) ?? item.mediaSources?.first else { return }
        let group = PreferencesGroup("Media Info")
        for row in Presentation.mediaRows(source) {
            group.add(ActionRow(row.title, subtitle: row.value))
        }
        info.append(group)
    }

    // MARK: - Going places

    private func openParent() {
        guard let item = model.item, let seriesId = item.seriesId else { return }
        var show = BaseItem(id: seriesId)
        show.type = .series
        show.name = item.seriesName
        shell.open(show)
    }

    private func play(_ playable: BaseItem, from start: Double? = nil, queue: [BaseItem] = []) {
        let isThis = playable.id == model.item?.id
        let subtitle: Int?? = isThis ? subtitleChoice : nil
        shell.window.play(
            playable, from: start,
            audioIndex: isThis ? audioChoice : nil,
            subtitleIndex: subtitle ?? nil,
            mediaSourceId: isThis ? versionChoice : nil,
            queue: queue
        )
    }
}
