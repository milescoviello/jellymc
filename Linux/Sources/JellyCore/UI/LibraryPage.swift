import CGtk
import Foundation

/// Everything in one library, sorted and filtered, paged in as it scrolls.
@MainActor
final class LibraryPage {
    let root: Widget
    private unowned let shell: Shell
    private let model: LibraryModel

    init(shell: Shell, library: BaseItem) {
        self.shell = shell
        model = LibraryModel(library: library)
        let model = self.model
        let grid = CardGrid(style: model.style, client: { [weak shell] in shell?.state.client }) { [weak shell] item in
            shell?.open(item)
        }
        let count = Label("", "dim-label")
        let sort = MenuButton(icon: "view-sort-descending-symbolic", "flat") {
            Menu([
                [.choice("Sort By", options: ItemQuery.Sort.allCases.map { ($0.rawValue, $0.title) }, selected: model.sort.rawValue) { id in
                    if let sort = ItemQuery.Sort(rawValue: id) { model.sort = sort }
                }],
                [.toggle("Descending", isOn: model.descending) { model.descending = $0 }],
                [.choice("Show", options: [("all", "All")] + ItemQuery.Filter.allCases.map { ($0.rawValue, $0.title) }, selected: model.filter?.rawValue ?? "all") { id in
                    model.filter = ItemQuery.Filter(rawValue: id)
                }],
            ])
        }
        sort.tooltip("Sort and filter")
        let header = HeaderBar().title(WindowTitle(library.title)).end(sort).end(count)
        let empty = StatusPage(icon: Shell.icon(for: library.collectionType), title: "Nothing to show")
        let stack = Stack()
        stack.add(grid.root, name: "grid")
        stack.add(empty, name: "empty")
        stack.add(Spinner().size(40).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER), name: "loading")
        root = ToolbarView(content: stack).top(header)
        root.keep(self)

        grid.scroller.onNearEnd { Task { await model.loadMore() } }
        root.observe {
            grid.set(model.items)
            count.text = model.total.map { "\($0) items" } ?? ""
            if model.items.isEmpty {
                stack.visibleName = model.isLoading || model.total == nil ? "loading" : "empty"
                if let error = model.error { empty.title = "Couldn’t load"; empty.descriptionText = error }
            } else {
                stack.visibleName = "grid"
            }
        }
        if let client = shell.state.client {
            Task { await model.load(client) }
        }
    }
}
