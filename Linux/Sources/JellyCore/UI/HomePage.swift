import CGtk
import Foundation

/// Continue Watching, Next Up, and the newest in each library.
@MainActor
final class HomePage {
    let root: Widget
    private unowned let shell: Shell
    private let rows = Box.vertical(spacing: 30)
    private var built: [String: CardRow] = [:]
    private var order: [String] = []

    init(shell: Shell) {
        self.shell = shell
        let empty = StatusPage(icon: "video-display-symbolic", title: "Nothing here yet", description: "Libraries the server shares with you show up here.")
        let stack = Stack()
        stack.add(Spinner().size(40).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER), name: "loading")
        stack.add(ScrolledWindow(rows.margins(top: 20, bottom: 30)).vexpand(), name: "rows")
        stack.add(empty, name: "empty")
        root = stack
        root.keep(self)

        let model = shell.state.home
        root.observe { [weak self] in
            guard let self else { return }
            let rows = model.rows
            if rows.isEmpty {
                stack.visibleName = model.isLoading ? "loading" : (model.error.map { _ in "empty" } ?? (model.libraries.isEmpty ? "loading" : "empty"))
                if let error = model.error { empty.title = "Couldn’t load"; empty.descriptionText = error }
            } else {
                stack.visibleName = "rows"
                self.show(rows)
            }
        }
    }

    func refresh() {
        guard let client = shell.state.client else { return }
        Task { await shell.state.home.load(client, force: true) }
    }

    private func show(_ homeRows: [HomeRow]) {
        guard let client = shell.state.client else { return }
        let ids = homeRows.map(\.id)
        if ids != order {
            // Removing a row from the box destroys its widgets — handles do not own them —
            // so a new order gets new rows rather than the old ones re-added.
            rows.removeAll()
            built = [:]
            for row in homeRows {
                var more: (@MainActor () -> Void)?
                if let id = row.libraryId {
                    more = { [weak self] in self?.shell.openLibrary(id) }
                }
                let kind = row.kind
                let card = CardRow(
                    title: row.title, style: row.style, more: more,
                    activate: { [weak self] item in self?.activate(item, from: kind) }
                )
                built[row.id] = card
                rows.append(card.root)
            }
            order = ids
        }
        for row in homeRows {
            built[row.id]?.show(row.items, client: client)
        }
    }

    /// Continue Watching and Next Up play straight away; anything else opens its page.
    private func activate(_ item: BaseItem, from kind: HomeRow.Kind) {
        switch kind {
        case .resume, .nextUp:
            shell.window.play(item)
        case .latest:
            shell.open(item)
        }
    }
}
