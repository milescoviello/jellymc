import CGtk
import Foundation

/// Search as you type, across every library, grouped by kind.
@MainActor
final class SearchPage {
    let root: Widget
    private unowned let shell: Shell
    private let results = Box.vertical(spacing: 28)
    private var rows: [CardRow] = []
    private var shown: [String] = []

    init(shell: Shell) {
        self.shell = shell
        let model = shell.state.search
        model.client = shell.state.client
        let entry = SearchEntry(placeholder: "Films, shows, episodes, people")
        entry.text = model.query
        entry.size(width: 420).searchDelay(150)
        entry.onSearch { model.query = $0 }
        entry.onActivate {
            model.query = entry.text
            model.remember()
        }

        let empty = StatusPage(icon: "system-search-symbolic", title: "Search your library", description: "Type at least two letters.")
        // Plex's recent searches, while nothing is typed: one click searches again.
        let recentList = ListBox()
        let recentHeader = Box.horizontal(spacing: 8) {
            Label("Recent Searches", "heading")
            Spacer()
            Button("Clear", "flat") { model.clearRecent() }
        }
        let recent = Clamp(Box.vertical(spacing: 10) {
            recentHeader
            recentList
        }.margins(top: 24, bottom: 24), maximum: 560)
        let stack = Stack()
        stack.add(ScrolledWindow(results.margins(top: 20, bottom: 30)).vexpand(), name: "results")
        stack.add(empty, name: "empty")
        stack.add(ScrolledWindow(recent).vexpand(), name: "recent")
        root = ToolbarView(content: stack).top(HeaderBar().title(entry))
        root.keep(self)

        root.observe { [weak self] in
            guard let self else { return }
            let groups = model.groups
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty, !model.recent.isEmpty {
                recentList.removeAll()
                for term in model.recent {
                    recentList.append(Box.horizontal(spacing: 12) {
                        Icon("document-open-recent-symbolic")
                        Label(term).ellipsize()
                    }.margin(12)) {
                        entry.text = term
                        model.query = term
                    }
                }
                stack.visibleName = "recent"
            } else if groups.isEmpty {
                stack.visibleName = "empty"
                if model.query.count >= 2, !model.isSearching {
                    empty.title = "No results"
                    empty.descriptionText = "Nothing matches “\(model.query)”."
                } else {
                    empty.title = "Search your library"
                    empty.descriptionText = "Type at least two letters."
                }
            } else {
                stack.visibleName = "results"
                self.show(groups)
            }
        }
        Task { @MainActor in entry.grabFocus() }
    }

    private func show(_ groups: [SearchModel.Group]) {
        guard let client = shell.state.client else { return }
        let key = groups.map { $0.title + $0.items.map(\.id).joined() }
        guard key != shown else { return }
        shown = key
        results.removeAll()
        rows = groups.map { group in
            let search = shell.state.search
            let row = CardRow(
                title: group.title, style: group.style,
                activate: { [weak self] item in
                    search.remember()
                    self?.shell.open(item)
                },
                menu: { [weak self] item in self.flatMap { ItemMenu.make(item, shell: $0.shell) } }
            )
            row.show(group.items, client: client)
            results.append(row.root)
            return row
        }
    }
}
