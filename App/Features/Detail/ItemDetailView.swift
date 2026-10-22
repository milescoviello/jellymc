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
    /// The other apps that can be told to play, as last fetched.
    @State private var remoteSessions: [RemoteSession] = []
    /// A word on what just happened, at the foot of the page for a moment.
    @State private var notice: String?

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
                            Text(Presentation.plainText(overview))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        credits(item)
                    }
                    // A summary across a whole iPad is hard to read; Plex keeps it a column.
                    .frame(maxWidth: sizeClass == .regular ? 820 : .infinity, alignment: .leading)
                    .padding(.horizontal)
                    if !model.seasons.isEmpty {
                        CardRowView(title: "\(model.seasons.count) Season\(model.seasons.count == 1 ? "" : "s")", style: .poster, items: model.seasons, onParent: true)
                    }
                    if !model.episodes.isEmpty {
                        episodeList
                            .frame(maxWidth: sizeClass == .regular ? 1000 : .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
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
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            if let client = state.client { await model.load(client) }
        }
        .task {
            // Ready for Play On; opening its menu asks again.
            if let client = state.client { remoteSessions = (try? await client.remoteSessions()) ?? [] }
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
            // A collection with no art of its own borrows its first film's, as Plex's does.
            ArtworkView(url: client.flatMap { client in
                Artwork.backdrop(item, client, width: 1600)
                    ?? model.children.first.flatMap { Artwork.backdrop($0, client, width: 1600) }
                    ?? Artwork.primary(item, client, width: 1000)
            }, cornerRadius: 0)
                .frame(height: height)
                .frame(maxWidth: .infinity)
            LinearGradient(
                colors: [.clear, Color(.systemBackground).opacity(0.6), Color(.systemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: height)
            HStack(alignment: .bottom, spacing: 16) {
                if client.flatMap({ Artwork.poster(item, $0, width: 10) }) != nil {
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
                    if !isEpisode, item.type != .season, let logo = client.flatMap({ Artwork.readableLogo(item, $0, width: 600) }) {
                        LogoView(url: logo, title: item.title)
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

    /// Plex's buttons: Play (and Play from Beginning) first, then the rest as icons with
    /// their names under them. A phone gives Play the width and puts the rest in a row
    /// of their own below; on an iPad they share one row.
    @ViewBuilder
    private func actions(_ item: BaseItem) -> some View {
        if sizeClass == .regular {
            HStack(spacing: 14) {
                playButtons(item)
                Group { otherButtons(item) }.frame(width: 72)
            }
        } else {
            VStack(spacing: 16) {
                playButtons(item)
                HStack(alignment: .top, spacing: 4) {
                    Group { otherButtons(item) }.frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func playButtons(_ item: BaseItem) -> some View {
        if let playable = model.playable {
            HStack(spacing: 10) {
                Button {
                    start(playable)
                } label: {
                    Label(Presentation.playLabel(for: playable, on: item), systemImage: "play.fill")
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.black)
                        .frame(minWidth: 130, maxWidth: sizeClass == .regular ? nil : .infinity)
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
        }
    }

    /// Each one sized by the caller: spread across a phone, a fixed width on an iPad.
    @ViewBuilder
    private func otherButtons(_ item: BaseItem) -> some View {
        if model.canShuffle {
            Button {
                Task {
                    let order = await model.shuffled()
                    guard let first = order.first else { return }
                    router.play(first, from: 0, queue: Array(order.dropFirst()))
                }
            } label: {
                ActionLabel(title: "Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.plain)
        }
        if let trailer = item.remoteTrailers?.first?.url.flatMap(URL.init(string:)) {
            Link(destination: trailer) {
                ActionLabel(title: "Trailer", systemImage: "film")
            }
            .buttonStyle(.plain)
        } else if let local = model.extras.first(where: { $0.type == .trailer }) {
            Button { router.play(local) } label: { ActionLabel(title: "Trailer", systemImage: "film") }
                .buttonStyle(.plain)
        }
        if item.type != .person, item.type != .boxSet {
            Button {
                Task { await model.togglePlayed() }
            } label: {
                ActionLabel(title: "Watched", systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle", isOn: item.isPlayed)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched")
        }
        Button {
            Task { await model.toggleFavorite() }
        } label: {
            ActionLabel(title: "Favourite", systemImage: item.isFavorite ? "heart.fill" : "heart", isOn: item.isFavorite)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.isFavorite ? "Remove from Favourites" : "Add to Favourites")
        if let playable = model.playable {
            // Plex's cast: another app signed in to the server plays it instead.
            Menu {
                Group {
                    if remoteSessions.isEmpty {
                        Text("No other device is open")
                    }
                    ForEach(remoteSessions) { session in
                        Button(session.title) { play(playable, on: session) }
                    }
                }
                // The list shown is the one fetched before; opening it fetches it for next time.
                .onAppear(perform: refreshRemoteSessions)
            } label: {
                ActionLabel(title: "Play On", systemImage: "tv")
            }
            .buttonStyle(.plain)
        }
        if item.type?.isVideo == true {
            DownloadButton(item: item)
        }
        if item.type == .season, !model.episodes.isEmpty {
            let episodes = model.episodes
            Button {
                Task { await state.downloads.download(episodes, for: .avPlayer) }
            } label: {
                ActionLabel(title: "Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download Season")
        }
    }

    private func start(_ playable: BaseItem, from start: Double? = nil) {
        guard playable.id == model.item?.id, let item = model.item, let source = selectedSource(item) else {
            router.play(playable, from: start, queue: model.queueAfterPlayable)
            return
        }
        // Resolved here, so a changed audio track does not drop the default subtitles.
        let initial = state.preferences.initialTracks(for: source, item: item)
        let subtitle = subtitleChoice.map { $0 < 0 ? nil : $0 } ?? initial.subtitle
        router.play(playable, from: start, audio: audioChoice ?? initial.audio, subtitle: subtitle, version: versionChoice)
    }

    private func refreshRemoteSessions() {
        guard let client = state.client else { return }
        Task { remoteSessions = (try? await client.remoteSessions()) ?? [] }
    }

    /// Sends it to another app, with the tracks chosen here, from where it was left.
    private func play(_ playable: BaseItem, on session: RemoteSession) {
        guard let client = state.client else { return }
        let isThis = playable.id == model.item?.id
        Task {
            do {
                try await client.play(
                    playable.id, on: session.id, start: playable.resumeSeconds,
                    mediaSourceId: isThis ? versionChoice : nil,
                    audioIndex: isThis ? audioChoice : nil,
                    subtitleIndex: isThis ? subtitleChoice.flatMap { $0 < 0 ? nil : $0 } : nil
                )
                // As casting does: the remote, for what it now plays there.
                state.remote.follow(session, playing: playable)
                router.showsRemote = true
            } catch {
                show("Couldn’t play there: \(error.localizedDescription)")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if notice == text { notice = nil } }
        }
    }

    private func selectedSource(_ item: BaseItem) -> MediaSource? {
        item.mediaSources?.first { $0.id == versionChoice } ?? item.mediaSources?.first
    }

    /// Video, audio and subtitles, as Plex lists them under the buttons.
    @ViewBuilder
    private func trackPickers(_ item: BaseItem) -> some View {
        if model.playable?.id == item.id, let sources = item.mediaSources, let source = selectedSource(item) {
            let initial = state.preferences.initialTracks(for: source, item: item)
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

/// A pre-play button's face: an icon with its name under it, gold while it is on.
struct ActionLabel: View {
    let title: String
    var systemImage: String?
    /// Shown in the icon's place: a download's percentage.
    var text: String?
    var isOn = false

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let text {
                    Text(text).font(.subheadline.weight(.semibold)).monospacedDigit()
                } else if let systemImage {
                    Image(systemName: systemImage).font(.title3)
                }
            }
            .frame(height: 26)
            .foregroundStyle(isOn ? Color.plexGold : Color.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 4)
        .frame(minWidth: 44)
        .contentShape(Rectangle())
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    let episode: BaseItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CardArt(item: episode, style: .landscape, width: sizeClass == .regular ? 240 : 160)
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
                    Text(Presentation.plainText(overview)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// The title's logo, or the title itself when the logo is dark: on the page's dark shade a
/// dark logo reads as nothing, and Plex shows the title then.
private struct LogoView: View {
    let url: URL
    let title: String
    @State private var image: UIImage?
    @State private var tooDark = false

    var body: some View {
        Group {
            if let image, !tooDark {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 90, alignment: .leading)
            } else {
                Text(title).font(.title.bold()).lineLimit(3)
            }
        }
        .task(id: url) {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let loaded = UIImage(data: data) else { return }
            tooDark = (Self.lightness(loaded) ?? 1) < 0.25
            image = loaded
        }
    }

    /// The average lightness of the drawn (mostly opaque) pixels, on a small copy.
    private static func lightness(_ image: UIImage) -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0, count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3])
            guard alpha > 160 else { continue }
            let red = Double(pixels[index]) / alpha, green = Double(pixels[index + 1]) / alpha, blue = Double(pixels[index + 2]) / alpha
            total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
            count += 1
        }
        return count == 0 ? nil : total / Double(count)
    }
}
