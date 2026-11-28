import AVKit
import SwiftUI

/// Full-screen video, the way Plex plays it: while it plays there is nothing over the
/// picture but the subtitles. A tap brings the controls (close, the title, AirPlay,
/// chapters, audio and subtitles, settings, play and pause, 10 s back and forward, the
/// seek bar with the server's thumbnails), and they go again after a few seconds of
/// playing. A double tap on either side skips 10 s, one in the middle or a pinch fills
/// the screen or fits the whole picture.
///
/// The picture is still AVPlayerViewController's, with its own controls off: it keeps
/// Picture in Picture on leaving the app, AirPlay and the lock screen's Now Playing.
struct PlayerView: View {
    @Environment(AppState.self) private var state
    @Environment(Reachability.self) private var reachability
    @Environment(\.dismiss) private var dismiss
    let request: PlayRequest

    @State private var engine = AVPlayerEngine()
    @State private var session: PlaybackSession?
    /// Kept across episodes, as on Linux; so is the speed, which the player keeps.
    @State private var sleepTimer = SleepTimer()
    @State private var rate = 1.0
    @State private var fill = false

    @State private var controlsShown = false
    @State private var hideTask: Task<Void, Never>?
    /// Where the seek bar is being dragged to, while it is.
    @State private var scrubbing: Double?
    @State private var panel: PlayerPanel?
    @State private var skipFlash: SkipFlash?
    /// The skip button shows on its own for a few seconds when its segment begins, then
    /// only with the controls.
    @State private var skipFresh = false
    @State private var skipFreshTask: Task<Void, Never>?

    /// A failure keeps the controls up: Close must be there.
    private var controlsVisible: Bool { controlsShown || session?.error != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SystemPlayer(player: engine.player, fill: fill)
                .ignoresSafeArea()

            touchLayer

            if controlsVisible {
                // Plex dims the picture under its controls, so they read over anything.
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            captions

            if let session {
                if session.isBuffering, !session.isPaused, session.error == nil, !controlsVisible {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .allowsHitTesting(false)
                }

                if let flash = skipFlash {
                    SkipFlashView(flash: flash)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if controlsVisible {
                    PlayerControls(
                        session: session,
                        sleepTimer: sleepTimer,
                        scrubbing: $scrubbing,
                        close: { close() },
                        open: { panel = $0; hideTask?.cancel() },
                        touched: { scheduleHide() },
                        scrubbingChanged: { active in
                            if active { hideTask?.cancel() } else { scheduleHide() }
                        }
                    )
                    .transition(.opacity)
                }

                Overlays(session: session, showsSkip: controlsVisible || skipFresh, controlsVisible: controlsVisible)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(item: $panel, onDismiss: { scheduleHide() }) { panel in
            if let session {
                PlayerPanelView(panel: panel, session: session, sleepTimer: sleepTimer, rate: $rate)
            }
        }
        .onChange(of: session?.isPaused) { _, paused in
            // Paused, the controls come up and stay; playing again, they go by themselves.
            if paused == true {
                hideTask?.cancel()
                withAnimation(.easeOut(duration: 0.2)) { controlsShown = true }
            } else {
                scheduleHide()
            }
        }
        .onChange(of: session?.skippable?.startTicks) { _, start in
            skipFreshTask?.cancel()
            guard start != nil else {
                skipFresh = false
                return
            }
            skipFresh = true
            skipFreshTask = Task {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { skipFresh = false }
            }
        }
        .onChange(of: session?.error) { _, error in
            guard error != nil else { return }
            // The engine writes what went wrong a moment after it says so.
            Task {
                try? await Task.sleep(for: .seconds(1))
                AutoLog.send("a video failed to play", state: state)
            }
        }
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            try? AVAudioSession.sharedInstance().setActive(true)
            start(request.item, from: request.start, audio: request.audioIndex, subtitle: request.subtitleIndex, version: request.mediaSourceId, continuing: .init(queue: request.queue))
        }
        .onDisappear {
            if let session {
                let line = "\(session.logName): closed at \(Ticks.clock(session.position)) of \(Ticks.clock(session.duration))"
                Task {
                    await Diagnostics.shared.record("playback", line)
                    AutoLog.send("a video was closed", state: state)
                }
            }
            hideTask?.cancel()
            skipFreshTask?.cancel()
            session?.stop()
            engine.shutdown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Touches

    /// Under the controls, over the picture: a tap shows or hides them, a double tap skips
    /// or fills, a pinch fills or fits. Taps on the controls' empty space fall through to it.
    private var touchLayer: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in doubleTap(at: value.location.x, width: geometry.size.width) }
                        .exclusively(before: SpatialTapGesture(count: 1).onEnded { _ in toggleControls() })
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onEnded { value in
                            if value.magnification > 1.08 {
                                withAnimation(.easeInOut(duration: 0.25)) { fill = true }
                            } else if value.magnification < 0.92 {
                                withAnimation(.easeInOut(duration: 0.25)) { fill = false }
                            }
                        }
                )
        }
        .ignoresSafeArea()
    }

