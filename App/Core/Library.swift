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

/// A library seen one way: what a row's "See All" opens, and what a library's Library,
/// Collections and genre pages page through.
struct Browse: Codable, Sendable, Equatable, Hashable {
    var title: String
    /// Nil for every library at once: collections live in their own.
    var libraryId: String?
    var itemTypes: [ItemKind]
    var sort: ItemQuery.Sort = .name
    var descending: Bool?
    var filter: ItemQuery.Filter?
    var genre: String?

    var isDescending: Bool { descending ?? sort.defaultDescending }
}

/// A row of cards with a title: Plex's hubs.
struct HomeRow: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case continueWatching, recentlyAdded, recentlyReleased, topRated, recentlyViewed
        case startWatching, rediscover, newEpisodes, genre, recommended, watchlist
    }

    var id: String
    var kind: Kind
    var title: String
    var style: CardStyle
    var items: [BaseItem]
    /// The library the row belongs to, if one.
    var libraryId: String?
    /// What "See All" opens: the library, sorted or filtered the row's way.
    var seeAll: Browse?
}

/// The kinds of item a library holds.
func libraryItemTypes(_ library: BaseItem) -> [ItemKind] {
    switch library.collectionType {
    case "movies": return [.movie]
    case "tvshows": return [.series]
    case "boxsets": return [.boxSet]
    case "playlists": return [.playlist]
    case "homevideos": return [.video]
    default: return []
    }
}

/// Plex's Home: Continue Watching, then what is new in each library.
@MainActor
@Observable
final class HomeModel {
    private(set) var rows: [HomeRow] = []
    private(set) var libraries: [BaseItem] = []
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var loaded = false
    /// Loads overlap (the player closing, a change on the server); only the newest may
    /// write, or a slow older one would put back what was there before the change.
    @ObservationIgnored private var latestLoad = 0

    private struct Snapshot: Codable {
        var rows: [HomeRow]
        var libraries: [BaseItem]
    }

    private func cacheKey(_ client: JellyfinClient) -> String { "home-v2-\(client.userId ?? "")" }

