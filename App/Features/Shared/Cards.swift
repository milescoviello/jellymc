import SwiftUI

/// An image from the server, filling its slot and cropping what overflows.
///
/// `Color.clear` with the image as an overlay, as in the Music app: an overlay is sized by
/// its parent and can never enlarge it, so art that is not the slot's shape fills it
/// without pushing the layout around.
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 10
    var placeholder: String = "film"
    /// Shown on the tile when there is no picture: Plex puts the title there.
    var title: String?

    var body: some View {
        Color.clear
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        ZStack {
                            Rectangle().fill(.quaternary)
                            if let title, url == nil {
                                Text(title)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                            } else {
                                Image(systemName: placeholder)
                                    .font(.title2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension CardStyle {
    var width: CGFloat { width(regular: false) }

    /// A card's width in a row: bigger on an iPad (regular width), where Plex shows fewer,
    /// larger posters across.
    func width(regular: Bool) -> CGFloat {
        switch self {
        case .poster: return regular ? 168 : 132
        case .landscape: return regular ? 300 : 236
        }
    }

    var aspect: CGFloat {
        switch self {
        case .poster: return 2.0 / 3.0
        case .landscape: return 16.0 / 9.0
        }
    }

    var placeholder: String {
        switch self {
        case .landscape: return "tv"
        case .poster: return "film"
        }
    }
}

/// Plex's gold, for marks and the like.
extension Color {
    static let plexGold = Color(red: 0.898, green: 0.627, blue: 0.051)
}

/// Plex's corner on what has not been watched: a gold triangle.
private struct UnwatchedCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A card's picture with Plex's marks on it: progress, the unwatched corner or count.
struct CardArt: View {
    @Environment(AppState.self) private var state
    let item: BaseItem
    let style: CardStyle
    let width: CGFloat

    var body: some View {
        ArtworkView(url: url(width: Int(width * 3)), placeholder: style.placeholder, title: item.title)
            .frame(width: width, height: width / style.aspect)
            .overlay(alignment: .bottom) {
                if let progress = item.progress {
                    ProgressView(value: progress)
                        .tint(.plexGold)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            }
            .overlay(alignment: .topTrailing) {
                switch Presentation.unwatched(item) {
                case .mark:
                    UnwatchedCorner().fill(Color.plexGold).frame(width: 22, height: 22)
                        .clipShape(UnevenRoundedRectangle(topTrailingRadius: 10, style: .continuous))
                case let .count(number):
                    Text(number > 99 ? "99+" : String(number))
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.black.opacity(0.87))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.plexGold, in: Capsule())
                        .padding(6)
                case .none:
                    EmptyView()
                }
            }
    }

    private func url(width: Int) -> URL? {
        guard let client = state.client else { return nil }
        return style == .landscape ? Artwork.landscape(item, client, width: width) : Artwork.poster(item, client, width: width)
    }
}

/// A poster, still or cover with its title under it.
struct CardView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let item: BaseItem
    let style: CardStyle
    var width: CGFloat?
    /// On its parent's page: a season card names the season, not the show again.
    var onParent = false

    var body: some View {
        let width = width ?? style.width(regular: sizeClass == .regular)
        VStack(alignment: .leading, spacing: 6) {
            CardArt(item: item, style: style, width: width)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var title: String { Presentation.cardLines(item, style: style, onParent: onParent).title }

    private var subtitle: String { Presentation.cardLines(item, style: style, onParent: onParent).subtitle }
}

/// A card that opens its item's page, Plex's way: play is on the page and in the menu.
struct CardLink: View {
    let item: BaseItem
    let style: CardStyle
    var width: CGFloat?
    var onParent = false

    var body: some View {
        NavigationLink(value: ItemRoute(item: item)) {
            CardView(item: item, style: style, width: width, onParent: onParent)
        }
        .buttonStyle(.plain)
        .contextMenu { ItemMenu(item: item) }
    }
}

/// A card's long-press menu, as Plex has it: play, watched, go to the show.
struct ItemMenu: View {
    @Environment(AppState.self) private var state
    @Environment(PlayerRouter.self) private var router
    let item: BaseItem

    var body: some View {
        if item.type?.isVideo == true {
            if item.resumeSeconds > 0 {
                Button { router.play(item) } label: { Label("Resume", systemImage: "play.fill") }
                Button { router.play(item, from: 0) } label: { Label("Play from Beginning", systemImage: "backward.end.fill") }
            } else {
                Button { router.play(item) } label: { Label("Play", systemImage: "play.fill") }
            }
        }
        if item.type != .person, item.type != .boxSet {
            Button {
                Task { await state.setPlayed(item, !item.isPlayed) }
            } label: {
                Label(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched", systemImage: item.isPlayed ? "circle" : "checkmark.circle")
            }
        }
        if item.resumeSeconds > 0 {
            Button {
                Task { await state.removeFromContinueWatching(item) }
            } label: {
                Label("Remove from Continue Watching", systemImage: "minus.circle")
            }
        }
        if item.type?.isVideo == true || item.type == .series || item.type == .season {
            Menu {
                ForEach(state.playlists) { playlist in
                    Button(playlist.title) { Task { await state.add(item, to: playlist) } }
                }
                Button { state.namingPlaylistFor = item } label: { Label("New Playlist…", systemImage: "plus") }
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }
        if item.type == .episode, let seriesId = item.seriesId {
            NavigationLink(value: ItemRoute(item: Self.show(seriesId, item))) {
                Label("Go to Show", systemImage: "tv")
            }
            if let seasonId = item.seasonId {
                NavigationLink(value: ItemRoute(item: Self.season(seasonId, item))) {
                    Label("Go to Season", systemImage: "square.stack")
                }
            }
        }
    }

    static func show(_ id: String, _ episode: BaseItem) -> BaseItem {
        var show = BaseItem(id: id)
        show.type = .series
        show.name = episode.seriesName
        return show
    }

    static func season(_ id: String, _ episode: BaseItem) -> BaseItem {
        var season = BaseItem(id: id)
        season.type = .season
        season.name = episode.seasonName
        season.seriesId = episode.seriesId
        season.seriesName = episode.seriesName
        return season
    }
}

/// A titled, sideways-scrolling row of cards: Plex's hubs.
struct CardRowView: View {
    let title: String
    let style: CardStyle
    let items: [BaseItem]
    /// What "See All" opens, if anything.
    var seeAll: Browse?
    var onParent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        Text("See All").font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        CardLink(item: item, style: style, onParent: onParent)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Plex's hubs, top to bottom: Home, and a library's Recommended tab.
struct HubList: View {
    let rows: [HomeRow]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(rows) { row in
                CardRowView(title: row.title, style: row.style, items: row.items, seeAll: row.seeAll)
            }
        }
        .padding(.vertical)
    }
}