    private func doubleTap(at x: CGFloat, width: CGFloat) {
        guard let session, width > 0 else { return }
        if x < width * 0.35 || x > width * 0.65 {
            let forward = x > width * 0.65
            session.skip(by: forward ? 10 : -10)
            let flash = SkipFlash(forward: forward)
            withAnimation(.easeOut(duration: 0.15)) { skipFlash = flash }
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                if skipFlash == flash { withAnimation(.easeIn(duration: 0.25)) { skipFlash = nil } }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { fill.toggle() }
        }
        if controlsShown { scheduleHide() }
    }

    private func toggleControls() {
        if controlsShown {
            hideTask?.cancel()
            withAnimation(.easeIn(duration: 0.25)) { controlsShown = false }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { controlsShown = true }
            scheduleHide()
        }
    }

    /// The controls go after a few untouched seconds of playing: never while paused, while
    /// the seek bar is held, or with a panel open.
    private func scheduleHide() {
        hideTask?.cancel()
        guard let session, !session.isPaused, session.error == nil, scrubbing == nil, panel == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, self.session?.isPaused == false, scrubbing == nil, panel == nil else { return }
            withAnimation(.easeIn(duration: 0.3)) { controlsShown = false }
        }
    }

    // MARK: - Subtitles

    /// Subtitles the app draws: low while the controls are away, above the seek bar
    /// while they are up.
    @ViewBuilder private var captions: some View {
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
                    .padding(.bottom, controlsVisible ? 96 : 20)
                    .padding(.horizontal, 24)
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        }
    }

    // MARK: - Playing

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
            tracks = state.preferences.initialTracks(for: source, item: item)
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

// MARK: - Controls

/// Everything a tap brings up. Its empty space takes no touches, so a tap there reaches
/// the layer underneath and hides it all again.
private struct PlayerControls: View {
    let session: PlaybackSession
    let sleepTimer: SleepTimer
    @Binding var scrubbing: Double?
    let close: () -> Void
    let open: (PlayerPanel) -> Void
    /// Any control used: the controls stay a while longer.
    let touched: () -> Void
    let scrubbingChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            // Darker at the top and the foot, where the text is.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)