    /// Shows the cached home first, then whatever the server says now.
    func load(_ client: JellyfinClient, force: Bool = false) async {
        if !loaded, let snapshot = ResponseCache.load(Snapshot.self, key: cacheKey(client)) {
            rows = snapshot.rows
            libraries = snapshot.libraries
        }
        guard force || !loaded || rows.isEmpty else { return }
        loaded = true
        latestLoad += 1
        let load = latestLoad
        isLoading = true
        defer { if load == latestLoad { isLoading = false } }
        let started = Date()
        do {
            async let user = client.currentUser()
            let views = try await client.userViews().filter(Self.isShown)
            guard load == latestLoad else { return }
            // Written only when changed: every write redraws what shows it, and a pull to
            // refresh that changes nothing should not move anything.
            if libraries != views { libraries = views }
            async let resume = client.resume()
            async let nextUp = client.nextUp()
            async let watchlist = Hubs.watchlist(client)
            // The server's own Home settings: a library can be kept out of "Latest".
            let excluded = Set((try? await user)?.configuration?.latestItemsExcludes ?? [])
            var perLibrary: [(Int, [HomeRow])] = []
            await withTaskGroup(of: (Int, [HomeRow]).self) { group in
                for (index, view) in views.enumerated() where Self.showsLatest(view) && !excluded.contains(view.id) {
                    group.addTask { (index, await Hubs.home(for: view, client)) }
                }
                for await result in group { perLibrary.append(result) }
            }
            var rows: [HomeRow] = []
            let continuing = Hubs.continueWatching(resume: (try? await resume) ?? [], nextUp: (try? await nextUp) ?? [])
            if !continuing.isEmpty {
                rows.append(HomeRow(id: "continue", kind: .continueWatching, title: "Continue Watching", style: .landscape, items: continuing))
            }
            // Plex's Watchlist is what was marked to watch; here, the favourites not yet seen.
            if let watchlist = await watchlist { rows.append(watchlist) }
            rows += perLibrary.sorted { $0.0 < $1.0 }.flatMap(\.1)
            guard load == latestLoad else { return }
            if self.rows != rows { self.rows = rows }
            error = nil
            ResponseCache.store(Snapshot(rows: rows, libraries: views), key: cacheKey(client))
            await Diagnostics.shared.record("home", "\(rows.count) rows in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            if load == latestLoad { self.error = error.localizedDescription }
        }
    }

    func reset() {
        rows = []
        libraries = []
        loaded = false
    }

    /// Home with no server: what is on the device, in Plex's rows. Places kept offline
    /// count (the outbox's); a film is Continue Watching while part watched.
    static func offlineRows(_ downloads: [DownloadRecord]) -> [HomeRow] {
        let saved = downloads.filter(\.isDone).map { Outbox.shared.applying(to: $0.item) }
        let started = saved.filter { $0.resumeSeconds > 0 && !$0.isPlayed }
        var rows: [HomeRow] = []
        if !started.isEmpty {
            rows.append(HomeRow(id: "offline-continue", kind: .continueWatching, title: "Continue Watching", style: .landscape, items: started))
        }
        let rest = saved.filter { item in !started.contains { $0.id == item.id } }
        if !rest.isEmpty {
            rows.append(HomeRow(id: "offline-downloads", kind: .recentlyAdded, title: "Downloaded", style: .poster, items: rest))
        }
        return rows
    }

    /// The server's own Home settings for each library, as Plex's Pin to Home: whether its
    /// Recently Added row shows on Home.
    private(set) var hiddenFromHome: Set<String> = []

    func loadHomeSettings(_ client: JellyfinClient) async {
        guard let user = try? await client.currentUser() else { return }
        hiddenFromHome = Set(user.configuration?.latestItemsExcludes ?? [])
    }

    /// Shows a library's row on Home or not, on the server, so every app sees it.
    func setOnHome(_ library: BaseItem, _ shown: Bool, client: JellyfinClient) async {
        var hidden = hiddenFromHome
        if shown { hidden.remove(library.id) } else { hidden.insert(library.id) }
        guard hidden != hiddenFromHome else { return }
        do {
            try await client.updateConfiguration(["LatestItemsExcludes": Array(hidden).sorted()])
            hiddenFromHome = hidden
            await load(client, force: true)
        } catch {
            await Diagnostics.shared.record("home", "could not change Home: \(error.localizedDescription)")
        }
    }

    /// Updates an item wherever it appears after its played or favourite state changed.
    func replace(_ item: BaseItem) {
        rows = rows.map { row in
            var row = row
            row.items = row.items.map { $0.id == item.id ? item : $0 }
            return row
        }
    }

    /// Films and shows, and collections of them, and home videos: the app is for
    /// watching. Music, books, photos and Live TV libraries are left out.
    nonisolated static func isShown(_ view: BaseItem) -> Bool {
        ["movies", "tvshows", "boxsets", "playlists", "homevideos"].contains(view.collectionType)
    }

    nonisolated static func showsLatest(_ view: BaseItem) -> Bool {
        ["movies", "tvshows", "homevideos"].contains(view.collectionType)
    }
}

/// The rows Plex builds: for Home, and for each library's Recommended tab.
enum Hubs {
    /// Plex's Continue Watching is one row with one card per show: what was stopped part
    /// way, most recent first (a show's latest episode only), then the next episode of each
    /// other show going on ("On Deck").
    static func continueWatching(resume: [BaseItem], nextUp: [BaseItem]) -> [BaseItem] {
        let sorted = resume.sorted { ($0.userData?.lastPlayedDate ?? .distantPast) > ($1.userData?.lastPlayedDate ?? .distantPast) }
        var seen = Set<String>()
        let started = sorted.filter { item in
            guard let show = item.seriesId else { return true }
            return seen.insert(show).inserted
        }
        let next = nextUp.filter { item in seen.insert(item.seriesId ?? item.id).inserted }
        return started + next
    }

