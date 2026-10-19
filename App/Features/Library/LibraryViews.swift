import SwiftUI

/// Every library the server shares.
struct LibrariesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List(state.home.libraries) { library in
            NavigationLink(value: LibraryRoute(library: library)) {
                Label(library.title, systemImage: Self.icon(for: library.collectionType))
            }
        }
        .navigationTitle("Libraries")
        .overlay {
            if state.home.libraries.isEmpty, !state.home.isLoading {
                ContentUnavailableView("No Libraries", systemImage: "square.grid.2x2")
            }
        }
        .task {
            if let client = state.client { await state.home.load(client) }
        }
    }

    static func icon(for collectionType: String?) -> String {
        switch collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "boxsets": return "square.stack"
        case "playlists": return "music.note.list"
        case "homevideos", "photos": return "photo.on.rectangle"
        case "livetv": return "antenna.radiowaves.left.and.right"
        default: return "folder"
        }
    }
}

/// Everything in one library, sorted and filtered, paged in as it scrolls.
struct LibraryGridView: View {
    @Environment(AppState.self) private var state
    @State private var model: LibraryModel

    init(library: BaseItem) {
        _model = State(initialValue: LibraryModel(library: library))
    }

    var body: some View {
        let style = model.style
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: style == .landscape ? 220 : 112), spacing: 14, alignment: .top)], spacing: 18) {
                ForEach(model.items) { item in
                    NavigationLink(value: ItemRoute(item: item)) {
                        GridCard(item: item, style: style)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == model.items.last?.id { Task { await model.loadMore() } }
                    }
                }
            }
            .padding()
        }
        .overlay {
            if model.items.isEmpty {
                if model.isLoading || model.total == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView("Nothing to Show", systemImage: LibrariesView.icon(for: model.library.collectionType))
                }
            }
        }
        .navigationTitle(model.library.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(ItemQuery.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Descending", isOn: $model.descending)
                    Picker("Show", selection: $model.filter) {
                        Text("All").tag(ItemQuery.Filter?.none)
                        ForEach(ItemQuery.Filter.allCases, id: \.self) { Text($0.title).tag(ItemQuery.Filter?.some($0)) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task {
            if let client = state.client { await model.load(client) }
        }
    }
}

/// A card that takes the width its grid column gives it.
private struct GridCard: View {
    let item: BaseItem
    let style: CardStyle

    var body: some View {
        GeometryReader { proxy in
            CardView(item: item, style: style, width: proxy.size.width)
        }
        .aspectRatio(style.aspect * 0.78, contentMode: .fit)
    }
}

/// Search as you type, across every library.
struct SearchView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var search = state.search
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(search.groups) { group in
                    CardRowView(title: group.title, style: group.style, items: group.items)
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if search.groups.isEmpty {
                if search.isSearching {
                    ProgressView()
                } else if search.query.count >= 2 {
                    ContentUnavailableView.search(text: search.query)
                } else {
                    ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass", description: Text("Films, shows, episodes, people and music."))
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $search.query, prompt: "Films, shows, people, music")
        .onAppear { search.client = state.client }
    }
}