            centerButtons
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            ControlButton(systemImage: "xmark", label: "Close", action: close)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.headline)
                if let subtitle = session.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            RoutePicker()
                .frame(width: 40, height: 40)
                .accessibilityLabel("AirPlay")
            if !session.chapters.isEmpty {
                ControlButton(systemImage: "list.bullet", label: "Chapters") { open(.chapters) }
            }
            ControlButton(systemImage: "captions.bubble", label: "Audio and Subtitles") { open(.tracks) }
            ControlButton(systemImage: sleepTimer.choice == .off ? "gearshape" : "moon.zzz.fill", label: "Playback Settings") { open(.settings) }
        }
    }

    private var centerButtons: some View {
        HStack(spacing: 48) {
            Button {
                session.skip(by: -10)
                touched()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 30, weight: .medium))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back 10 Seconds")

            ZStack {
                if session.isBuffering, !session.isPaused {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Button {
                        session.togglePause()
                        touched()
                    } label: {
                        Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 46))
                            .frame(width: 80, height: 80)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(session.isPaused ? "Play" : "Pause")
                }
            }
            .frame(width: 80, height: 80)

            Button {
                session.skip(by: 10)
                touched()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 30, weight: .medium))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Forward 10 Seconds")
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.35), radius: 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 2) {
            Scrubber(session: session, scrubbing: $scrubbing, changed: scrubbingChanged)
            HStack {
                Text(Ticks.clock(scrubbing ?? session.position))
                Spacer()
                Text("-" + Ticks.clock(max(0, session.duration - (scrubbing ?? session.position))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct ControlButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The seek bar: drag anywhere along it; the video moves when it is let go, with the
/// server's thumbnail of the spot above the finger meanwhile.
private struct Scrubber: View {
    let session: PlaybackSession
    @Binding var scrubbing: Double?
    let changed: (Bool) -> Void

    private static let thumbnailWidth: CGFloat = 176

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let duration = max(session.duration, 1)
            let fraction = min(max((scrubbing ?? session.position) / duration, 0), 1)
            let knob: CGFloat = scrubbing == nil ? 14 : 22
            let bar: CGFloat = scrubbing == nil ? 4 : 6

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: bar)
                Capsule().fill(Color.plexGold).frame(width: width * fraction, height: bar)
                Circle().fill(.white).frame(width: knob, height: knob).offset(x: width * fraction - knob / 2)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if scrubbing == nil { changed(true) }
                        scrubbing = min(max(value.location.x / width, 0), 1) * duration
                    }
                    .onEnded { value in
                        session.seek(to: min(max(value.location.x / width, 0), 1) * duration)
                        scrubbing = nil
                        changed(false)
                    }
            )
            .overlay(alignment: .bottomLeading) {
                if let scrubbing, let preview = session.preview(at: scrubbing) {
                    let height = Self.thumbnailWidth * CGFloat(preview.frame.height) / CGFloat(max(preview.frame.width, 1))
                    TrickplayThumbnail(preview: preview)
                        .frame(width: Self.thumbnailWidth, height: height)
                        .offset(
                            x: min(max(width * fraction - Self.thumbnailWidth / 2, 0), max(width - Self.thumbnailWidth, 0)),
                            y: -(geometry.size.height + 8)
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(Ticks.clock(session.position))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: session.skip(by: 10)
            case .decrement: session.skip(by: -10)
            @unknown default: break
            }
        }
    }
}

/// One frame of the server's trickplay tiles.
private struct TrickplayThumbnail: View {
    let preview: TrickplayPreview
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.6))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.8), lineWidth: 1))
        .task(id: preview) {
            if let loaded = await TrickplayTiles.shared.image(for: preview) { image = loaded }
        }
    }
}

/// The last few tile images, so dragging across one tile's frames fetches it once.
@MainActor
private final class TrickplayTiles {
    static let shared = TrickplayTiles()
    private var tiles: [URL: CGImage] = [:]
    private var order: [URL] = []

    func image(for preview: TrickplayPreview) async -> UIImage? {
        let tile: CGImage
        if let cached = tiles[preview.tile] {
            tile = cached
        } else {
            guard let response = try? await URLSession.shared.data(from: preview.tile),
                  let image = UIImage(data: response.0)?.cgImage
            else { return nil }
            tiles[preview.tile] = image
            order.append(preview.tile)
            if order.count > 6 { tiles[order.removeFirst()] = nil }
            tile = image
        }
        let frame = preview.frame
        guard let cropped = tile.cropping(to: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)) else { return nil }
        return UIImage(cgImage: cropped)
    }
}

/// AirPlay's own picker, video devices first.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = UIColor(Color.plexGold)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// A double tap's "10 s", briefly, on the side it skipped.
private struct SkipFlash: Equatable {
    let forward: Bool
    let id = UUID()
}

private struct SkipFlashView: View {
    let flash: SkipFlash

    var body: some View {
        HStack {
            if flash.forward { Spacer() }
            VStack(spacing: 6) {
                Image(systemName: flash.forward ? "goforward.10" : "gobackward.10")
                    .font(.system(size: 30, weight: .medium))
                Text("10 seconds").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 120, height: 120)
            .background(.black.opacity(0.35), in: Circle())
            if !flash.forward { Spacer() }
        }
        .padding(.horizontal, 48)
    }
}

// MARK: - Panels

