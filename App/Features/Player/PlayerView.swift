import AVKit
import SwiftUI

/// Full-screen video: the system's player and controls, with what the system does not
/// know about drawn over them — the skip button, the next episode's countdown, sidecar
/// subtitles, and why something failed.
struct PlayerView: View {
    @Environment(AppState.self) private var state
    @Environment(Reachability.self) private var reachability
    @Environment(\.dismiss) private var dismiss
    let request: PlayRequest

    @State private var engine = AVPlayerEngine()
    @State private var session: PlaybackSession?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SystemPlayer(player: engine.player)
                .ignoresSafeArea()

            if let caption = engine.caption {
                VStack {
                    Spacer()
                    Text(caption)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 70)
                        .padding(.horizontal, 24)
                }
                .allowsHitTesting(false)
            }

            if let session {
                Overlays(session: session)
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.leading, 12)
            .padding(.top, 8)
            .accessibilityLabel("Close")
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            try? AVAudioSession.sharedInstance().setActive(true)
            start(request.item, from: request.start, audio: request.audioIndex, subtitle: request.subtitleIndex, version: request.mediaSourceId)
        }
        .onDisappear {
            session?.stop()
            engine.shutdown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func start(_ item: BaseItem, from start: Double?, audio: Int?, subtitle: Int?, version: String?) {
        guard let client = state.client else { return }
        session?.stop()
        let session = PlaybackSession(
            item: item,
            client: client,
            engine: engine,
            preferences: state.playbackPreferences(network: reachability.network),
            segmentActions: state.preferences.segmentActions,
            autoplayNext: state.preferences.autoplayNext
        )
        session.onPlayNext = { next in
            self.start(next, from: 0, audio: nil, subtitle: nil, version: nil)
        }
        session.onFinished = { close() }
        self.session = session

        var tracks = (audio: audio, subtitle: subtitle)
        if audio == nil, subtitle == nil, let source = item.mediaSources?.first(where: { $0.id == version }) ?? item.mediaSources?.first {
            tracks = state.preferences.initialTracks(for: source)
        }
        Task {
            await session.start(at: start, audioIndex: tracks.audio, subtitleIndex: tracks.subtitle, mediaSourceId: version)
        }
    }

    private func close() {
        session?.stop()
        dismiss()
    }
}

/// The skip button, the countdown to the next episode, and errors, from the session.
private struct Overlays: View {
    let session: PlaybackSession

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear

            if let segment = session.skippable {
                Button {
                    session.skipSegment()
                } label: {
                    Text(segment.type == .outro && session.next != nil ? "Next Episode" : segment.type.skipLabel)
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.trailing, 24)
                .padding(.bottom, 110)
                .transition(.opacity)
            }

            if let countdown = session.countdown, let next = session.next {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text([next.episodeLabel, next.name].compactMap { $0 }.joined(separator: " · "))
                        .font(.headline)
                        .lineLimit(2)
                    Text("Starting in \(countdown) s").font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button("Play Now") { session.playNext(next) }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { session.cancelCountdown() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .frame(maxWidth: 320, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.trailing, 24)
                .padding(.bottom, 110)
            }

            if let error = session.error {
                VStack(spacing: 12) {
                    Text("Playback Failed").font(.title3.bold())
                    Text(error).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try Transcoding") { session.retryWithTranscode() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: 360)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.skippable?.startTicks)
    }
}

/// AVPlayerViewController: the controls, Picture in Picture (including starting it when
/// the app goes to the background), AirPlay, Now Playing and the lock screen.
private struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
