import CGtk
import Foundation

/// A poster, still or cover with its title under it: the unit of every row and grid.
///
/// Built once and filled again for each item (`show`), so a grid's recycled cells and a
/// row's fixed ones work the same way.
@MainActor
final class Card {
    private(set) var root: Widget = Bin()
    private var picture: FixedPicture!
    private let title = Label("", "card-title").ellipsize().lines(1)
    private let subtitle = Label("", "dim-label", "caption").ellipsize().lines(1)
    private let progress = ProgressBar()
    /// Plex's gold corner on what has not been watched.
    private let unwatchedMark = DrawingArea(width: 26, height: 26) { cairo, width, height in
        cairo.color(red: 0.898, green: 0.627, blue: 0.051)
        cairo.move(0, 0)
        cairo.line(width, 0)
        cairo.line(width, height)
        cairo.close()
        cairo.fill()
    }
    /// A show's unwatched episodes.
    private let count = Label("", "count-badge")
    /// The title on the tile, for an item with no picture: Plex's placeholder.
    private let placeholder = Label("", "title-4", "dim-label").wrap().lines(4).ellipsize()
    private var frame = Overlay()
    let style: CardStyle
    private(set) var item: BaseItem?

    static func size(_ style: CardStyle) -> (Int32, Int32) {
        switch style {
        case .poster: return (156, 234)
        case .landscape: return (272, 153)
        }
    }

    init(style: CardStyle, activate: @escaping @MainActor (BaseItem) -> Void, menu: (@MainActor (BaseItem) -> Menu?)? = nil) {
        self.style = style
        let (width, height) = Self.size(style)
        picture = FixedPicture(width: width, height: height)
        picture.css("card-art")
        frame = Overlay(picture)
        frame.add(placeholder.halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER).margin(12).canTarget(false))
        placeholder.justify(GTK_JUSTIFY_CENTER)
        frame.add(Box.vertical {
            Spacer(horizontal: false)
            progress.css("card-progress").margins(bottom: 6, start: 8, end: 8)
        }.canTarget(false))
        frame.add(unwatchedMark.halign(GTK_ALIGN_END).valign(GTK_ALIGN_START).canTarget(false))
        frame.add(count.halign(GTK_ALIGN_END).valign(GTK_ALIGN_START).margin(6).canTarget(false))
        frame.clipped()

        let content = Box.vertical(spacing: 4) {
            frame
            title.margins(top: 4)
            subtitle
        }
        content.size(width: width)
        let button = Button(child: content, "flat", "card")
        root = button
        let box = WeakBox(self)
        button.onClicked {
            guard let card = box.value, let item = card.item else { return }
            activate(item)
        }
        if let menu {
            button.contextMenu {
                guard let item = box.value?.item else { return nil }
                return menu(item)
            }
        }
        root.keep(self)
    }

    func show(_ item: BaseItem, client: JellyfinClient) {
        self.item = item
        let (width, _) = Self.size(style)
        let pixels = Int(width) * 2
        let art: URL?
        switch style {
        case .landscape: art = Artwork.landscape(item, client, width: pixels)
        default: art = Artwork.primary(item, client, width: pixels)
        }
        picture.picture.load(art)
        placeholder.text = item.title
        placeholder.visible(art == nil)
        if style == .landscape, item.type == .episode {
            title.text = item.seriesName ?? item.title
            subtitle.text = [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        } else {
            title.text = item.title
            subtitle.text = item.subtitle ?? ""
        }
        root.tooltip(item.title)
        if let value = item.progress {
            progress.fraction = value
            progress.visible(true)
        } else {
            progress.visible(false)
        }
        switch Presentation.unwatched(item) {
        case .none:
            unwatchedMark.visible(false)
            count.visible(false)
        case .mark:
            unwatchedMark.visible(true)
            count.visible(false)
        case let .count(number):
            unwatchedMark.visible(false)
            count.text = number > 99 ? "99+" : String(number)
            count.visible(true)
        }
    }
}

/// A weak reference for closures that GTK keeps, so they do not keep their target alive.
final class WeakBox<Object: AnyObject> {
    weak var value: Object?
    init(_ value: Object) { self.value = value }
}

