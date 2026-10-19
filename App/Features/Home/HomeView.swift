import SwiftUI

/// Plex's Home: Continue Watching, then what is new in each library.
struct HomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let home = state.home
        // With no server and nothing cached, Home is what was downloaded.
        let rows = home.rows.isEmpty && state.isOffline ? HomeModel.offlineRows(state.downloads.all) : home.rows
        ScrollView {
            HubList(rows: rows)
        }
        .overlay {
            if rows.isEmpty {
                if home.isLoading {
                    ProgressView()
                } else if state.isOffline {
                    ContentUnavailableView("Can’t Reach the Server", systemImage: "wifi.slash", description: Text("Downloads play without it. It will be tried again on its own."))
                } else if let error = home.error {
                    ContentUnavailableView("Couldn’t Load", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "play.tv", description: Text("Libraries the server shares with you show up here."))
                }
            }
        }
        .navigationTitle("Home")
        .toolbar {
            if state.lock.isEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        state.lock.lockNow()
                    } label: {
                        Image(systemName: "lock")
                    }
                    .accessibilityLabel("Lock")
                }
            }
        }
        .pullToRefresh {
            if let client = state.client { await home.load(client, force: true) }
        }
        .task {
            if let client = state.client { await home.load(client) }
        }
    }
}
