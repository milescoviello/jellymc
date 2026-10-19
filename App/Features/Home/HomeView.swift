import SwiftUI

/// Continue Watching, Next Up, and the newest in each library.
struct HomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let home = state.home
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(home.rows) { row in
                    CardRowView(
                        title: row.title,
                        style: row.style,
                        items: row.items,
                        playsDirectly: row.kind != .latest,
                        library: row.libraryId.flatMap { id in home.libraries.first { $0.id == id } }
                    )
                }
            }
            .padding(.vertical)
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
