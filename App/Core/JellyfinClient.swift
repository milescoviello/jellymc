import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Who this app is to the server: the `Client`, `Device`, `DeviceId` and `Version` of every
/// request's `Authorization` header, and what the server's dashboard lists it as.
struct DeviceIdentity: Sendable, Equatable {
    var client = "jellymc"
    var deviceName: String
    var deviceId: String
    var version: String
}

struct JellyfinError: Error, LocalizedError, Sendable {
    enum Kind: Sendable, Equatable {
        case http(Int)
        case notJellyfin
        case decoding
        case badURL
        case transport
    }

    var kind: Kind
    var message: String

    var errorDescription: String? { message }

    var isUnauthorized: Bool { kind == .http(401) }
}

/// The Jellyfin HTTP API, typed for what the app uses.
///
/// Immutable: signing in returns a new client carrying the token. Every request sends
/// `Authorization: MediaBrowser …`, and every URL handed to a player carries `ApiKey=`;
/// 12.0 refuses the legacy `X-Emby-Token` and `api_key` forms, so neither appears here.
final class JellyfinClient: Sendable {
    let baseURL: URL
    let device: DeviceIdentity
    let token: String?
    let userId: String?
    private let session: URLSession

    init(baseURL: URL, device: DeviceIdentity, token: String? = nil, userId: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.device = device
        self.token = token
        self.userId = userId
        self.session = session
    }

    func signedIn(token: String, userId: String) -> JellyfinClient {
        JellyfinClient(baseURL: baseURL, device: device, token: token, userId: userId, session: session)
    }

