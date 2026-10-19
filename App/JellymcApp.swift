import AVFoundation
import SwiftUI

@main
struct JellymcApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = AppState()
    @State private var reachability = Reachability()

    init() {
        // Jellyfin's image URLs carry a content tag, so a cached one is good forever; the
        // default cache is small enough that posters reload on every scroll.
        URLCache.shared = URLCache(memoryCapacity: 96 * 1024 * 1024, diskCapacity: 768 * 1024 * 1024, directory: nil)
        // Playback: video keeps playing with the screen locked, in Picture in Picture, and
        // over AirPlay; it does not mix with other apps' audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .environment(reachability)
                .preferredColorScheme(.dark)
                .task {
                    reachability.onNetworkChange = { [state] in
                        Task { await state.reconnect() }
                    }
                    await state.restore()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back is the most likely moment for the network to have changed
                    // under the app: home Wi-Fi to cellular, a VPN coming up.
                    if phase == .active, state.phase == .signedIn {
                        Task { await state.reconnect() }
                    }
                }
        }
    }
}

/// Signing in, or the app.
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        switch state.phase {
        case .starting:
            ProgressView()
                .controlSize(.large)
        case .signedOut:
            SignInView()
        case .signedIn:
            MainTabView()
        }
    }
}
