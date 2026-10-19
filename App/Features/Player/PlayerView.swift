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
    /// Kept across episodes, as on Linux.
    @State private var sleepTimer = SleepTimer()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SystemPlayer(player: engine.player)
                .ignoresSafeArea()

            if let caption = engine.caption {
                VStack {
                    Spacer()
                    Text(caption)
                        .font(.system(size: 20 * state.preferences.subtitleSize.scale, weight: .semibold))
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
        .overlay(alignment: .topTrailing) {
            // Plex's playback settings; speed is in the system player's own menu.
            if let session {
                Menu {
                    if !session.chapters.isEmpty {
                        // Plex's chapter list: choosing one goes there.
                        Picker("Chapters", selection: Binding(
                            get: { session.currentChapter ?? -1 },
                            set: { index in
                                if session.chapters.indices.contains(index) { session.seek(to: session.chapters[index].start) }
                            }
                        )) {
                            ForEach(Array(session.chapters.enumerated()), id: \.offset) { index, chapter in
                                Text("\(Ticks.clock(chapter.start))  \(chapter.name.isEmpty ? "Chapter \(index + 1)" : chapter.name)").tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Picker("Quality", selection: Binding(get: { session.maxBitrate }, set: { session.setMaxBitrate($0) })) {
                        ForEach(PlaybackPreferences.bitrateChoices, id: \.bits) { Text($0.title).tag($0.bits) }
                    }
                    .pickerStyle(.menu)
                    Picker("Sleep Timer", selection: Binding(get: { sleepTimer.choice }, set: { sleepTimer.set($0) })) {
                        ForEach(SleepTimer.Choice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                } label: {
                    Image(systemName: sleepTimer.choice == .off ? "gearshape" : "moon.zzz.fill")
                        .font(.headline)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.trailing, 12)
                .padding(.top, 8)
                .accessibilityLabel("Playback Settings")
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            try? AVAudioSession.sharedInstance().setActive(true)
            start(request.item, from: request.start, audio: request.audioIndex, subtitle: request.subtitleIndex, version: request.mediaSourceId, continuing: .init(queue: request.queue))
        }
        .onDisappear {
            session?.stop()
            engine.shutdown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func start(_ item: BaseItem, from start: Double?, audio: Int?, subtitle: Int?, version: String?, continuing: PlaybackSession.Continuation = .init()) {
        guard let client = state.client else { return }
        session?.stop()
        let session = PlaybackSession(
            item: item,
            client: client,
            engine: engine,
            preferences: state.playbackPreferences(network: reachability.network),
            segmentActions: state.preferences.segmentActions,
            autoplayNext: state.preferences.autoplayNext,
            continuing: continuing
        )
        session.onPlayNext = { next, continuing in
            self.start(next, from: 0, audio: nil, subtitle: nil, version: nil, continuing: continuing)
        }
        session.onFinished = { close() }
        let timer = sleepTimer
        session.stopsAtEnd = { timer.itemEnded() }
        session.willStopAtEnd = { timer.choice == .endOfItem }
        timer.onFire = { [weak session] in session?.setPaused(true) }
        self.session = session

        var tracks = (audio: audio, subtitle: subtitle)
        if audio == nil, subtitle == nil, let source = item.mediaSources?.first(where: { $0.id == version }) ?? item.mediaSources?.first {
            tracks = state.preferences.initialTracks(for: source)
        }
        // A downloaded copy plays from the phone, with the server or without it.
        let local = state.downloads.localPlan(for: item.id, start: start ?? item.resumeSeconds)
        Task {
            await session.start(at: start, audioIndex: tracks.audio, subtitleIndex: tracks.subtitle, mediaSourceId: version, local: local)
        }
    }

    private func close() {
        session?.stop()
        dismiss()
    }
}

/// The skip button, the countdown to the next episode, and errors, from the session.
private struct Overlays: View {
    @Environment(AppState.self) private var state
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
                    // Plex shows the next one's picture, with the countdown along its foot.
                    ArtworkView(url: state.client.flatMap { Artwork.landscape(next, $0, width: 600) }, cornerRadius: 8, title: next.title)
                        .frame(width: 288, height: 162)
                        .overlay(alignment: .bottom) {
                            ProgressView(value: Double(10 - countdown), total: 10)
                                .tint(.plexGold)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 6)
                        }
                    Text(next.type == .episode ? [next.episodeLabel, next.name].compactMap { $0 }.joined(separator: " · ") : next.title)
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

            if session.isAskingStillWatching {
                VStack(spacing: 14) {
                    Text("Are you still watching?").font(.title3.bold())
                    HStack {
                        Button("Continue Watching") { session.keepWatching() }
                            .buttonStyle(.borderedProminent)
                            .tint(.plexGold)
                            .foregroundStyle(.black)
                        Button("Stop") { session.end() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
