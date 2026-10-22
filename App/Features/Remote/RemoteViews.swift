import SwiftUI

/// Above the tabs while another of your devices plays: what, where, and play/pause. A tap
/// opens the remote.
struct RemoteBar: View {
    @Environment(AppState.self) private var state
    @Environment(PlayerRouter.self) private var router

    var body: some View {
        let remote = state.remote
        if remote.isShown, let item = remote.item {
            HStack(spacing: 12) {
                ArtworkView(url: state.client.flatMap { Artwork.landscape(item, $0, width: 240) }, cornerRadius: 6, placeholder: "tv")
                    .frame(width: 64, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RemoteView.title(item))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Label(remote.session == nil ? "Starting on \(remote.deviceName)…" : "Playing on \(remote.deviceName)", systemImage: "tv")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    remote.togglePause()
                } label: {
                    Image(systemName: remote.isPaused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(remote.session == nil)
                .accessibilityLabel(remote.isPaused ? "Play" : "Pause")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottom) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ProgressView(value: remote.position(at: context.date), total: max(remote.duration, 1))
                        .tint(.plexGold)
                        .scaleEffect(x: 1, y: 0.6)
                        .padding(.horizontal, 14)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { router.showsRemote = true }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The remote, as casting has it: the picture, where it is, play and pause, back ten and on
/// thirty, the next episode, and stop.
struct RemoteView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// The seek bar's value while a finger is on it.
    @State private var scrubbing: Double?

    var body: some View {
        let remote = state.remote
        NavigationStack {
            VStack(spacing: 22) {
                if let item = remote.item {
                    ArtworkView(url: state.client.flatMap { Artwork.landscape(item, $0, width: 900) }, cornerRadius: 14, placeholder: "tv", title: item.title)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                    VStack(spacing: 4) {
                        Text(Self.title(item)).font(.title3.bold()).multilineTextAlignment(.center)
                        if let detail = Self.detail(item) {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    if remote.session == nil {
                        ProgressView("Starting on \(remote.deviceName)…")
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            seekBar(remote, position: remote.position(at: context.date))
                        }
                        controls(remote, item: item)
                    }
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "tv", description: Text("Play On sends what you pick to another device, and this controls it."))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .navigationTitle(remote.isShown ? "Playing on \(remote.deviceName)" : "Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear { remote.isOnScreen = true }
        .onDisappear { remote.isOnScreen = false }
        .onChange(of: remote.isShown) { _, shown in
            // Stopped here or there: nothing left to control.
            if !shown { dismiss() }
        }
    }

    private func seekBar(_ remote: RemoteControl, position: Double) -> some View {
        let duration = max(remote.duration, 1)
        let shown = scrubbing ?? position
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { shown }, set: { scrubbing = $0 }),
                in: 0 ... duration
            ) { editing in
                if !editing, let target = scrubbing {
                    remote.seek(to: target)
                    scrubbing = nil
                }
            }
            .tint(.plexGold)
            .disabled(remote.session?.playState?.canSeek == false)
            HStack {
                Text(Ticks.clock(shown))
                Spacer()
                Text("-" + Ticks.clock(max(0, duration - shown)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func controls(_ remote: RemoteControl, item: BaseItem) -> some View {
        VStack(spacing: 26) {
            HStack(spacing: 44) {
                Button { remote.skip(by: -10) } label: { Image(systemName: "gobackward.10").font(.title) }
                    .accessibilityLabel("Back 10 Seconds")
                Button { remote.togglePause() } label: {
                    Image(systemName: remote.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(Color.plexGold)
                }
                .accessibilityLabel(remote.isPaused ? "Play" : "Pause")
                Button { remote.skip(by: 30) } label: { Image(systemName: "goforward.30").font(.title) }
                    .accessibilityLabel("Forward 30 Seconds")
            }
            .buttonStyle(.plain)
            HStack(spacing: 14) {
                if item.type == .episode {
                    Button { remote.next() } label: { Label("Next Episode", systemImage: "forward.end.fill") }
                        .buttonStyle(.bordered)
                }
                Button(role: .destructive) { remote.stopPlayback() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// A film's title, or an episode's show.
    static func title(_ item: BaseItem) -> String {
        item.type == .episode ? (item.seriesName ?? item.title) : item.title
    }

    static func detail(_ item: BaseItem) -> String? {
        guard item.type == .episode else { return item.productionYear.map(String.init) }
        return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
    }
}
