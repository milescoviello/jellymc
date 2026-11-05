import CGtk
import Foundation

/// A library, as Plex lays one out: Recommended, Library, Collections and Categories,
/// switched from the header. A collections library is its grid alone.
@MainActor
final class LibraryPage {
    let root: Widget
    private unowned let shell: Shell

    init(shell: Shell, library: BaseItem) {
        self.shell = shell
        let header = HeaderBar()
        let isClips = library.collectionType == "homevideos"
        guard library.collectionType == "movies" || library.collectionType == "tvshows" || isClips else {
            let grid = BrowseView(shell: shell, model: LibraryModel(library: library))
            header.title(WindowTitle(library.title)).end(grid.options).end(grid.count)
            root = ToolbarView(content: grid.root).top(header)
            root.keep(self)
            return
        }
        let stack = ViewStack()
        let recommended = RecommendedView(shell: shell, library: library)
        let all = BrowseView(shell: shell, model: LibraryModel(library: library))
        stack.add(recommended.root, name: "recommended", title: isClips ? "Folders" : "Recommended")
        stack.add(all.root, name: "library", title: isClips ? "All" : "Library")
        if library.collectionType == "movies" {
            stack.add(BrowseView(shell: shell, model: .collections()).root, name: "collections", title: "Collections")
        }
        if !isClips {
            stack.add(CategoriesView(shell: shell, library: library).root, name: "categories", title: "Categories")
        }
        header.title(ViewSwitcher(stack)).end(all.options).end(all.count)
        // Sorting and the count belong to the Library tab.
        all.options.visible(false)
        all.count.visible(false)
        stack.onSwitch { name in
            all.options.visible(name == "library")
            all.count.visible(name == "library")
        }
        root = ToolbarView(content: stack).top(header)
        root.keep(self)
        root.keep(recommended)
        root.keep(all)
    }
}

/// What "See All" and a genre open: one sort or filter of a library, as a grid.
@MainActor
final class BrowsePage {
    let root: Widget

    init(shell: Shell, browse: Browse) {
        let grid = BrowseView(shell: shell, model: LibraryModel(browse: browse))
        let header = HeaderBar().title(WindowTitle(browse.title)).end(grid.options).end(grid.count)
        root = ToolbarView(content: grid.root).top(header)
        root.keep(grid)
    }
}

/// A grid of a library's items, paged in as it scrolls, with Plex's sort and filter menu
/// and an A–Z bar down the side while sorted by title.
@MainActor
final class BrowseView {
    let root: Widget
    /// For the header: sort and filter, and how many there are.
    let options: Widget
    let count = Label("", "dim-label")
    private let model: LibraryModel

    init(shell: Shell, model: LibraryModel) {
        self.model = model
        let grid = CardGrid(
            style: model.style, client: { [weak shell] in shell?.state.client },
            activate: { [weak shell] item in shell?.open(item) },
            menu: { [weak shell] item in shell.flatMap { ItemMenu.make(item, shell: $0) } }
        )
        let sorting = MenuButton(icon: "view-sort-descending-symbolic", "flat") {
            Menu([
                [.choice("Sort By", options: ItemQuery.Sort.allCases.map { ($0.rawValue, $0.title) }, selected: model.sort.rawValue) { id in
                    if let sort = ItemQuery.Sort(rawValue: id) { model.sort = sort }
                }],
                [.toggle("Descending", isOn: model.descending) { model.descending = $0 }],
            ])
        }.tooltip("Sort")
        // Plex's filters: watched state, then genre, decade, content rating, resolution.
        let filtering = MenuButton(icon: "jellymc-filter-symbolic", "flat") {
            let all = ("all", "All")
            let choices = model.choices
            var sections: [[Menu.Item]] = [[
                .choice("Show", options: [all] + ItemQuery.Filter.allCases.map { ($0.rawValue, $0.title) }, selected: model.filter?.rawValue ?? "all") { id in
                    model.filter = ItemQuery.Filter(rawValue: id)
                },
            ]]
            var narrow: [Menu.Item] = []
            if let genres = choices.genres, !genres.isEmpty {
                narrow.append(.choice("Genre", options: [all] + genres.map { ($0, $0) }, selected: model.genre ?? "all") { id in
                    model.genre = id == "all" ? nil : id
                })
            }
            if !choices.decades.isEmpty {
                narrow.append(.choice("Decade", options: [all] + choices.decades.map { (String($0), "\($0)s") }, selected: model.decade.map(String.init) ?? "all") { id in
                    model.decade = Int(id)
                })
            }
            if let ratings = choices.officialRatings, !ratings.isEmpty {
                narrow.append(.choice("Content Rating", options: [all] + ratings.map { ($0, $0) }, selected: model.contentRating ?? "all") { id in
                    model.contentRating = id == "all" ? nil : id
                })
            }
            narrow.append(.choice("Resolution", options: [all] + LibraryModel.Resolution.allCases.map { ($0.rawValue, $0.rawValue) }, selected: model.resolution?.rawValue ?? "all") { id in
                model.resolution = LibraryModel.Resolution(rawValue: id)
            })
            sections.append(narrow)
            if model.activeFilters > 0 {
                sections.append([.action("Clear Filters") { model.clearFilters() }])
            }
            return Menu(sections)
        }.tooltip("Filter")
        let shuffle = Button(icon: "media-playlist-shuffle-symbolic", "flat") { [weak shell] in
            guard let shell else { return }
            Task {
                let order = await model.shuffled()
                guard let first = order.first else { return }
                shell.window.play(first, from: 0, queue: Array(order.dropFirst()))
            }
        }.tooltip("Shuffle")
        shuffle.visible(model.kinds != [.boxSet] && model.kinds != [.playlist])
        options = Box.horizontal(spacing: 0) {
            shuffle
            filtering
            sorting
        }

        // "#" for what comes before A, then the letters.
        let letters = ["#"] + (65 ... 90).map { String(UnicodeScalar($0)) }
        let alphabet = Box.vertical(spacing: 0).css("alphabet").valign(GTK_ALIGN_CENTER).margins(end: 6)
        for letter in letters {
            alphabet.append(Button(letter, "flat", "alphabet-letter") {
                Task {
                    guard let index = await model.index(of: letter) else { return }
                    await model.load(through: index)
                    grid.scroll(to: min(index, max(0, model.items.count - 1)))
                }
            })
        }

        let empty = StatusPage(icon: "folder-symbolic", title: "Nothing Here")
        let stack = Stack()
        stack.add(Box.horizontal {
            grid.root.hexpand()
            alphabet
        }, name: "grid")
        stack.add(empty, name: "empty")
        stack.add(Spinner().size(40).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER), name: "loading")
        root = stack
        root.keep(self)
        root.keep(grid)

