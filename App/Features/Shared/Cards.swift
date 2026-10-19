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
                            Image(systemName: placeholder)
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension CardStyle {
    var width: CGFloat {
        switch self {
        case .poster: return 132
        case .landscape: return 236
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

/// A poster, still or cover with its title under it.
struct CardView: View {
    @Environment(AppState.self) private var state
    let item: BaseItem
    let style: CardStyle
    var width: CGFloat?

    var body: some View {
        let width = width ?? style.width
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: url(width: Int(width * 3)), placeholder: style.placeholder)
                .frame(width: width, height: width / style.aspect)
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressView(value: progress)
                            .tint(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.isPlayed, item.type != .series, item.type != .boxSet {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
                }
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

    private var title: String {
        style == .landscape && item.type == .episode ? (item.seriesName ?? item.title) : item.title
    }

    private var subtitle: String {
        if style == .landscape, item.type == .episode {
            return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        }
        return item.subtitle ?? ""
    }

    private func url(width: Int) -> URL? {
        guard let client = state.client else { return nil }
        return style == .landscape ? Artwork.landscape(item, client, width: width) : Artwork.primary(item, client, width: width)
    }
}

/// A titled, sideways-scrolling row of cards. Cards play or open, as the row says.
struct CardRowView: View {
    @Environment(PlayerRouter.self) private var router
    let title: String
    let style: CardStyle
    let items: [BaseItem]
    var playsDirectly = false
    var library: BaseItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                if let library {
                    NavigationLink(value: LibraryRoute(library: library)) {
                        Text("See All").font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        if playsDirectly {
                            Button { router.play(item) } label: { CardView(item: item, style: style) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    NavigationLink(value: ItemRoute(item: item)) {
                                        Label("Details", systemImage: "info.circle")
                                    }
                                }
                        } else {
                            NavigationLink(value: ItemRoute(item: item)) { CardView(item: item, style: style) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
