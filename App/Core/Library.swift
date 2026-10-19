import Foundation
import Observation

// The state each screen shows, shared by the SwiftUI and the GTK screens: what to fetch,
// how to page, what to keep while refreshing. Views read these and call their methods;
// nothing here knows which toolkit draws it.

/// How a row of cards is drawn.
enum CardStyle: String, Codable, Sendable {
    /// 2:3 posters: films, series.
    case poster
    /// 16:9 stills: episodes, continue watching.
    case landscape
}

struct HomeRow: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case resume, nextUp, latest
    }

    var id: String
    var kind: Kind
    var title: String
    var style: CardStyle
    var items: [BaseItem]
    /// For "Latest in …": the library to open from the row's header.
    var libraryId: String?
}

@MainActor
@Observable
final class HomeModel {
    private(set) var rows: [HomeRow] = []
    private(set) var libraries: [BaseItem] = []
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var loaded = false

    private struct Snapshot: Codable {
        var rows: [HomeRow]
        var libraries: [BaseItem]
    }

    /// Shows the cached home first, then whatever the server says now.
    func load(_ client: JellyfinClient, force: Bool = false) async {
        if !loaded, let snapshot = ResponseCache.load(Snapshot.self, key: "home-\(client.userId ?? "")") {
            rows = snapshot.rows
            libraries = snapshot.libraries
        }
        guard force || !loaded || rows.isEmpty else { return }
        loaded = true
        isLoading = true
        defer { isLoading = false }
        do {
            let views = try await client.userViews().filter(Self.isShown)
            libraries = views
            async let resume = client.resume()
            async let nextUp = client.nextUp()
            var latest: [(BaseItem, [BaseItem])] = []
            await withTaskGroup(of: (Int, BaseItem, [BaseItem]).self) { group in
                for (index, view) in views.enumerated() where Self.showsLatest(view) {
                    group.addTask { (index, view, (try? await client.latest(parentId: view.id)) ?? []) }
                }
                var results: [(Int, BaseItem, [BaseItem])] = []
                for await result in group { results.append(result) }
                latest = results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
            }
            var rows: [HomeRow] = []
            let resumeItems = (try? await resume) ?? []
            if !resumeItems.isEmpty {
                rows.append(HomeRow(id: "resume", kind: .resume, title: "Continue Watching", style: .landscape, items: resumeItems))
            }
            let nextItems = ((try? await nextUp) ?? []).filter { next in !resumeItems.contains { $0.id == next.id } }
            if !nextItems.isEmpty {
                rows.append(HomeRow(id: "nextup", kind: .nextUp, title: "Next Up", style: .landscape, items: nextItems))
            }
            for (view, items) in latest where !items.isEmpty {
                rows.append(HomeRow(
                    id: "latest-\(view.id)", kind: .latest, title: "Latest \(view.title)",
                    style: .poster, items: items, libraryId: view.id
                ))
            }
            self.rows = rows
            error = nil
            ResponseCache.store(Snapshot(rows: rows, libraries: views), key: "home-\(client.userId ?? "")")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reset() {
        rows = []
        libraries = []
        loaded = false
    }

    /// Updates an item wherever it appears after its played or favourite state changed.
    func replace(_ item: BaseItem) {
        rows = rows.map { row in
            var row = row
            row.items = row.items.map { $0.id == item.id ? item : $0 }
            return row
        }
    }

    /// Films and shows, and collections of them: the app is for watching. Music, books,
    /// photos and Live TV libraries are left out.
    nonisolated static func isShown(_ view: BaseItem) -> Bool {
        ["movies", "tvshows", "boxsets"].contains(view.collectionType)
    }

    static func showsLatest(_ view: BaseItem) -> Bool {
        ["movies", "tvshows"].contains(view.collectionType)
    }
}

/// One library, paged as it scrolls.
@MainActor
@Observable
final class LibraryModel {
    let library: BaseItem
    private(set) var items: [BaseItem] = []
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var error: String?
    var sort: ItemQuery.Sort {
        didSet { if sort != oldValue { descending = sort.defaultDescending; restart() } }
    }
    var descending: Bool = false {
        didSet { if descending != oldValue { restart() } }
    }
    var filter: ItemQuery.Filter? {
        didSet { if filter != oldValue { restart() } }
    }
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var generation = 0

    init(library: BaseItem) {
        self.library = library
        sort = .name
    }

    var style: CardStyle { .poster }

    var kinds: [ItemKind] {
        switch library.collectionType {
        case "movies": return [.movie]
        case "tvshows": return [.series]
        case "boxsets": return [.boxSet]
        default: return []
        }
    }

    var hasMore: Bool { total.map { items.count < $0 } ?? true }

    func load(_ client: JellyfinClient) async {
        self.client = client
        guard items.isEmpty else { return }
        if let cached = ResponseCache.load(ItemsPage<BaseItem>.self, key: cacheKey) {
            items = cached.items
            total = cached.totalRecordCount
        }
        await fetch(from: 0, replacing: true)
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        await fetch(from: items.count, replacing: false)
    }

    private var cacheKey: String { "library-\(library.id)-\(sort.rawValue)-\(descending)-\(filter?.rawValue ?? "all")" }

    private func restart() {
        items = []
        total = nil
        Task { await fetch(from: 0, replacing: true) }
    }

    private func fetch(from start: Int, replacing: Bool) async {
        guard let client else { return }
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        var query = ItemQuery()
        query.parentId = library.id
        query.includeItemTypes = kinds
        query.recursive = !kinds.isEmpty
        query.sort = sort
        query.descending = descending
        query.filters = filter.map { [$0] } ?? []
        query.startIndex = start
        query.limit = 120
        do {
            let page = try await client.items(query)
            guard mine == generation else { return }
            items = replacing ? page.items : items + page.items
            total = page.totalRecordCount
            error = nil
            if start == 0 { ResponseCache.store(page, key: cacheKey) }
        } catch {
            if mine == generation { self.error = error.localizedDescription }
        }
    }
}

/// A film, series, season, episode, collection or person, with what its page shows.
@MainActor
@Observable
final class ItemModel {
    let id: String
    private(set) var item: BaseItem?
    private(set) var seasons: [BaseItem] = []
    private(set) var episodes: [BaseItem] = []
    /// For a series: the episode the play button starts.
    private(set) var nextEpisode: BaseItem?
    /// A collection's or folder's contents; a person's films and shows.
    private(set) var children: [BaseItem] = []
    private(set) var similar: [BaseItem] = []
    private(set) var error: String?
    var selectedSeasonId: String? {
        didSet { if selectedSeasonId != oldValue { Task { await loadEpisodes() } } }
    }
    @ObservationIgnored private var client: JellyfinClient?

    init(id: String, placeholder: BaseItem? = nil) {
        self.id = id
        item = placeholder
    }

    var kind: ItemKind? { item?.type }

    func load(_ client: JellyfinClient) async {
        self.client = client
        if item?.mediaSources == nil, let cached = ResponseCache.load(BaseItem.self, key: "item-\(id)") {
            item = cached
        }
        do {
            let item = try await client.item(id)
            self.item = item
            ResponseCache.store(item, key: "item-\(id)")
            error = nil
            switch item.type {
            case .series?:
                async let seasons = client.seasons(seriesId: id)
                async let next = client.nextUp(seriesId: id, limit: 1)
                self.seasons = (try? await seasons) ?? []
                nextEpisode = (try? await next)?.first
                if selectedSeasonId == nil {
                    selectedSeasonId = nextEpisode?.seasonId ?? self.seasons.first?.id
                } else {
                    await loadEpisodes()
                }
            case .season?:
                if let seriesId = item.seriesId {
                    episodes = (try? await client.episodes(seriesId: seriesId, seasonId: id)) ?? []
                }
            case .person?:
                var query = ItemQuery()
                query.recursive = true
                query.sort = .premiere
                query.descending = true
                query.limit = 300
                query.personIds = [id]
                query.includeItemTypes = [.movie, .series]
                children = (try? await client.items(query).items) ?? []
            case .boxSet?, .folder?, .collectionFolder?:
                var query = ItemQuery()
                query.parentId = id
                query.sort = .premiere
                query.limit = 500
                children = (try? await client.items(query).items) ?? []
            default:
                break
            }
            if [.movie, .series].contains(item.type) {
                similar = (try? await client.similar(to: id)) ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let client, let seasonId = selectedSeasonId else { return }
        episodes = (try? await client.episodes(seriesId: id, seasonId: seasonId)) ?? []
    }

    /// What the big play button plays: the film, or for a series the next episode.
    var playable: BaseItem? {
        guard let item else { return nil }
        if item.type == .series { return nextEpisode ?? episodes.first }
        if item.type == .season { return episodes.first { !$0.isPlayed } ?? episodes.first }
        return item.type?.isVideo == true ? item : nil
    }

    func togglePlayed() async {
        guard let client, var item else { return }
        let played = !item.isPlayed
        if let data = try? await client.setPlayed(played, itemId: item.id) {
            item.userData = data
            self.item = item
        }
    }

    func toggleFavorite() async {
        guard let client, var item else { return }
        if let data = try? await client.setFavorite(!item.isFavorite, itemId: item.id) {
            item.userData = data
            self.item = item
        }
    }

    func setEpisodePlayed(_ episode: BaseItem, _ played: Bool) async {
        guard let client, let data = try? await client.setPlayed(played, itemId: episode.id) else { return }
        episodes = episodes.map { item in
            guard item.id == episode.id else { return item }
            var item = item
            item.userData = data
            return item
        }
    }
}

/// Search as you type, grouped by kind.
@MainActor
@Observable
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    private(set) var results: [BaseItem] = []
    private(set) var isSearching = false
    @ObservationIgnored var client: JellyfinClient?
    @ObservationIgnored private var task: Task<Void, Never>?

    struct Group: Identifiable {
        var id: String { title }
        var title: String
        var style: CardStyle
        var items: [BaseItem]
    }

    var groups: [Group] {
        let order: [(ItemKind, String, CardStyle)] = [
            (.movie, "Movies", .poster), (.series, "Shows", .poster), (.episode, "Episodes", .landscape),
            (.boxSet, "Collections", .poster), (.person, "People", .poster),
        ]
        return order.compactMap { kind, title, style in
            let items = results.filter { $0.type == kind }
            return items.isEmpty ? nil : Group(title: title, style: style, items: items)
        }
    }

    private func schedule() {
        task?.cancel()
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2, let client else {
            results = []
            return
        }
        task = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = (try? await client.search(term)) ?? []
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}
