import SwiftUI

/// Plex's Home: Continue Watching, then what is new in each library.
struct HomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let home = state.home
        ScrollView {
            HubList(rows: home.rows)
        }
        .overlay {
            if home.rows.isEmpty {
                if home.isLoading {
                    ProgressView()
                } else if let error = home.error {
                    ContentUnavailableView("Couldn’t Load", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "play.tv", description: Text("Libraries the server shares with you show up here."))
                }
            }
        }
        .navigationTitle("Home")
        .refreshable {
            if let client = state.client { await home.load(client, force: true) }
        }
        .task {
            if let client = state.client { await home.load(client) }
        }
    }
}
