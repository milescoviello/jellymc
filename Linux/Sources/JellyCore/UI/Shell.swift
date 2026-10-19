import CGtk
import Foundation

/// Signed in: a sidebar of places, and the pages they open.
@MainActor
final class Shell {
    let root: Widget
    unowned let window: MainWindow
    private let content = NavigationView()
    private let places = ListBox(boxed: false)
    private let split: NavigationSplitView
    private var placeIds: [String] = []
    private var current: String?
    private var home: HomePage?

    var state: AppState { window.state }

    init(window: MainWindow) {
        self.window = window
        places.css("navigation-sidebar")

        let title = WindowTitle("jellymc", subtitle: window.state.serverName)
        let sidebar = ToolbarView(content: ScrolledWindow(places))
            .top(HeaderBar().title(title))
        let banner = Banner("Server unreachable — showing what was saved", button: "Retry") {
            Task { await window.state.reconnect() }
        }
        let contentPage = NavigationPage(ToolbarView(content: content).top(banner), title: "Home")
        split = NavigationSplitView(
            sidebar: NavigationPage(sidebar, title: "jellymc"),
            content: contentPage
        ).sidebarWidth(min: 200, max: 260, fraction: 0.2)
        root = split
        root.keep(self)

        root.observe { [weak self] in
            guard let self else { return }
            title.subtitle = self.state.serverName
            banner.isRevealed = self.state.isOffline
            self.buildPlaces(self.state.home.libraries)
        }
        select("home")
        if let client = state.client {
            Task { await state.home.load(client) }
        }
    }

    // MARK: - Places

    private func buildPlaces(_ libraries: [BaseItem]) {
        let ids = ["home", "search"] + libraries.map(\.id) + ["downloads", "settings"]
        guard ids != placeIds else { return }
        placeIds = ids
        places.removeAll()
        func row(_ title: String, _ icon: String, _ id: String) {
            places.append(Box.horizontal(spacing: 12) {
                Icon(icon)
                Label(title)
            }.margin(horizontal: 6, vertical: 8)) { [weak self] in self?.select(id) }
        }
        row("Home", "go-home-symbolic", "home")
        row("Search", "system-search-symbolic", "search")
        for library in libraries {
            row(library.title, Self.icon(for: library.collectionType), library.id)
        }
        row("Downloads", "folder-download-symbolic", "downloads")
        row("Settings", "emblem-system-symbolic", "settings")
    }

    static func icon(for collectionType: String?) -> String {
        switch collectionType {
        case "movies": return "camera-video-symbolic"
        case "tvshows": return "video-display-symbolic"
        case "boxsets": return "view-grid-symbolic"
        case "homevideos", "photos": return "image-x-generic-symbolic"
        case "livetv": return "network-wireless-symbolic"
        default: return "folder-symbolic"
        }
    }

    func select(_ id: String) {
        current = id
        let page: NavigationPage
        switch id {
        case "home":
            let home = HomePage(shell: self)
            self.home = home
            page = NavigationPage(home.root, title: "Home", tag: "home")
        case "search":
            page = NavigationPage(SearchPage(shell: self).root, title: "Search", tag: "search")
        case "downloads":
            page = NavigationPage(DownloadsPage(shell: self).root, title: "Downloads", tag: "downloads")
        case "settings":
            page = NavigationPage(SettingsPage(shell: self).root, title: "Settings", tag: "settings")
        default:
            guard let library = state.home.libraries.first(where: { $0.id == id }) else { return }
            page = NavigationPage(LibraryPage(shell: self, library: library).root, title: library.title)
        }
        content.replace(with: page)
        split.showsContent = true
    }

    // MARK: - Navigation

    func open(_ item: BaseItem) {
        switch item.type {
        case .episode?, .movie?, .video?, .trailer?, .series?, .season?, .boxSet?, .folder?, .person?:
            content.push(NavigationPage(ItemPage(shell: self, item: item).root, title: item.title))
        case .collectionFolder?, .userView?:
            content.push(NavigationPage(LibraryPage(shell: self, library: item).root, title: item.title))
        default:
            if item.type?.isVideo == true { window.play(item) } else {
                content.push(NavigationPage(ItemPage(shell: self, item: item).root, title: item.title))
            }
        }
    }

    /// A row's "See All", or a genre: one sort or filter of a library.
    func open(_ browse: Browse) {
        content.push(NavigationPage(BrowsePage(shell: self, browse: browse).root, title: browse.title))
    }

    func openLibrary(_ id: String) {
        select(id)
    }

    /// After playback: the home rows and the page on top may show stale progress.
    func refreshVisible() {
        if current == "home" { home?.refresh() }
    }
}