    /// Films and shows marked as favourites and not finished, newest marked first.
    static func watchlist(_ client: JellyfinClient) async -> HomeRow? {
        var query = ItemQuery()
        query.recursive = true
        query.includeItemTypes = [.movie, .series]
        query.filters = [.favorite]
        query.sort = .dateAdded
        query.descending = true
        query.limit = 30
        guard let items = try? await client.items(query).items.filter({ !$0.isPlayed }), !items.isEmpty else { return nil }
        return HomeRow(
            id: "watchlist", kind: .watchlist, title: "Watchlist", style: .poster, items: items,
            seeAll: Browse(title: "Watchlist", libraryId: nil, itemTypes: [.movie, .series], sort: .dateAdded, filter: .favorite)
        )
    }

    /// Home's row for one library, as Plex's Home has it: what was added. The rest is in
    /// the library's Recommended tab.
    static func home(for library: BaseItem, _ client: JellyfinClient) async -> [HomeRow] {
        guard let items = try? await client.latest(parentId: library.id), !items.isEmpty else { return [] }
        return [HomeRow(
            id: "added-\(library.id)", kind: .recentlyAdded, title: "Recently Added in \(library.title)",
            style: libraryItemTypes(library) == [.video] ? .landscape : .poster,
            items: items, libraryId: library.id,
            seeAll: Browse(title: "Recently Added", libraryId: library.id, itemTypes: libraryItemTypes(library), sort: .dateAdded)
        )]
    }

    /// A library's Recommended tab.
    static func recommended(for library: BaseItem, _ client: JellyfinClient) async -> [HomeRow] {
        library.collectionType == "tvshows" ? await shows(library, client) : await films(library, client)
    }

    private static func films(_ library: BaseItem, _ client: JellyfinClient) async -> [HomeRow] {
        let id = library.id
        async let resume = try? client.resume(parentId: id)
        async let released = released(in: library, client, title: "Recently Released")
        async let added = try? client.latest(parentId: id)
        async let picks = try? client.recommendations(parentId: id)
        async let top = query(library, client, sort: .rating, limit: 20)
        async let viewed = query(library, client, sort: .lastPlayed, filter: .played, limit: 20)
        async let rediscover = query(library, client, sort: .lastPlayed, descending: false, filter: .played, limit: 20)
        async let genres = genreRows(library, client, noun: "Movies")

        var rows: [HomeRow] = []
        rows.append(row("continue", .continueWatching, "Continue Watching", .landscape, (await resume) ?? [], library))
        if let released = await released { rows.append(released) }
        rows.append(row("added", .recentlyAdded, "Recently Added", .poster, (await added) ?? [], library,
                        Browse(title: "Recently Added", libraryId: id, itemTypes: [.movie], sort: .dateAdded)))
        for pick in ((await picks) ?? []).prefix(3) {
            guard let title = pick.title else { continue }
            rows.append(row("pick-\(pick.categoryId ?? title)", .recommended, title, .poster, pick.items ?? [], library))
        }
        rows.append(row("top", .topRated, "Top Rated", .poster, (await top)?.items ?? [], library,
                        Browse(title: "Top Rated", libraryId: id, itemTypes: [.movie], sort: .rating)))
        rows += await genres
        rows.append(row("viewed", .recentlyViewed, "Recently Viewed", .poster, (await viewed)?.items ?? [], library,
                        Browse(title: "Recently Viewed", libraryId: id, itemTypes: [.movie], sort: .lastPlayed, filter: .played)))
        // Watched longest ago: worth another look.
        rows.append(row("rediscover", .rediscover, "Rediscover", .poster, (await rediscover)?.items ?? [], library))
        return rows.filter { !$0.items.isEmpty }
    }