enum PlayerPanel: String, Identifiable {
    case tracks, settings, chapters
    var id: String { rawValue }
}

/// What the controls' buttons open, as a sheet: Plex's audio and subtitle lists, its
/// playback settings (quality, speed, the sleep timer), and the chapters.
private struct PlayerPanelView: View {
    let panel: PlayerPanel
    let session: PlaybackSession
    let sleepTimer: SleepTimer
    @Binding var rate: Double
    @Environment(\.dismiss) private var dismiss

    private static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        NavigationStack {
            List {
                switch panel {
                case .tracks: tracks
                case .settings: settings
                case .chapters: chapters
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var title: String {
        switch panel {
        case .tracks: return "Audio & Subtitles"
        case .settings: return "Playback Settings"
        case .chapters: return "Chapters"
        }
    }

    @ViewBuilder private var tracks: some View {
        let plan = session.plan
        Section("Subtitles") {
            CheckRow("Off", checked: plan?.subtitleIndex == nil) {
                session.selectSubtitle(nil)
                dismiss()
            }
            ForEach(plan?.subtitleStreams ?? [], id: \.index) { stream in
                CheckRow(stream.label, checked: plan?.subtitleIndex == stream.index) {
                    session.selectSubtitle(stream.index)
                    dismiss()
                }
            }
        }
        if let audio = plan?.audioStreams, !audio.isEmpty {
            Section("Audio") {
                ForEach(audio, id: \.index) { stream in
                    CheckRow(stream.label, checked: plan?.audioIndex == stream.index) {
                        session.selectAudio(stream.index)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder private var settings: some View {
        Section("Quality") {
            ForEach(PlaybackPreferences.bitrateChoices, id: \.bits) { choice in
                CheckRow(choice.title, checked: session.maxBitrate == choice.bits) { session.setMaxBitrate(choice.bits) }
            }
        }
        Section("Speed") {
            ForEach(Self.rates, id: \.self) { value in
                CheckRow(value == 1 ? "Normal" : "\(value.formatted())×", checked: rate == value) {
                    rate = value
                    session.setRate(value)
                }
            }
        }
        Section("Sleep Timer") {
            ForEach(SleepTimer.Choice.allCases, id: \.self) { choice in
                CheckRow(choice.title, checked: sleepTimer.choice == choice) { sleepTimer.set(choice) }
            }
        }
    }

    @ViewBuilder private var chapters: some View {
        ForEach(Array(session.chapters.enumerated()), id: \.offset) { index, chapter in
            Button {
                session.seek(to: chapter.start)
                dismiss()
            } label: {
                HStack {
                    Text(chapter.name.isEmpty ? "Chapter \(index + 1)" : chapter.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(Ticks.clock(chapter.start))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if session.currentChapter == index {
                        Image(systemName: "checkmark").foregroundStyle(Color.plexGold)
                    }
                }
            }
        }
    }
}

private struct CheckRow: View {
    let title: String
    let checked: Bool
    let action: () -> Void

    init(_ title: String, checked: Bool, action: @escaping () -> Void) {
        self.title = title
        self.checked = checked
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if checked {
                    Image(systemName: "checkmark").foregroundStyle(Color.plexGold)
                }
            }
        }
    }
}

// MARK: - Over the picture

/// The skip button, the countdown to the next episode, and errors, from the session.
private struct Overlays: View {
    @Environment(AppState.self) private var state
    let session: PlaybackSession
    /// The skip button: at its segment's start for a few seconds, then with the controls.
    let showsSkip: Bool
    let controlsVisible: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Fills the screen to place the rest, and takes no taps.
            Color.clear.allowsHitTesting(false)

            if showsSkip, let segment = session.skippable {
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
                .padding(.bottom, controlsVisible ? 76 : 28)
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
                .padding(.bottom, controlsVisible ? 76 : 28)
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
        .animation(.easeInOut(duration: 0.2), value: showsSkip)
    }
}

/// AVPlayerViewController for the picture only: Picture in Picture (including starting it
/// when the app goes to the background), AirPlay and Now Playing. Its own controls are
/// off; the app's are drawn over it.
private struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let fill: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if controller.videoGravity != gravity { controller.videoGravity = gravity }
    }
}
