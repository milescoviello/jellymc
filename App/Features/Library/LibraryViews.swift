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
        case "boxsets": return "square.stack"
        case "playlists": return "list.and.film"
        case "homevideos", "photos": return "photo.on.rectangle"
        case "livetv": return "antenna.radiowaves.left.and.right"
        default: return "folder"
        }
    }
}

/// A library, as Plex lays one out: Recommended, Library, Collections and Categories.
struct LibraryView: View {
    let library: BaseItem
    @State private var tab: Tab = .recommended

    enum Tab: String, CaseIterable, Identifiable {
        case recommended = "Recommended", library = "Library", collections = "Collections", categories = "Categories"
        var id: String { rawValue }
    }

    private var tabs: [Tab] {
        switch library.collectionType {
        case "movies": return Tab.allCases
        case "tvshows": return [.recommended, .library, .categories]
        default: return []
        }
    }

    var body: some View {
        Group {
            if tabs.isEmpty {
                BrowseGridView(model: LibraryModel(library: library))
            } else {
                VStack(spacing: 0) {
                    Picker("View", selection: $tab) {
                        ForEach(tabs) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    switch tab {
                    case .recommended: RecommendedView(library: library)
                    case .library: BrowseGridView(model: LibraryModel(library: library))
                    case .collections: BrowseGridView(model: .collections())
                    case .categories: CategoriesView(library: library)
                    }
                }
            }
        }
        .navigationTitle(library.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A library's Recommended tab.
struct RecommendedView: View {
    @Environment(AppState.self) private var state
    @State private var model: RecommendedModel

    init(library: BaseItem) {
        _model = State(initialValue: RecommendedModel(library: library))
    }

    var body: some View {
        ScrollView {
            HubList(rows: model.rows)
        }
        .overlay {
            if model.rows.isEmpty {
                if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("Nothing Here Yet", systemImage: LibrariesView.icon(for: model.library.collectionType))
                }
            }
        }
        .refreshable {
            if let client = state.client { await model.load(client, force: true) }
        }
        .task {
            if let client = state.client { await model.load(client) }
        }
        .onChange(of: state.dataGeneration) {
            Task { if let client = state.client { await model.load(client, force: true) } }
        }
    }
}

/// A library's Categories tab: a tile for each genre.
struct CategoriesView: View {
    @Environment(AppState.self) private var state
    @State private var model: GenresModel

    init(library: BaseItem) {
        _model = State(initialValue: GenresModel(library: library))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(model.genres) { genre in
                    NavigationLink(value: model.browse(genre)) {
                        Text(genre.title)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 76)
                            .padding(.horizontal, 8)
                            .background(Self.tint(genre.title), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .task {
            if let client = state.client { await model.load(client) }
        }
    }

    /// One of eight gradients for a name, the same every time; Linux uses the same eight.
    static func tint(_ name: String) -> LinearGradient {
        let pairs: [(Color, Color)] = [
            (Color(red: 0.48, green: 0.18, blue: 0.97), Color(red: 0.16, green: 0.04, blue: 0.37)),
            (Color(red: 0.90, green: 0.63, blue: 0.05), Color(red: 0.42, green: 0.27, blue: 0.00)),
            (Color(red: 0.12, green: 0.53, blue: 0.90), Color(red: 0.04, green: 0.18, blue: 0.36)),
            (Color(red: 0.85, green: 0.11, blue: 0.38), Color(red: 0.30, green: 0.03, blue: 0.13)),
            (Color(red: 0.26, green: 0.63, blue: 0.28), Color(red: 0.06, green: 0.24, blue: 0.07)),
            (Color(red: 0.96, green: 0.32, blue: 0.12), Color(red: 0.35, green: 0.10, blue: 0.02)),
            (Color(red: 0.00, green: 0.67, blue: 0.76), Color(red: 0.00, green: 0.22, blue: 0.25)),
            (Color(red: 0.55, green: 0.43, blue: 0.39), Color(red: 0.18, green: 0.13, blue: 0.11)),
        ]
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let pair = pairs[Int(hash % 8)]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// What "See All" and a genre open: one sort or filter of a library.
struct BrowsePageView: View {
    let browse: Browse

    var body: some View {
        BrowseGridView(model: LibraryModel(browse: browse))
            .navigationTitle(browse.title)
    }
}

/// A grid of a library's items, paged in as it scrolls, with Plex's sorts and filters and
/// an A–Z index down the side while sorted by title.
struct BrowseGridView: View {
    @Environment(AppState.self) private var state
    @State private var model: LibraryModel

    init(model: LibraryModel) {
        _model = State(initialValue: model)
    }

    private static let letters = ["#"] + (65 ... 90).map { String(UnicodeScalar($0)) }

    var body: some View {
        let style = model.style
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: style == .landscape ? 220 : 108), spacing: 14, alignment: .top)], spacing: 18) {
                    ForEach(model.items) { item in
                        GridCard(item: item, style: style)
                            .id(item.id)
                            .onAppear {
                                if item.id == model.items.last?.id { Task { await model.loadMore() } }
                            }
                    }
                }
                .padding()
                .padding(.trailing, model.isAlphabetical ? 14 : 0)
            }
            .overlay(alignment: .trailing) {
                if model.isAlphabetical, (model.total ?? 0) > 40 {
                    VStack(spacing: 1) {
                        ForEach(Self.letters, id: \.self) { letter in
                            Button(letter) {
                                Task {
                                    guard let index = await model.index(of: letter) else { return }
                                    await model.load(through: index)
                                    let target = model.items[min(index, max(0, model.items.count - 1))]
                                    withAnimation { proxy.scrollTo(target.id, anchor: .top) }
                                }
                            }
                            .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .overlay {
            if model.items.isEmpty {
                if model.isLoading || model.total == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView("Nothing Here", systemImage: "square.grid.2x2")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Plex's filters: watched state, genre, decade, content rating, resolution.
                Menu {
                    Picker("Show", selection: $model.filter) {
                        Text("All").tag(ItemQuery.Filter?.none)
                        ForEach(ItemQuery.Filter.allCases, id: \.self) { Text($0.title).tag(ItemQuery.Filter?.some($0)) }
                    }
                    .pickerStyle(.menu)
                    if let genres = model.choices.genres, !genres.isEmpty {
                        Picker("Genre", selection: $model.genre) {
                            Text("All").tag(String?.none)
                            ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.menu)
                    }
                    if !model.choices.decades.isEmpty {
                        Picker("Decade", selection: $model.decade) {
                            Text("All").tag(Int?.none)
                            ForEach(model.choices.decades, id: \.self) { Text("\(String($0))s").tag(Int?.some($0)) }
                        }
                        .pickerStyle(.menu)
                    }
                    if let ratings = model.choices.officialRatings, !ratings.isEmpty {
                        Picker("Content Rating", selection: $model.contentRating) {
                            Text("All").tag(String?.none)
                            ForEach(ratings, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.menu)
                    }
                    Picker("Resolution", selection: $model.resolution) {
                        Text("All").tag(LibraryModel.Resolution?.none)
                        ForEach(LibraryModel.Resolution.allCases, id: \.self) { Text($0.rawValue).tag(LibraryModel.Resolution?.some($0)) }
                    }
                    .pickerStyle(.menu)
                    if model.activeFilters > 0 {
                        Button("Clear Filters", role: .destructive) { model.clearFilters() }
                    }
                } label: {
                    Image(systemName: model.activeFilters > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(ItemQuery.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Descending", isOn: $model.descending)
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
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
            CardLink(item: item, style: style, width: proxy.size.width)
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
                    ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass", description: Text("Films, shows, episodes and people."))
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $search.query, prompt: "Films, shows, people")
        .onAppear { search.client = state.client }
    }
}