    private static func shows(_ library: BaseItem, _ client: JellyfinClient) async -> [HomeRow] {
        let id = library.id
        async let resume = try? client.resume(parentId: id)
        async let nextUp = try? client.nextUp(parentId: id)
        async let added = try? client.latest(parentId: id)
        async let aired = episodes(library, client)
        async let fresh = query(library, client, sort: .dateAdded, limit: 60)
        async let touched = query(library, client, sort: .lastPlayed, descending: false, limit: 100)
        async let top = query(library, client, sort: .rating, limit: 20)
        async let genres = genreRows(library, client, noun: "Shows")

        var rows: [HomeRow] = []
        let continuing = continueWatching(resume: (await resume) ?? [], nextUp: (await nextUp) ?? [])
        rows.append(row("continue", .continueWatching, "Continue Watching", .landscape, continuing, library))
        rows.append(row("added", .recentlyAdded, "Recently Added", .poster, (await added) ?? [], library,
                        Browse(title: "Recently Added", libraryId: id, itemTypes: [.series], sort: .dateAdded)))
        rows.append(row("aired", .newEpisodes, "New Episodes", .landscape, (await aired) ?? [], library))
        // Shows added and not begun.
        let unstarted = ((await fresh)?.items ?? []).filter { ($0.userData?.playedPercentage ?? 0) == 0 && !$0.isPlayed }
        rows.append(row("start", .startWatching, "Start Watching", .poster, Array(unstarted.prefix(20)), library))
        // What the show being watched now is like.
        // The server's like-this can name the show itself; that is no suggestion.
        if let show = continuing.first, let showId = show.seriesId ?? (show.type == .series ? show.id : nil),
           let alike = (try? await client.similar(to: showId, limit: 16))?.filter({ $0.id != showId }), !alike.isEmpty {
            rows.append(row("because", .recommended, "Because You Watched \(show.seriesName ?? show.title)", .poster, alike, library))
        }
        rows.append(row("top", .topRated, "Top Rated", .poster, (await top)?.items ?? [], library,
                        Browse(title: "Top Rated", libraryId: id, itemTypes: [.series], sort: .rating)))
        rows += await genres
        // Begun and left the longest.
        let lapsed = ((await touched)?.items ?? []).filter {
            let done = $0.userData?.playedPercentage ?? 0
            return done > 0 && done < 100 && !$0.isPlayed
        }
        rows.append(row("rediscover", .rediscover, "Rediscover", .poster, Array(lapsed.prefix(20)), library))
        return rows.filter { !$0.items.isEmpty }
    }

    private static func released(in library: BaseItem, _ client: JellyfinClient, title: String) async -> HomeRow? {
        var query = ItemQuery()
        query.parentId = library.id
        query.includeItemTypes = [.movie]
        query.recursive = true
        query.sort = .premiere
        query.descending = true
        query.releasedBy = Date()
        query.limit = 20
        guard let items = try? await client.items(query).items, !items.isEmpty else { return nil }
        return HomeRow(
            id: "released-\(library.id)", kind: .recentlyReleased, title: title,
            style: .poster, items: items, libraryId: library.id,
            seeAll: Browse(title: "Recently Released", libraryId: library.id, itemTypes: [.movie], sort: .premiere)
        )
    }

    /// The newest episodes to air, of every show in the library.
    private static func episodes(_ library: BaseItem, _ client: JellyfinClient) async -> [BaseItem]? {
        var query = ItemQuery()
        query.parentId = library.id
        query.includeItemTypes = [.episode]
        query.recursive = true
        query.sort = .premiere
        query.descending = true
        query.releasedBy = Date()
        query.limit = 20
        return try? await client.items(query).items
    }

    /// Two genres, a different two each time, best rated first: "Top Movies in Action".
    private static func genreRows(_ library: BaseItem, _ client: JellyfinClient, noun: String) async -> [HomeRow] {
        let types = libraryItemTypes(library)
        guard let genres = try? await client.genres(parentId: library.id, includeItemTypes: types), !genres.isEmpty else { return [] }
        // Only genres with a row's worth in them; the server counts them.
        let full = genres.filter { ($0.childCount ?? 0) >= 3 }
        var rows: [HomeRow] = []
        for genre in full.shuffled().prefix(2) {
            var query = ItemQuery()
            query.parentId = library.id
            query.includeItemTypes = types
            query.recursive = true
            query.genres = [genre.title]
            query.sort = .rating
            query.descending = true
            query.limit = 20
            guard let items = try? await client.items(query).items, items.count >= 3 else { continue }
            rows.append(row(
                "genre-\(genre.title)", .genre, "Top \(noun) in \(genre.title)", .poster, items, library,
                Browse(title: genre.title, libraryId: library.id, itemTypes: types, sort: .rating, genre: genre.title)
            ))
        }
        return rows
    }