/// A titled, sideways-scrolling row of cards: Continue Watching, Latest Movies.
@MainActor
final class CardRow {
    let root: Widget
    private let strip = Box.horizontal(spacing: 14)
    private var cards: [Card] = []
    private let style: CardStyle
    private let activate: @MainActor (BaseItem) -> Void
    private let menu: (@MainActor (BaseItem) -> Menu?)?

    init(
        title: String, style: CardStyle, more: (@MainActor () -> Void)? = nil,
        activate: @escaping @MainActor (BaseItem) -> Void, menu: (@MainActor (BaseItem) -> Menu?)? = nil
    ) {
        self.style = style
        self.activate = activate
        self.menu = menu
        let header = Box.horizontal(spacing: 8) {
            Label(title, "title-4")
            Spacer()
        }
        if let more {
            header.append(Button("See All", icon: "go-next-symbolic", "flat", action: more))
        }
        let scroller = ScrolledWindow(strip.margins(bottom: 10, start: 24, end: 24), horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER)
        scroller.propagatesNaturalHeight()
        root = Box.vertical(spacing: 8) {
            header.margins(start: 24, end: 18)
            scroller
        }
        root.keep(self)
    }

    func show(_ items: [BaseItem], client: JellyfinClient) {
        while cards.count < items.count {
            let card = Card(style: style, activate: activate, menu: menu)
            cards.append(card)
            strip.append(card.root)
        }
        for (index, card) in cards.enumerated() {
            if index < items.count {
                card.show(items[index], client: client)
                card.root.visible(true)
            } else {
                card.root.visible(false)
            }
        }
    }
}

/// A grid of every item in a library, built only as far as it is scrolled.
@MainActor
final class CardGrid {
    let root: Widget
    private let list: ItemList<BaseItem, Card>
    let scroller: ScrolledWindow

    init(
        style: CardStyle, client: @escaping @MainActor () -> JellyfinClient?,
        activate: @escaping @MainActor (BaseItem) -> Void, menu: (@MainActor (BaseItem) -> Menu?)? = nil
    ) {
        list = ItemList(
            .grid(minColumns: 2, maxColumns: 14),
            setup: {
                let card = Card(style: style, activate: activate, menu: menu)
                return (card.root, card)
            },
            bind: { card, item, _ in
                guard let client = client() else { return }
                card.show(item, client: client)
            }
        )
        list.view.css("card-grid")
        scroller = ScrolledWindow(list.view)
        scroller.vexpand()
        root = scroller
    }

    func set(_ items: [BaseItem]) {
        list.set(items)
    }

    /// Brings the item at `index` into view: the A–Z bar's jump.
    func scroll(to index: Int) {
        gtk_grid_view_scroll_to(list.view.widget.cast(), guint(index), GTK_LIST_SCROLL_NONE, nil)
    }
}

/// Plex's Cast & Crew: round photos, the name, and the part.
@MainActor
final class CastRow {
    let root: Widget

    init(people: [Person], client: JellyfinClient, open: @escaping @MainActor (BaseItem) -> Void) {
        let strip = Box.horizontal(spacing: 18)
        for person in people {
            let item = BaseItem(person: person)
            let photo = Picture()
            photo.size(width: 112, height: 112).css("cast-art")
            photo.load(Artwork.primary(item, client, width: 224))
            let face = Overlay(photo).add(Icon("avatar-default-symbolic", size: 40).css("dim-label").canTarget(false).visible(person.primaryImageTag == nil))
            face.clipped().css("cast-art")
            let card = Box.vertical(spacing: 4) {
                face
                Label(person.name ?? "", "card-title").ellipsize().lines(1).maxWidthChars(14)
                Label(person.role ?? person.type ?? "", "dim-label", "caption").ellipsize().lines(1).maxWidthChars(14)
            }.size(width: 112)
            strip.append(Button(child: card, "flat", "card") { open(item) })
        }
        let scroller = ScrolledWindow(strip.margins(bottom: 10, start: 24, end: 24), horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER)
        scroller.propagatesNaturalHeight()
        root = Box.vertical(spacing: 8) {
            Label("Cast & Crew", "title-4").halign(GTK_ALIGN_START).margins(start: 24)
            scroller
        }
    }
}
