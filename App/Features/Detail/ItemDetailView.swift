import SwiftUI

/// A film, a series and its seasons, an episode, a collection, a person.
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
                        if !model.seasons.isEmpty { seasonPicker }
                        if !model.episodes.isEmpty { episodeList }
                        if !model.children.isEmpty { childrenSection(item) }
                        if let source = selectedSource(item) { mediaInfo(source) }
                    }
                    .padding(.horizontal)
                    extras(item)
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
        .onChange(of: state.playbackGeneration) {
            // Back from the player: the progress and watched marks have moved.
            Task { if let client = state.client { await model.load(client) } }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func hero(_ item: BaseItem) -> some View {
        let client = state.client
        let height: CGFloat = sizeClass == .regular ? 460 : 340
        ZStack(alignment: .bottomLeading) {
            ArtworkView(url: client.flatMap { Artwork.backdrop(item, $0, width: 1600) ?? Artwork.primary(item, $0, width: 1000) }, cornerRadius: 0)
                .frame(height: height)
                .frame(maxWidth: .infinity)
            LinearGradient(
                colors: [.clear, Color(.systemBackground).opacity(0.6), Color(.systemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: height)
            VStack(alignment: .leading, spacing: 8) {
                if let logo = client.flatMap({ Artwork.logo(item, $0, width: 600) }) {
                    AsyncImage(url: logo) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text(title(item)).font(.largeTitle.bold())
                    }
                    .frame(maxWidth: 320, maxHeight: 110, alignment: .leading)
                } else {
                    Text(title(item))
                        .font(.largeTitle.bold())
                        .lineLimit(3)
                }
                Text(Presentation.metaLine(item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let genres = item.genres, !genres.isEmpty {
                    Text(genres.prefix(4).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private func title(_ item: BaseItem) -> String {
        item.type == .episode ? "\(item.seriesName ?? "") — \(item.title)" : item.title
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
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if playable.resumeSeconds > 0 {
                    Button {
                        start(playable, from: 0)
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Play from the start")
                }
            }
            if item.type != .person {
                Button {
                    Task { await model.togglePlayed() }
                } label: {
                    Image(systemName: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel(item.isPlayed ? "Mark unplayed" : "Mark played")
            }
            Button {
                Task { await model.toggleFavorite() }
            } label: {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel(item.isFavorite ? "Remove from favourites" : "Add to favourites")
            if item.type?.isVideo == true {
                DownloadButton(item: item)
            }
            if let trailer = item.remoteTrailers?.first?.url.flatMap(URL.init(string:)) {
                Link(destination: trailer) {
                    Image(systemName: "film.stack")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Trailer")
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

    @ViewBuilder
    private func trackPickers(_ item: BaseItem) -> some View {
        if model.playable?.id == item.id, let sources = item.mediaSources, let source = selectedSource(item) {
            let initial = state.preferences.initialTracks(for: source)
            let audio = audioChoice ?? initial.audio
            let subtitle = subtitleChoice.map { $0 < 0 ? nil : $0 } ?? initial.subtitle
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if sources.count > 1 {
                        Menu {
                            Picker("Version", selection: $versionChoice) {
                                ForEach(sources, id: \.id) { Text($0.name ?? $0.id).tag(Optional($0.id)) }
                            }
                        } label: {
                            Label(source.name ?? "Version", systemImage: "square.stack")
                        }
                    }
                    if source.audioStreams.count > 1 {
                        Menu {
                            Picker("Audio", selection: $audioChoice) {
                                ForEach(source.audioStreams, id: \.index) { Text($0.label).tag(Optional($0.index)) }
                            }
                        } label: {
                            Label(source.audioStreams.first { $0.index == audio }?.label ?? "Audio", systemImage: "speaker.wave.2")
                        }
                    }
                    if !source.subtitleStreams.isEmpty {
                        Menu {
                            Picker("Subtitles", selection: $subtitleChoice) {
                                Text("Off").tag(Optional(-1))
                                ForEach(source.subtitleStreams, id: \.index) { Text($0.label).tag(Optional($0.index)) }
                            }
                        } label: {
                            Label(subtitle.flatMap { index in source.subtitleStreams.first { $0.index == index }?.label } ?? "Subtitles Off", systemImage: "captions.bubble")
                        }
                    }
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Series

    private var seasonPicker: some View {
        HStack {
            Picker("Season", selection: $model.selectedSeasonId) {
                ForEach(model.seasons) { season in
                    Text(season.title).tag(Optional(season.id))
                }
            }
            .pickerStyle(.menu)
            .font(.headline)
            Spacer()
            if !model.episodes.isEmpty {
                let episodes = model.episodes
                Button {
                    Task { await state.downloads.download(episodes, for: .avPlayer) }
                } label: {
                    Label("Download Season", systemImage: "arrow.down.circle")
                }
                .font(.subheadline)
            }
        }
    }

    private var episodeList: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(model.episodes) { episode in
                Button {
                    router.play(episode)
                } label: {
                    EpisodeRow(episode: episode)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { router.play(episode, from: 0) } label: { Label("Play from the Start", systemImage: "backward.end") }
                    Button {
                        Task { await model.setEpisodePlayed(episode, !episode.isPlayed) }
                    } label: {
                        Label(episode.isPlayed ? "Mark Unplayed" : "Mark Played", systemImage: "checkmark.circle")
                    }
                    if state.downloads.record(for: episode.id) == nil {
                        Button {
                            Task { await state.downloads.download(episode, for: .avPlayer) }
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                    NavigationLink(value: ItemRoute(item: episode)) { Label("Details", systemImage: "info.circle") }
                }
            }
        }
    }

    // MARK: - Contents

    private func childrenSection(_ item: BaseItem) -> some View {
        CardRowView(
            title: item.type == .person ? "Filmography" : "In This Collection",
            style: .poster,
            items: model.children
        )
        .padding(.horizontal, -16)
    }

    private func mediaInfo(_ source: MediaSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Media").font(.title3.bold())
            ForEach(Array(Presentation.mediaRows(source).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.caption).foregroundStyle(.secondary)
                    Text(row.value).font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private func extras(_ item: BaseItem) -> some View {
        let people = Array((item.people ?? []).prefix(30))
        if !people.isEmpty {
            CardRowView(
                title: "Cast & Crew",
                style: .poster,
                items: people.map(BaseItem.init(person:))
            )
        }
        if !model.similar.isEmpty {
            CardRowView(title: "More Like This", style: .poster, items: model.similar)
        }
    }
}

/// One episode: its still, number and title, a few lines of what happens.
private struct EpisodeRow: View {
    @Environment(AppState.self) private var state
    let episode: BaseItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkView(url: state.client.flatMap { Artwork.primary(episode, $0, width: 480) }, placeholder: "tv")
                .frame(width: 160, height: 90)
                .overlay(alignment: .bottom) {
                    if let progress = episode.progress {
                        ProgressView(value: progress).padding(.horizontal, 6).padding(.bottom, 4)
                    }
                }
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
                    if episode.isPlayed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
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