    private static func query(
        _ library: BaseItem, _ client: JellyfinClient, sort: ItemQuery.Sort, descending: Bool = true,
        filter: ItemQuery.Filter? = nil, limit: Int
    ) async -> ItemsPage<BaseItem>? {
        var query = ItemQuery()
        query.parentId = library.id
        query.includeItemTypes = libraryItemTypes(library)
        query.recursive = true
        query.sort = sort
        query.descending = descending
        query.filters = filter.map { [$0] } ?? []
        query.limit = limit
        return try? await client.items(query)
    }

    private static func row(
        _ id: String, _ kind: HomeRow.Kind, _ title: String, _ style: CardStyle, _ items: [BaseItem], _ library: BaseItem,
        _ seeAll: Browse? = nil
    ) -> HomeRow {
        HomeRow(id: "\(id)-\(library.id)", kind: kind, title: title, style: style, items: items, libraryId: library.id, seeAll: seeAll)
    }
}

/// What plays after what: Plex's Shuffle, and a collection played through.
enum Queues {
    /// Everything after `item` in `list`: a collection's Play goes on to the next film.
    static func after(_ item: BaseItem, in list: [BaseItem]) -> [BaseItem] {
        guard let index = list.firstIndex(where: { $0.id == item.id }) else { return [] }
        return Array(list[(index + 1)...])
    }

    static func shuffle(_ list: [BaseItem]) -> [BaseItem] {
        list.shuffled()
    }
}

/// A library's Recommended tab: Plex's rows for it.
@MainActor
@Observable
final class RecommendedModel {
    let library: BaseItem
    private(set) var rows: [HomeRow] = []
    private(set) var isLoading = false
    @ObservationIgnored private var loaded = false

    init(library: BaseItem) {
        self.library = library
    }

    func load(_ client: JellyfinClient, force: Bool = false) async {
        let key = "recommended-v1-\(library.id)"
        if rows.isEmpty, let cached = ResponseCache.load([HomeRow].self, key: key) { rows = cached }
        guard force || !loaded else { return }
        loaded = true
        isLoading = true
        defer { isLoading = false }
        let started = Date()
        let fresh = await Hubs.recommended(for: library, client)
        await Diagnostics.shared.record("home", "\(library.title) recommended: \(fresh.count) rows in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        guard !fresh.isEmpty else { return }
        if rows != fresh { rows = fresh }
        ResponseCache.store(fresh, key: key)
    }
}

/// A library's Categories tab: its genres.
@MainActor
@Observable
final class GenresModel {
    let library: BaseItem
    private(set) var genres: [BaseItem] = []

    init(library: BaseItem) {
        self.library = library
    }

    func load(_ client: JellyfinClient) async {
        guard genres.isEmpty else { return }
        genres = (try? await client.genres(parentId: library.id, includeItemTypes: libraryItemTypes(library))) ?? []
    }

    func browse(_ genre: BaseItem) -> Browse {
        Browse(title: genre.title, libraryId: library.id, itemTypes: libraryItemTypes(library), sort: .name, genre: genre.title)
    }
}

/// A library, or part of one, paged as it scrolls.
@MainActor
@Observable
final class LibraryModel {
    let browse: Browse
    private(set) var items: [BaseItem] = []
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var error: String?
    var sort: ItemQuery.Sort {
        didSet { if sort != oldValue { descending = sort.defaultDescending; restart() } }
    }
    var descending: Bool {
        didSet { if descending != oldValue { restart() } }
    }
    var filter: ItemQuery.Filter? {
        didSet { if filter != oldValue { restart() } }
    }
    /// Plex's other filters: a genre, a decade, a content rating, a resolution.
    var genre: String? {
        didSet { if genre != oldValue { restart() } }
    }
    var decade: Int? {
        didSet { if decade != oldValue { restart() } }
    }
    var contentRating: String? {
        didSet { if contentRating != oldValue { restart() } }
    }
    var resolution: Resolution? {
        didSet { if resolution != oldValue { restart() } }
    }
    /// What the filters can be set to, from the server.
    private(set) var choices = LibraryFilters()
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var generation = 0

