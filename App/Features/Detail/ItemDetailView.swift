import SwiftUI

/// Plex's pre-play screen: a film, a show and its seasons, a season and its episodes, an
/// episode, a collection, a person.
struct ItemDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(PlayerRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: ItemModel
    @State private var audioChoice: Int?
    /// -1 for off; nil for the preferences' choice.
    @State private var subtitleChoice: Int?
    @State private var versionChoice: String?

    init(item: BaseItem) {
        _model = State(initialValue: ItemModel(id: item.id, placeholder: item))
    }

    var body: some View {
        ScrollView {
            if let item = model.item {
                VStack(alignment: .leading, spacing: 22) {
                    hero(item)
                    VStack(alignment: .leading, spacing: 18) {
                        actions(item)
                        trackPickers(item)
                        if let tagline = item.taglines?.first {
                            Text(tagline).font(.headline)
                        }
                        if let overview = item.overview {
                            Text(overview)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        credits(item)
                    }
                    .padding(.horizontal)
                    if !model.seasons.isEmpty {
                        CardRowView(title: "\(model.seasons.count) Season\(model.seasons.count == 1 ? "" : "s")", style: .poster, items: model.seasons)
                    }
                    if !model.episodes.isEmpty { episodeList.padding(.horizontal) }
                    if !model.children.isEmpty {
                        CardRowView(title: item.type == .person ? "Filmography" : "\(model.children.count) Items", style: .poster, items: model.children)
                    }
                    extras(item)
                    if let source = selectedSource(item) { mediaInfo(source).padding(.horizontal) }
                }
                .padding(.bottom, 30)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.item == nil {
                if let error = model.error {
                    ContentUnavailableView("Couldn’t Load", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
        }
        .onChange(of: versionChoice) {
            // Another version has its own tracks.
            audioChoice = nil
            subtitleChoice = nil
        }
        .task {
            if let client = state.client { await model.load(client) }
        }
        .onChange(of: state.dataGeneration) {
            // Back from the player, or changed on another device: progress and watched marks.
            Task { if let client = state.client { await model.load(client) } }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func hero(_ item: BaseItem) -> some View {
        let client = state.client
        let height: CGFloat = sizeClass == .regular ? 520 : 420
        let isEpisode = item.type == .episode
        ZStack(alignment: .bottomLeading) {
            ArtworkView(url: client.flatMap { Artwork.backdrop(item, $0, width: 1600) ?? Artwork.primary(item, $0, width: 1000) }, cornerRadius: 0)
                .frame(height: height)
                .frame(maxWidth: .infinity)
            LinearGradient(
                colors: [.clear, Color(.systemBackground).opacity(0.6), Color(.systemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: height)
            HStack(alignment: .bottom, spacing: 16) {
                if item.type != .person || item.imageTags?["Primary"] != nil {
                    let width: CGFloat = isEpisode ? 150 : (sizeClass == .regular ? 160 : 110)
                    ArtworkView(url: client.flatMap { isEpisode ? Artwork.primary(item, $0, width: 450) : Artwork.poster(item, $0, width: 480) }, cornerRadius: 8, title: item.title)
                        .frame(width: width, height: isEpisode ? width * 9 / 16 : width * 1.5)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if isEpisode || item.type == .season, let show = item.seriesName, let seriesId = item.seriesId {
                        NavigationLink(value: ItemRoute(item: ItemMenu.show(seriesId, item))) {
                            Text(show).font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    if !isEpisode, item.type != .season, let logo = client.flatMap({ Artwork.logo(item, $0, width: 600) }) {
                        AsyncImage(url: logo) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Text(item.title).font(.title.bold())
                        }
                        .frame(maxWidth: 260, maxHeight: 90, alignment: .leading)
                    } else {
                        Text(item.title)
                            .font(.title.bold())
                            .lineLimit(3)
                    }
                    if isEpisode {
                        Text([item.seasonName, item.indexNumber.map { "Episode \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.headline)
                    }
                    Text(Presentation.metaLine(item, episodeLabel: !isEpisode))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    let ratings = Presentation.ratings(item)
                    if !ratings.isEmpty {
                        Text(ratings.joined(separator: "   ")).font(.subheadline.weight(.bold))
                    }
                    if let genres = item.genres, !genres.isEmpty {
                        Text(genres.prefix(4).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(_ item: BaseItem) -> some View {
        HStack(spacing: 12) {
            if let playable = model.playable {
                Button {
                    start(playable)
                } label: {
                    Label(Presentation.playLabel(for: playable, on: item), systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .tint(.plexGold)
                .controlSize(.large)
                if playable.resumeSeconds > 0 {
                    Button {
                        start(playable, from: 0)
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Play from Beginning")
                }
            }
            if let trailer = item.remoteTrailers?.first?.url.flatMap(URL.init(string:)) {
                Link(destination: trailer) {
                    Image(systemName: "film")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Play Trailer")
            } else if let local = model.extras.first(where: { $0.type == .trailer }) {
                Button { router.play(local) } label: { Image(systemName: "film") }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Play Trailer")
            }
            if item.type != .person, item.type != .boxSet {
                Button {
                    Task { await model.togglePlayed() }
                } label: {
                    Image(systemName: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(item.isPlayed ? Color.plexGold : Color.primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched")
            }
            Button {
                Task { await model.toggleFavorite() }
            } label: {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(item.isFavorite ? Color.plexGold : Color.primary)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel(item.isFavorite ? "Remove from Favourites" : "Add to Favourites")
            if item.type?.isVideo == true {
                DownloadButton(item: item)
            }
            if item.type == .season, !model.episodes.isEmpty {
                let episodes = model.episodes
                Button {
                    Task { await state.downloads.download(episodes, for: .avPlayer) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Download Season")
            }
        }
    }

    private func start(_ playable: BaseItem, from start: Double? = nil) {
        guard playable.id == model.item?.id, let item = model.item, let source = selectedSource(item) else {
            router.play(playable, from: start)
            return
        }
        // Resolved here, so a changed audio track does not drop the default subtitles.
        let initial = state.preferences.initialTracks(for: source)
        let subtitle = subtitleChoice.map { $0 < 0 ? nil : $0 } ?? initial.subtitle
        router.play(playable, from: start, audio: audioChoice ?? initial.audio, subtitle: subtitle, version: versionChoice)
    }

    private func selectedSource(_ item: BaseItem) -> MediaSource? {
        item.mediaSources?.first { $0.id == versionChoice } ?? item.mediaSources?.first
    }

    /// Video, audio and subtitles, as Plex lists them under the buttons.
    @ViewBuilder
    private func trackPickers(_ item: BaseItem) -> some View {
        if model.playable?.id == item.id, let sources = item.mediaSources, let source = selectedSource(item) {
            let initial = state.preferences.initialTracks(for: source)
            let audio = audioChoice ?? initial.audio
            let subtitle = subtitleChoice.map { $0 < 0 ? nil : $0 } ?? initial.subtitle
            VStack(alignment: .leading, spacing: 8) {
                if let video = source.videoStream {
                    Menu {
                        Picker("Video", selection: $versionChoice) {
                            ForEach(sources, id: \.id) { Text($0.name ?? $0.videoStream?.label ?? $0.id).tag(Optional($0.id)) }
                        }
                    } label: {
                        trackRow("Video", sources.count > 1 ? (source.name ?? video.label) : video.label)
                    }
                    .disabled(sources.count < 2)
                }
                if !source.audioStreams.isEmpty {
                    Menu {
                        Picker("Audio", selection: $audioChoice) {
                            ForEach(source.audioStreams, id: \.index) { Text($0.label).tag(Optional($0.index)) }
                        }
                    } label: {
                        trackRow("Audio", source.audioStreams.first { $0.index == audio }?.label ?? "Audio")
                    }
                }
                Menu {
                    Picker("Subtitles", selection: $subtitleChoice) {
                        Text("None").tag(Optional(-1))
                        ForEach(source.subtitleStreams, id: \.index) { Text($0.label).tag(Optional($0.index)) }
                    }
                } label: {
                    trackRow("Subtitles", subtitle.flatMap { index in source.subtitleStreams.first { $0.index == index }?.label } ?? "None")
                }
            }
            .font(.subheadline)
        }
    }

    private func trackRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(value).foregroundStyle(.primary).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Directed by, Written by, Studio.
    @ViewBuilder
    private func credits(_ item: BaseItem) -> some View {
        let lines = Presentation.credits(item)
        if !lines.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    GridRow {
                        Text(line.title).foregroundStyle(.secondary)
                        Text(line.names)
                    }
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: - Episodes

    private var episodeList: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(model.episodes) { episode in
                // Plex: an episode opens its page; play is there, or in the menu.
                NavigationLink(value: ItemRoute(item: episode)) {
                    EpisodeRow(episode: episode)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    ItemMenu(item: episode)
                    if state.downloads.record(for: episode.id) == nil {
                        Button {
                            Task { await state.downloads.download(episode, for: .avPlayer) }
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Below

    @ViewBuilder
    private func extras(_ item: BaseItem) -> some View {
        let people = Presentation.castAndCrew(item)
        if !people.isEmpty {
            CastRowView(people: people)
        }
        if !model.extras.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Extras").font(.title3.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(model.extras) { extra in
                            Button { router.play(extra) } label: { CardView(item: extra, style: .landscape) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        if !model.similar.isEmpty {
            CardRowView(title: "More Like This", style: .poster, items: model.similar)
        }
    }

    private func mediaInfo(_ source: MediaSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Media Info").font(.title3.bold())
            ForEach(Array(Presentation.mediaRows(source).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.caption).foregroundStyle(.secondary)
                    Text(row.value).font(.subheadline)
                }
            }
        }
    }
}

/// Plex's Cast & Crew: round photos, the name, and the part.
private struct CastRowView: View {
    @Environment(AppState.self) private var state
    let people: [Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast & Crew").font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(people) { person in
                        let item = BaseItem(person: person)
                        NavigationLink(value: ItemRoute(item: item)) {
                            VStack(spacing: 4) {
                                ArtworkView(url: state.client.flatMap { Artwork.primary(item, $0, width: 240) }, cornerRadius: 45, placeholder: "person.fill")
                                    .frame(width: 90, height: 90)
                                Text(person.name ?? "")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(person.role ?? person.type ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 96)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct EpisodeRow: View {
    @Environment(AppState.self) private var state
    let episode: BaseItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CardArt(item: episode, style: .landscape, width: 160)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.title)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if state.downloads.record(for: episode.id)?.isDone == true {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                            .accessibilityLabel("Downloaded")
                    }
                }
                if let runtime = episode.runtime {
                    Text(Ticks.runtime(runtime)).font(.caption).foregroundStyle(.secondary)
                }
                if let overview = episode.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