        grid.scroller.onNearEnd { Task { await model.loadMore() } }
        let count = self.count
        root.observe {
            grid.set(model.items)
            alphabet.visible(model.isAlphabetical && (model.total ?? 0) > 40)
            // Lit while anything narrows what is shown.
            if model.activeFilters > 0 {
                gtk_widget_add_css_class(filtering.widget, "played-on")
            } else {
                gtk_widget_remove_css_class(filtering.widget, "played-on")
            }
            count.text = model.total.map { "\($0) item\($0 == 1 ? "" : "s")" } ?? ""
            if model.items.isEmpty {
                stack.visibleName = model.isLoading || model.total == nil ? "loading" : "empty"
                if let error = model.error { empty.title = "Couldn’t Load"; empty.descriptionText = error }
            } else {
                stack.visibleName = "grid"
            }
        }
        if let client = shell.state.client {
            Task { await model.load(client) }
        }
    }
}

/// A library's Recommended tab: Plex's rows, top to bottom.
@MainActor
final class RecommendedView {
    let root: Widget
    private unowned let shell: Shell
    private let rows = Box.vertical(spacing: 30)
    private var built: [String: CardRow] = [:]
    private var order: [String] = []

    init(shell: Shell, library: BaseItem) {
        self.shell = shell
        let model = RecommendedModel(library: library)
        let stack = Stack()
        stack.add(Spinner().size(40).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER), name: "loading")
        stack.add(ScrolledWindow(rows.margins(top: 20, bottom: 30)).vexpand(), name: "rows")
        stack.add(StatusPage(icon: Shell.icon(for: library.collectionType), title: "Nothing Here Yet"), name: "empty")
        root = stack
        root.keep(self)
        root.observe { [weak self] in
            guard let self else { return }
            if model.rows.isEmpty {
                stack.visibleName = model.isLoading ? "loading" : "empty"
            } else {
                stack.visibleName = "rows"
                self.show(model.rows)
            }
        }
        // Back from the player, or changed elsewhere: Continue Watching and the rest move.
        let generation = shell.state.dataGeneration
        root.observe { [weak shell] in
            guard let shell, shell.state.dataGeneration != generation, let client = shell.state.client else { return }
            Task { await model.load(client, force: true) }
        }
        if let client = shell.state.client {
            Task { await model.load(client) }
        }
    }

    private func show(_ hubs: [HomeRow]) {
        guard let client = shell.state.client else { return }
        let ids = hubs.map(\.id)
        if ids != order {
            // A row removed from the box loses its widgets, so a new order gets new rows.
            rows.removeAll()
            built = [:]
            for hub in hubs {
                var more: (@MainActor () -> Void)?
                if let browse = hub.seeAll {
                    more = { [weak shell] in shell?.open(browse) }
                }
                let row = CardRow(
                    title: hub.title, style: hub.style, more: more,
                    activate: { [weak shell] item in shell?.open(item) },
                    menu: { [weak shell] item in shell.flatMap { ItemMenu.make(item, shell: $0) } }
                )
                built[hub.id] = row
                rows.append(row.root)
            }
            order = ids
        }
        for hub in hubs {
            built[hub.id]?.show(hub.items, client: client)
        }
    }
}

/// A library's Categories tab: a tile for each genre.
@MainActor
final class CategoriesView {
    let root: Widget

    init(shell: Shell, library: BaseItem) {
        let model = GenresModel(library: library)
        let tiles = FlowBox(spacing: 12).columns(min: 2, max: 8)
        tiles.valign(GTK_ALIGN_START)
        root = ScrolledWindow(tiles.margin(24)).vexpand()
        root.keep(model)
        var shown = false
        root.observe { [weak shell] in
            let genres = model.genres
            guard !genres.isEmpty, !shown, let shell else { return }
            shown = true
            for genre in genres {
                let tile = Button(genre.title, "flat", "genre-tile") { [weak shell] in shell?.open(model.browse(genre)) }
                tile.size(width: 220, height: 110).valign(GTK_ALIGN_START).css(Style.tint(for: genre.title))
                tiles.append(tile)
            }
        }
        if let client = shell.state.client {
            Task { await model.load(client) }
        }
    }
}
