import AVFoundation
import SwiftUI
import UIKit

/// Only for what SwiftUI has no hook for: downloads that finished while the app was away.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        URLSessionDownloader.backgroundCompletion = completionHandler
    }
}

@main
struct JellymcApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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
                    switch phase {
                    case .active:
                        state.lock.becameActive(playing: PlaybackSession.current != nil)
                        // Coming back is the most likely moment for the network to have
                        // changed under the app: home Wi-Fi to cellular, a VPN coming up.
                        if state.phase == .signedIn {
                            Task { await state.reconnect() }
                        }
                    case .inactive:
                        state.lock.becameInactive(playing: PlaybackSession.current != nil)
                    case .background:
                        state.lock.enteredBackground(playing: PlaybackSession.current != nil)
                    @unknown default:
                        break
                    }
                }
        }
    }
}

/// Signing in, or the app, with the PIN over it.
struct RootView: View {
    @Environment(AppState.self) private var state
    @State private var lockWindow = LockWindow()

    var body: some View {
        Group {
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
        // Signed out there is nothing to hide, and the PIN keeps for the next sign-in.
        .onChange(of: state.lock.isShown && state.phase != .signedOut, initial: true) { _, shown in
            lockWindow.update(shown: shown, state: state)
        }
    }
}
