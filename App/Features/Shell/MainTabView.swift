import SwiftUI

/// What the player is asked to play: everything a play button can choose.
struct PlayRequest: Identifiable {
    let id = UUID()
    var item: BaseItem
    var start: Double?
    var audioIndex: Int?
    var subtitleIndex: Int?
    var mediaSourceId: String?
    /// What plays after it: Shuffle's order, the rest of a collection.
    var queue: [BaseItem] = []
}

/// Starts playback from anywhere below the tabs: views ask it, the tab view presents.
@MainActor
@Observable
final class PlayerRouter {
    var request: PlayRequest?
    /// The remote for what another device plays.
    var showsRemote = false

    func play(_ item: BaseItem, from start: Double? = nil, audio: Int? = nil, subtitle: Int? = nil, version: String? = nil, queue: [BaseItem] = []) {
        request = PlayRequest(item: item, start: start, audioIndex: audio, subtitleIndex: subtitle, mediaSourceId: version, queue: queue)
    }
}

/// A page that can be opened from a card: hashed by id, so a refreshed item is the same
/// destination.
struct ItemRoute: Hashable {
    let item: BaseItem

    static func == (lhs: ItemRoute, rhs: ItemRoute) -> Bool { lhs.item.id == rhs.item.id }
    func hash(into hasher: inout Hasher) { hasher.combine(item.id) }
}

struct LibraryRoute: Hashable {
    let library: BaseItem

    static func == (lhs: LibraryRoute, rhs: LibraryRoute) -> Bool { lhs.library.id == rhs.library.id }
    func hash(into hasher: inout Hasher) { hasher.combine(library.id) }
}

/// Home, the libraries, search and settings; a sidebar on iPad.
struct MainTabView: View {
    @Environment(AppState.self) private var state
    @Environment(Reachability.self) private var reachability
    @State private var router = PlayerRouter()
    @State private var selection = Tabs.home
    @State private var remoteMessage: RemoteMessage?
    @State private var playlistName = ""

    /// Text another device sent, through the server.
    struct RemoteMessage: Identifiable {
        let id = UUID()
        var header: String
        var text: String
    }

    enum Tabs: Hashable { case home, libraries, downloads, search, settings }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: Tabs.home) {
                NavigationStack { HomeView().withRoutes() }.remoteBar()
            }
            Tab("Libraries", systemImage: "square.grid.2x2", value: Tabs.libraries) {
                NavigationStack { LibrariesView().withRoutes() }.remoteBar()
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: Tabs.downloads) {
                NavigationStack { DownloadsView().withRoutes() }.remoteBar()
            }
            Tab("Settings", systemImage: "gearshape", value: Tabs.settings) {
                NavigationStack { SettingsView() }.remoteBar()
            }
            Tab(value: Tabs.search, role: .search) {
                NavigationStack { SearchView().withRoutes() }.remoteBar()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(router)
        .sheet(isPresented: $router.showsRemote) {
            RemoteView()
                .environment(state)
        }
        // Reading what the other devices play, from whichever client is current.
        .task(id: state.client.map { ObjectIdentifier($0) }) {
            if let client = state.client { state.remote.start(client) }
        }
        .fullScreenCover(item: $router.request, onDismiss: refresh) { request in
            PlayerView(request: request)
                .environment(state)
                .environment(reachability)
        }
        .alert(
            remoteMessage.map { $0.header.isEmpty ? "Message" : $0.header } ?? "",
            isPresented: Binding(get: { remoteMessage != nil }, set: { if !$0 { remoteMessage = nil } }),
            presenting: remoteMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message.text)
        }
        .alert("New Playlist", isPresented: Binding(get: { state.namingPlaylistFor != nil }, set: { if !$0 { state.namingPlaylistFor = nil } })) {
            TextField("Name", text: $playlistName)
            Button("Create") {
                if let item = state.namingPlaylistFor {
                    let name = playlistName
                    Task { await state.newPlaylist(name, with: item) }
                }
                playlistName = ""
            }
            Button("Cancel", role: .cancel) { playlistName = "" }
        }
        .onAppear {
            // Another device plays something here: the same player a tap opens.
            let router = router
            state.onRemotePlay = { item, request in
                router.play(item, from: request.start, audio: request.audioStreamIndex, subtitle: request.subtitleStreamIndex, version: request.mediaSourceId)
            }
            state.onRemoteMessage = { header, text in
                remoteMessage = RemoteMessage(header: header, text: text)
            }
        }
        .overlay(alignment: .top) {
            if state.isOffline {
                Label("Server unreachable — showing what was saved", systemImage: "wifi.slash")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 4)
            }
        }
    }

    /// Progress and Next Up move after playing; the home rows catch up.
    private func refresh() {
        Task { await state.playbackEnded() }
    }
}

extension View {
    /// The bar for what another device plays, above the tabs.
    func remoteBar() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { RemoteBar() }
    }

    /// The pages every tab's stack can open.
    func withRoutes() -> some View {
        navigationDestination(for: ItemRoute.self) { route in
            ItemDetailView(item: route.item)
        }
        .navigationDestination(for: LibraryRoute.self) { route in
            LibraryView(library: route.library)
        }
        .navigationDestination(for: Browse.self) { browse in
            BrowsePageView(browse: browse)
        }
    }
}