    enum Resolution: String, CaseIterable, Sendable {
        case uhd = "4K", hd = "HD", sd = "SD"
    }

    init(browse: Browse) {
        self.browse = browse
        sort = browse.sort
        descending = browse.isDescending
        filter = browse.filter
        genre = browse.genre
    }

    /// How many filters are on, for the button's badge.
    var activeFilters: Int {
        [filter != nil, genre != nil && genre != browse.genre, decade != nil, contentRating != nil, resolution != nil].filter { $0 }.count
    }

    func clearFilters() {
        filter = nil
        genre = browse.genre
        decade = nil
        contentRating = nil
        resolution = nil
    }

    /// The whole of a library, by title.
    convenience init(library: BaseItem) {
        self.init(browse: Browse(title: library.title, libraryId: library.id, itemTypes: libraryItemTypes(library)))
    }

    /// Every collection, from whichever library.
    static func collections() -> LibraryModel {
        LibraryModel(browse: Browse(title: "Collections", libraryId: nil, itemTypes: [.boxSet]))
    }

    var title: String { browse.title }

    var style: CardStyle { browse.itemTypes == [.episode] || browse.itemTypes == [.video] ? .landscape : .poster }

    var kinds: [ItemKind] { browse.itemTypes }

    var hasMore: Bool { total.map { items.count < $0 } ?? true }

    func load(_ client: JellyfinClient) async {
        self.client = client
        guard items.isEmpty else { return }
        if let cached = ResponseCache.load(ItemsPage<BaseItem>.self, key: cacheKey) {
            items = cached.items
            total = cached.totalRecordCount
        }
        let browse = browse
        let filters = Task { () -> LibraryFilters? in
            guard let id = browse.libraryId else { return nil }
            return try? await client.filters(parentId: id, includeItemTypes: browse.itemTypes)
        }
        await fetch(from: 0, replacing: true)
        if let found = await filters.value { choices = found }
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        await fetch(from: items.count, replacing: false)
    }

    /// Whether the A–Z bar means anything: titles in order.
    var isAlphabetical: Bool { sort == .name && !descending }

    /// Where the first title from `letter` on is: what the A–Z bar jumps to. "#" is the
    /// start, before A.
    func index(of letter: String) async -> Int? {
        guard let client, isAlphabetical else { return nil }
        if letter == "#" { return 0 }
        var query = baseQuery()
        query.limit = 0
        query.nameLessThan = letter
        return (try? await client.items(query))?.totalRecordCount
    }

    /// Plex's Shuffle on a library: items from all of it in a random order, the first to
    /// play and the rest queued. A show is its episodes, shuffled across the show.
    func shuffled(limit: Int = 100) async -> [BaseItem] {
        guard let client else { return [] }
        var query = baseQuery()
        query.sort = .random
        query.limit = limit
        if browse.itemTypes == [.series] { query.includeItemTypes = [.episode] }
        if browse.itemTypes == [.boxSet] || browse.itemTypes == [.playlist] { return [] }
        return (try? await client.items(query).items.filter { $0.type?.isVideo == true }) ?? []
    }

    /// Pages in until `index` is loaded, for a jump.
    func load(through index: Int) async {
        while items.count <= index, hasMore {
            let before = items.count
            await loadMore()
            if items.count == before { return }
        }
    }

