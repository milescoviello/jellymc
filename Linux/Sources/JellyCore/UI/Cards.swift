import CGtk
import Foundation

/// A poster, still or cover with its title under it: the unit of every row and grid.
///
/// Built once and filled again for each item (`show`), so a grid's recycled cells and a
/// row's fixed ones work the same way.
@MainActor
final class Card {
    private(set) var root: Widget = Bin()
    private let picture = Picture()
    private let title = Label("", "card-title").ellipsize().lines(1)
    private let subtitle = Label("", "dim-label", "caption").ellipsize().lines(1)
    private let progress = ProgressBar()
    private let played = Icon("object-select-symbolic", size: 14)
    private var frame = Overlay()
    let style: CardStyle
    private(set) var item: BaseItem?

    static func size(_ style: CardStyle) -> (Int32, Int32) {
        switch style {
        case .poster: return (156, 234)
        case .landscape: return (272, 153)
        case .square: return (168, 168)
        }
    }

    init(style: CardStyle, activate: @escaping @MainActor (BaseItem) -> Void) {
        self.style = style
        let (width, height) = Self.size(style)
        picture.size(width: width, height: height).css("card-art")
        frame = Overlay(picture)
        frame.add(Box.vertical {
            Spacer(horizontal: false)
            progress.css("card-progress").margins(bottom: 6, start: 8, end: 8)
        }.canTarget(false))
        frame.add(played.css("card-played").halign(GTK_ALIGN_END).valign(GTK_ALIGN_START).margin(8).canTarget(false))
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
        root.keep(self)
    }

    func show(_ item: BaseItem, client: JellyfinClient) {
        self.item = item
        let (width, _) = Self.size(style)
        let pixels = Int(width) * 2
        switch style {
        case .landscape: picture.load(Artwork.landscape(item, client, width: pixels))
        default: picture.load(Artwork.primary(item, client, width: pixels))
        }
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
        played.visible(item.isPlayed && item.type != .series && item.type != .musicAlbum)
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

    init(title: String, style: CardStyle, more: (@MainActor () -> Void)? = nil, activate: @escaping @MainActor (BaseItem) -> Void) {
        self.style = style
        self.activate = activate
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
            let card = Card(style: style, activate: activate)
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

    init(style: CardStyle, client: @escaping @MainActor () -> JellyfinClient?, activate: @escaping @MainActor (BaseItem) -> Void) {
        list = ItemList(
            .grid(minColumns: 2, maxColumns: 14),
            setup: {
                let card = Card(style: style, activate: activate)
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
}