    /// The header every request carries. Quotes inside a value would end it early, so
    /// they become apostrophes.
    var authorization: String {
        func value(_ string: String) -> String { string.replacingOccurrences(of: "\"", with: "'") }
        var parts = [
            "Client=\"\(value(device.client))\"",
            "Device=\"\(value(device.deviceName))\"",
            "DeviceId=\"\(value(device.deviceId))\"",
            "Version=\"\(value(device.version))\"",
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    /// The addresses worth trying for what a person typed, best guess first.
    ///
    /// A full URL is taken as given. Without a scheme, a LAN address or a bare name is most
    /// likely a fresh install on plain HTTP and port 8096; a domain is most likely behind a
    /// reverse proxy on HTTPS — so both are tried, in that order of likelihood.
    static func candidates(for text: String) -> [URL] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains("://") {
            return URL(string: trimmed).flatMap { $0.host == nil ? nil : [$0] } ?? []
        }
        guard let parsed = URLComponents(string: "http://" + trimmed), let host = parsed.host, !host.isEmpty else { return [] }
        let isAddress = host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" } || !host.contains(".") || host.hasSuffix(".local")
        func url(_ scheme: String, port: Int?) -> URL? {
            var components = parsed
            components.scheme = scheme
            if parsed.port == nil { components.port = port }
            return components.url
        }
        let plain = url("http", port: 8096)
        let secure = url("https", port: nil)
        if parsed.port != nil { return [url("http", port: nil), url("https", port: nil)].compactMap { $0 } }
        return (isAddress ? [plain, secure] : [secure, plain]).compactMap { $0 }
    }

    // MARK: - System and sign-in

    func publicInfo() async throws -> PublicSystemInfo {
        let info: PublicSystemInfo = try await get("System/Info/Public", timeout: 8)
        guard info.version != nil, info.id != nil else {
            throw JellyfinError(kind: .notJellyfin, message: "That address answered, but not as a Jellyfin server.")
        }
        return info
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        struct Body: Encodable { let username: String; let pw: String }
        return try await send("POST", "Users/AuthenticateByName", body: Body(username: username, pw: password))
    }

    func currentUser() async throws -> User {
        try await get("Users/Me")
    }

    func logout() async {
        try? await sendNoContent("POST", "Sessions/Logout")
    }

    /// Tells the server what this client can be asked to do, so other clients can send it
    /// media and commands, and the dashboard shows it as controllable.
    func registerCapabilities(playableMediaTypes: [String], commands: [String]) async {
        struct Body: Encodable {
            let playableMediaTypes: [String]
            let supportedCommands: [String]
            let supportsMediaControl: Bool
            let supportsPersistentIdentifier: Bool
        }
        try? await sendNoContent(
            "POST",
            "Sessions/Capabilities/Full",
            body: Body(playableMediaTypes: playableMediaTypes, supportedCommands: commands, supportsMediaControl: true, supportsPersistentIdentifier: true)
        )
    }

    // MARK: - Browsing

    static let listFields = "PrimaryImageAspectRatio,Overview,ChildCount,RecursiveItemCount"
    static let detailFields = "Overview,Genres,People,Studios,Taglines,MediaSources,MediaStreams,Chapters,Trickplay,RemoteTrailers,PrimaryImageAspectRatio,ChildCount,RecursiveItemCount,ProductionLocations"
    static let imageTypes = "Primary,Backdrop,Thumb,Logo"

    func userViews() async throws -> [BaseItem] {
        let page: ItemsPage<BaseItem> = try await get("UserViews", query: userQuery())
        return page.items
    }

    func resume(limit: Int = 24, mediaTypes: String = "Video") async throws -> [BaseItem] {
        let page: ItemsPage<BaseItem> = try await get("UserItems/Resume", query: userQuery([
            "limit": String(limit), "mediaTypes": mediaTypes, "fields": Self.listFields,
            "enableImageTypes": Self.imageTypes, "imageTypeLimit": "1",
        ]))
        return page.items
    }

    func nextUp(seriesId: String? = nil, limit: Int = 24) async throws -> [BaseItem] {
        var query = userQuery([
            "limit": String(limit), "fields": Self.listFields, "enableImageTypes": Self.imageTypes,
            "imageTypeLimit": "1", "enableResumable": "false", "enableRewatching": "false",
        ])
        if let seriesId { query["seriesId"] = seriesId }
        let page: ItemsPage<BaseItem> = try await get("Shows/NextUp", query: query)
        return page.items
    }

    func latest(parentId: String, limit: Int = 20) async throws -> [BaseItem] {
        try await get("Items/Latest", query: userQuery([
            "parentId": parentId, "limit": String(limit), "fields": Self.listFields,
            "enableImageTypes": Self.imageTypes, "imageTypeLimit": "1",
        ]))
    }

    func items(_ query: ItemQuery) async throws -> ItemsPage<BaseItem> {
        try await get("Items", query: userQuery(query.parameters))
    }

    func item(_ id: String) async throws -> BaseItem {
        try await get("Items/\(id)", query: userQuery(["fields": Self.detailFields]))
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let page: ItemsPage<BaseItem> = try await get("Shows/\(seriesId)/Seasons", query: userQuery([
            "fields": Self.listFields, "enableImageTypes": Self.imageTypes,
        ]))
        return page.items
    }

    func episodes(seriesId: String, seasonId: String?) async throws -> [BaseItem] {
        var query = userQuery([
            "fields": Self.listFields + ",MediaSources", "enableImageTypes": Self.imageTypes,
        ])
        if let seasonId { query["seasonId"] = seasonId }
        let page: ItemsPage<BaseItem> = try await get("Shows/\(seriesId)/Episodes", query: query)
        return page.items
    }

    func similar(to id: String, limit: Int = 12) async throws -> [BaseItem] {
        let page: ItemsPage<BaseItem> = try await get("Items/\(id)/Similar", query: userQuery([
            "limit": String(limit), "fields": Self.listFields,
        ]))
        return page.items
    }

    func search(_ term: String, limit: Int = 60) async throws -> [BaseItem] {
        var query = ItemQuery()
        query.searchTerm = term
        query.recursive = true
        query.limit = limit
        query.includeItemTypes = [.movie, .series, .episode, .boxSet, .person]
        return try await items(query).items
    }

    // MARK: - User data

    func setPlayed(_ played: Bool, itemId: String) async throws -> UserItemData {
        try await send(played ? "POST" : "DELETE", "UserPlayedItems/\(itemId)", query: userQuery())
    }

    func setFavorite(_ favorite: Bool, itemId: String) async throws -> UserItemData {
        try await send(favorite ? "POST" : "DELETE", "UserFavoriteItems/\(itemId)", query: userQuery())
    }

    /// Writes a position directly, for progress made while offline.
    func setPosition(_ seconds: Double, played: Bool?, lastPlayed: Date, itemId: String) async throws {
        struct Body: Encodable {
            let playbackPositionTicks: Int64
            let played: Bool?
            let lastPlayedDate: Date
        }
        try await sendNoContent(
            "POST", "UserItems/\(itemId)/UserData", query: userQuery(),
            body: Body(playbackPositionTicks: Ticks.from(seconds: seconds), played: played, lastPlayedDate: lastPlayed)
        )
    }

    // MARK: - Playback

    func playbackInfo(itemId: String, request: PlaybackInfoRequest) async throws -> PlaybackInfoResponse {
        try await send("POST", "Items/\(itemId)/PlaybackInfo", query: userQuery(), body: request)
    }

    func reportStart(_ report: PlaybackReport) async {
        try? await sendNoContent("POST", "Sessions/Playing", body: report)
    }

    func reportProgress(_ report: PlaybackReport) async {
        try? await sendNoContent("POST", "Sessions/Playing/Progress", body: report)
    }

    func reportStopped(_ report: PlaybackReport) async {
        try? await sendNoContent("POST", "Sessions/Playing/Stopped", body: report)
    }

    func ping(playSessionId: String) async {
        try? await sendNoContent("POST", "Sessions/Playing/Ping", query: ["playSessionId": playSessionId])
    }

    func mediaSegments(itemId: String) async throws -> [MediaSegment] {
        let page: ItemsPage<MediaSegment> = try await get("MediaSegments/\(itemId)")
        return page.items
    }

    func sendLog(_ text: String) async throws {
        var request = try makeRequest("POST", "ClientLog/Document", query: [:])
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(text.utf8)
        _ = try await perform(request)
    }

    // MARK: - URLs for players and images

    /// A URL relative to the server, with the token as `ApiKey` so a player that knows
    /// nothing of headers can open it.
    func authorizedURL(_ path: String) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(string: baseURL.absoluteString + "/" + trimmed) else { return nil }
        var items = components.queryItems ?? []
        if let token, !items.contains(where: { $0.name.lowercased() == "apikey" || $0.name.lowercased() == "api_key" }) {
            items.append(URLQueryItem(name: "ApiKey", value: token))
        }
        // The legacy spelling is refused by 12.0 when legacy authorization is off.
        items = items.map { $0.name.lowercased() == "api_key" ? URLQueryItem(name: "ApiKey", value: $0.value) : $0 }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    func directStreamURL(itemId: String, mediaSourceId: String, playSessionId: String?, tag: String?) -> URL? {
        var query = "static=true&mediaSourceId=\(mediaSourceId)"
        if let playSessionId { query += "&playSessionId=\(playSessionId)" }
        if let tag { query += "&Tag=\(tag)" }
        return authorizedURL("Videos/\(itemId)/stream?\(query)")
    }

    func imageURL(itemId: String, type: String = "Primary", tag: String?, maxWidth: Int, index: Int? = nil) -> URL? {
        var path = "Items/\(itemId)/Images/\(type)"
        if let index { path += "/\(index)" }
        var components = URLComponents(string: baseURL.absoluteString + "/" + path)
        var items = [URLQueryItem(name: "maxWidth", value: String(maxWidth)), URLQueryItem(name: "quality", value: "90")]
        if let tag { items.append(URLQueryItem(name: "tag", value: tag)) }
        components?.queryItems = items
        return components?.url
    }

    func userImageURL(userId: String, tag: String?, maxWidth: Int) -> URL? {
        var components = URLComponents(string: baseURL.absoluteString + "/Users/\(userId)/Images/Primary")
        var items = [URLQueryItem(name: "maxWidth", value: String(maxWidth))]
        if let tag { items.append(URLQueryItem(name: "tag", value: tag)) }
        components?.queryItems = items
        return components?.url
    }

    func trickplayTileURL(itemId: String, width: Int, index: Int, mediaSourceId: String) -> URL? {
        authorizedURL("Videos/\(itemId)/Trickplay/\(width)/\(index).jpg?mediaSourceId=\(mediaSourceId)")
    }

    // MARK: - Plumbing

    func userQuery(_ extra: [String: String] = [:]) -> [String: String] {
        var query = extra
        if let userId { query["userId"] = userId }
        return query
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String], timeout: TimeInterval = 30) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL.absoluteString + "/" + path) else {
            throw JellyfinError(kind: .badURL, message: "Not a usable server address.")
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw JellyfinError(kind: .badURL, message: "Not a usable server address.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            #if canImport(FoundationNetworking)
            // Linux's URLSession crashes when a task that has just failed is cancelled
            // ("a task that in not in the registry"), and cancelling the Swift task that
            // awaits it cancels it: an `async let` left by a throw, a search typed over.
            // So the request runs in a task of its own, which nothing cancels.
            let session = session
            (data, response) = try await Task { try await session.data(for: request) }.value
            #else
            (data, response) = try await session.data(for: request)
            #endif
        } catch {
            throw JellyfinError(kind: .transport, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError(kind: .transport, message: "No HTTP response.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            let message: String
            switch http.statusCode {
            case 401: message = "The server did not accept the sign-in."
            case 403: message = "This account is not allowed to do that."
            case 404: message = "Not found on the server."
            default: message = "The server answered \(http.statusCode). \(body)"
            }
            throw JellyfinError(kind: .http(http.statusCode), message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, path: String) throws -> T {
        do {
            return try JSONCoding.decoder().decode(T.self, from: data)
        } catch {
            throw JellyfinError(kind: .decoding, message: "Unexpected reply from \(path): \(error)")
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], timeout: TimeInterval = 30) async throws -> T {
        let request = try makeRequest("GET", path, query: query, timeout: timeout)
        return try decode(try await perform(request), path: path)
    }

    func send<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:]) async throws -> T {
        let request = try makeRequest(method, path, query: query)
        return try decode(try await perform(request), path: path)
    }

    func send<T: Decodable, Body: Encodable>(_ method: String, _ path: String, query: [String: String] = [:], body: Body) async throws -> T {
        var request = try makeRequest(method, path, query: query)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder().encode(body)
        return try decode(try await perform(request), path: path)
    }

    func sendNoContent(_ method: String, _ path: String, query: [String: String] = [:]) async throws {
        _ = try await perform(try makeRequest(method, path, query: query))
    }

    func sendNoContent<Body: Encodable>(_ method: String, _ path: String, query: [String: String] = [:], body: Body) async throws {
        var request = try makeRequest(method, path, query: query)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder().encode(body)
        _ = try await perform(request)
    }
}

/// `GET /Items`'s filters, for library pages and search.
struct ItemQuery: Sendable, Equatable {
    enum Sort: String, Sendable, CaseIterable {
        case name = "SortName"
        case dateAdded = "DateCreated"
        case premiere = "PremiereDate"
        case rating = "CommunityRating"
        case runtime = "Runtime"
        case lastPlayed = "DatePlayed"
        case random = "Random"

        var title: String {
            switch self {
            case .name: return "Name"
            case .dateAdded: return "Date Added"
            case .premiere: return "Release Date"
            case .rating: return "Rating"
            case .runtime: return "Runtime"
            case .lastPlayed: return "Last Played"
            case .random: return "Random"
            }
        }

        /// Newest, best and longest first; names A to Z.
        var defaultDescending: Bool { self != .name }
    }

    enum Filter: String, Sendable, CaseIterable {
        case unplayed = "IsUnplayed"
        case played = "IsPlayed"
        case favorite = "IsFavorite"
        case resumable = "IsResumable"

        var title: String {
            switch self {
            case .unplayed: return "Unplayed"
            case .played: return "Played"
            case .favorite: return "Favourites"
            case .resumable: return "In Progress"
            }
        }
    }

    var parentId: String?
    var includeItemTypes: [ItemKind] = []
    var recursive = false
    var sort: Sort = .name
    var descending = false
    var filters: [Filter] = []
    var genres: [String] = []
    var personIds: [String] = []
    var searchTerm: String?
    var startIndex = 0
    var limit = 100
    var fields = JellyfinClient.listFields

    var parameters: [String: String] {
        var query: [String: String] = [
            "startIndex": String(startIndex),
            "limit": String(limit),
            "fields": fields,
            "enableImageTypes": JellyfinClient.imageTypes,
            "imageTypeLimit": "1",
            "enableTotalRecordCount": "true",
        ]
        if let parentId { query["parentId"] = parentId }
        if !includeItemTypes.isEmpty { query["includeItemTypes"] = includeItemTypes.map(\.rawValue).joined(separator: ",") }
        if recursive { query["recursive"] = "true" }
        if let searchTerm, !searchTerm.isEmpty {
            query["searchTerm"] = searchTerm
        } else {
            query["sortBy"] = sort == .name ? "SortName" : "\(sort.rawValue),SortName"
            query["sortOrder"] = descending ? "Descending" : "Ascending"
        }
        if !filters.isEmpty { query["filters"] = filters.map(\.rawValue).joined(separator: ",") }
        if !genres.isEmpty { query["genres"] = genres.joined(separator: "|") }
        if !personIds.isEmpty { query["personIds"] = personIds.joined(separator: ",") }
        return query
    }
}