    private var cacheKey: String {
        let types = browse.itemTypes.map(\.rawValue).joined(separator: ",")
        let narrowed = [genre ?? "", decade.map(String.init) ?? "", contentRating ?? "", resolution?.rawValue ?? ""].joined(separator: ",")
        return "browse-\(browse.libraryId ?? "all")-\(types)-\(narrowed)-\(sort.rawValue)-\(descending)-\(filter?.rawValue ?? "all")"
    }

    private func restart() {
        items = []
        total = nil
        Task { await fetch(from: 0, replacing: true) }
    }

    private func baseQuery() -> ItemQuery {
        var query = ItemQuery()
        query.parentId = browse.libraryId
        query.includeItemTypes = browse.itemTypes
        query.recursive = !browse.itemTypes.isEmpty
        query.genres = genre.map { [$0] } ?? []
        query.years = decade.map { Array($0 ..< $0 + 10) } ?? []
        query.officialRatings = contentRating.map { [$0] } ?? []
        switch resolution {
        case .uhd?: query.is4K = true
        case .hd?: query.is4K = false; query.isHD = true
        case .sd?: query.isHD = false
        case nil: break
        }
        query.sort = sort
        query.descending = descending
        query.filters = filter.map { [$0] } ?? []
        return query
    }

    private func fetch(from start: Int, replacing: Bool) async {
        guard let client else { return }
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        var query = baseQuery()
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

/// A film, series, season, episode, collection or person, with what its page shows:
/// Plex's pre-play screen.
@MainActor
@Observable
final class ItemModel {
    let id: String
    private(set) var item: BaseItem?
    /// A series' seasons, as a row of posters.
    private(set) var seasons: [BaseItem] = []
    /// A season's episodes.
    private(set) var episodes: [BaseItem] = []
    /// For a series: the episode the play button starts (Plex's On Deck).
    private(set) var nextEpisode: BaseItem?
    /// A collection's or folder's contents; a person's films and shows.
    private(set) var children: [BaseItem] = []
    /// Related: Plex's "More Like This".
    private(set) var similar: [BaseItem] = []
    /// Trailers and special features.
    private(set) var extras: [BaseItem] = []
    private(set) var error: String?
    @ObservationIgnored private var client: JellyfinClient?

    init(id: String, placeholder: BaseItem? = nil) {
        self.id = id
        item = placeholder
    }

    var kind: ItemKind? { item?.type }

    func load(_ client: JellyfinClient) async {
        self.client = client
        if item?.mediaSources == nil, let cached = ResponseCache.load(BaseItem.self, key: "item-\(id)") {
            item = Outbox.shared.applying(to: cached)
        }
        do {
            let item = try await client.item(id)
            self.item = Outbox.shared.applying(to: item)
            ResponseCache.store(item, key: "item-\(id)")
            error = nil
            async let related: [BaseItem]? = [.movie, .series].contains(item.type) ? try? client.similar(to: id, limit: 16) : nil
            async let extra: [BaseItem]? = (item.localTrailerCount ?? 0) + (item.specialFeatureCount ?? 0) > 0 ? try? client.extras(for: id) : nil
            switch item.type {
            case .series?:
                async let seasons = client.seasons(seriesId: id)
                async let next = client.nextUp(seriesId: id, limit: 1)
                self.seasons = (try? await seasons) ?? []
                nextEpisode = (try? await next)?.first.map(Outbox.shared.applying)
                if nextEpisode == nil, let first = self.seasons.first {
                    // All watched, or never begun: the play button starts at the beginning.
                    nextEpisode = (try? await client.episodes(seriesId: id, seasonId: first.id))?.first
                }
            case .season?:
                if let seriesId = item.seriesId {
                    episodes = ((try? await client.episodes(seriesId: seriesId, seasonId: id)) ?? []).map(Outbox.shared.applying)
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
            case .playlist?:
                children = (try? await client.playlistItems(id)) ?? []
            case .boxSet?, .folder?, .collectionFolder?:
                var query = ItemQuery()
                query.parentId = id
                query.sort = .premiere
                query.limit = 500
                children = (try? await client.items(query).items) ?? []
            default:
                break
            }
            similar = ((await related) ?? []).filter { $0.id != id }
            extras = (await extra) ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// What the big play button plays: the film or episode, a series' next episode, a
    /// season's first unwatched one.
    var playable: BaseItem? {
        guard let item else { return nil }
        if item.type == .series { return nextEpisode }
        if item.type == .season {
            // One part way through comes first, the latest touched; then the first not seen.
            let started = episodes.filter { $0.resumeSeconds > 0 }
                .max { ($0.userData?.lastPlayedDate ?? .distantPast) < ($1.userData?.lastPlayedDate ?? .distantPast) }
            return started ?? episodes.first { !$0.isPlayed } ?? episodes.first
        }
        if item.type == .boxSet {
            // The first film not yet seen, in the collection's order.
            let films = children.filter { $0.type?.isVideo == true }
            return films.first { !$0.isPlayed } ?? films.first
        }
        // A playlist plays from its top, as Plex's does.
        if item.type == .playlist { return children.first { $0.type?.isVideo == true } }
        return item.type?.isVideo == true ? item : nil
    }

    /// Whether the page has a Shuffle button: a show, a season, a collection.
    var canShuffle: Bool {
        guard let item else { return false }
        switch item.type {
        case .series?, .season?: return true
        case .boxSet?, .playlist?: return children.filter { $0.type?.isVideo == true }.count > 1
        default: return false
        }
    }

    /// Plex's Shuffle: every episode of the show or season, or every film in the
    /// collection, in a random order. The first plays; the rest are the queue.
    func shuffled() async -> [BaseItem] {
        guard let client, let item else { return [] }
        switch item.type {
        case .series?:
            return Queues.shuffle((try? await client.episodes(seriesId: item.id, seasonId: nil)) ?? [])
        case .season?:
            return Queues.shuffle(episodes)
        case .boxSet?, .playlist?:
            return Queues.shuffle(children.filter { $0.type?.isVideo == true })
        default:
            return []
        }
    }

    /// What follows the play button: the rest of a collection.
    var queueAfterPlayable: [BaseItem] {
        guard let item, item.type == .boxSet || item.type == .playlist, let playable else { return [] }
        return Queues.after(playable, in: children.filter { $0.type?.isVideo == true })
    }

    func togglePlayed() async {
        guard let client, var item else { return }
        let played = !item.isPlayed
        if let data = try? await client.setPlayed(played, itemId: item.id) {
            item.userData = data
            self.item = item
            // A show or season marked watched marks its episodes, on the server and here.
            episodes = episodes.map { episode in
                var episode = episode
                episode.userData = (episode.userData ?? UserItemData()).marked(played: played)
                return episode
            }
            seasons = seasons.map { season in
                var season = season
                season.userData = (season.userData ?? UserItemData()).marked(played: played)
                return season
            }
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
    /// What was searched for lately, newest first: shown while the field is empty.
    private(set) var recent: [String] = []
    @ObservationIgnored var client: JellyfinClient?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let recentFile: URL
    static let recentLimit = 10

    init(recentFile: URL = Paths.root.appendingPathComponent("recent-searches.json")) {
        self.recentFile = recentFile
        if let data = try? Data(contentsOf: recentFile), let saved = try? JSONDecoder().decode([String].self, from: data) {
            recent = saved
        }
    }

    /// Keeps a search (the current one unless told): when one of its results is opened,
    /// or Enter is pressed.
    func remember(_ searched: String? = nil) {
        let term = (searched ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return }
        recent.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        recent.insert(term, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        saveRecent()
    }

    func clearRecent() {
        recent = []
        saveRecent()
    }

    private func saveRecent() {
        if let data = try? JSONEncoder().encode(recent) { try? data.write(to: recentFile, options: .atomic) }
    }

    struct Group: Identifiable {
        var id: String { title }
        var title: String
        var style: CardStyle
        var items: [BaseItem]
    }

    var groups: [Group] {
        let order: [(ItemKind, String, CardStyle)] = [
            (.movie, "Movies", .poster), (.series, "Shows", .poster), (.episode, "Episodes", .landscape),
            (.video, "Videos", .landscape),
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
