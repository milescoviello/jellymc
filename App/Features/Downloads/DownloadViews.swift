import SwiftUI

/// Everything saved on the phone, and what is on its way. Plays with no server at all.
struct DownloadsView: View {
    @Environment(AppState.self) private var state
    @Environment(PlayerRouter.self) private var router

    var body: some View {
        let downloads = state.downloads
        let records = downloads.all
        List {
            if !records.isEmpty {
                Section {
                    ForEach(records) { record in
                        Button {
                            if record.isDone { router.play(record.item) }
                        } label: {
                            DownloadRow(record: record).foregroundStyle(.primary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                downloads.remove(record.id)
                            } label: {
                                Label(record.isDone ? "Delete" : "Cancel", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("\(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)) on this device")
                }
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "No Downloads", systemImage: "arrow.down.circle",
                    description: Text("Download films and episodes from their pages to watch them without the server.")
                )
            }
        }
        .navigationTitle("Downloads")
    }
}

private struct DownloadRow: View {
    @Environment(AppState.self) private var state
    let record: DownloadRecord

    var body: some View {
        let downloads = state.downloads
        HStack(spacing: 14) {
            ArtworkView(url: downloads.artURL(for: record) ?? state.client.flatMap { Artwork.landscape(record.item, $0, width: 480) })
                .frame(width: 120, height: 68)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(record.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if record.state == .downloading {
                    ProgressView(value: record.progress)
                }
            }
            Spacer(minLength: 0)
            if case .failed = record.state {
                Button {
                    downloads.retry(record.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Retry")
            }
        }
    }
}

/// Download, its progress, or remove it: one button on a film's or episode's page.
struct DownloadButton: View {
    @Environment(AppState.self) private var state
    let item: BaseItem
    @State private var confirming = false

    var body: some View {
        let downloads = state.downloads
        let record = downloads.record(for: item.id)
        Button {
            switch record?.state {
            case nil: Task { await downloads.download(item, for: .avPlayer) }
            case .failed?: downloads.retry(item.id)
            default: confirming = true
            }
        } label: {
            switch record?.state {
            case nil: Image(systemName: "arrow.down.circle")
            case .queued?: Image(systemName: "clock")
            case .downloading?: Text("\(Int((record?.progress ?? 0) * 100))%").monospacedDigit()
            case .done?: Image(systemName: "arrow.down.circle.fill")
            case .failed?: Image(systemName: "exclamationmark.arrow.circlepath")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityLabel(label(record))
        .confirmationDialog(
            record?.isDone == true ? "Remove the download?" : "Stop the download?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button(record?.isDone == true ? "Remove Download" : "Stop Download", role: .destructive) {
                downloads.remove(item.id)
            }
        }
    }

    private func label(_ record: DownloadRecord?) -> String {
        switch record?.state {
        case nil: return "Download"
        case .queued?: return "Waiting to download"
        case .downloading?: return "Downloading"
        case .done?: return "Downloaded"
        case .failed?: return "Retry download"
        }
    }
}
