import CGtk
import Foundation

/// What is saved on this computer, and what is on its way. Plays with no server at all.
@MainActor
final class DownloadsPage {
    let root: Widget
    private unowned let shell: Shell
    private let list = ListBox()
    private var shown: [String] = []

    init(shell: Shell) {
        self.shell = shell
        let downloads = shell.state.downloads
        let summary = Label("", "dim-label")
        let empty = StatusPage(icon: "folder-download-symbolic", title: "No Downloads", description: "Download films and episodes from their pages to watch them without the server.")
        let stack = Stack()
        stack.add(ScrolledWindow(Clamp(list.margin(24), maximum: 1000)).vexpand(), name: "list")
        stack.add(empty, name: "empty")
        root = ToolbarView(content: stack).top(HeaderBar().title(WindowTitle("Downloads")).end(summary))
        root.keep(self)

        root.observe { [weak self] in
            guard let self else { return }
            let records = downloads.all
            stack.visibleName = records.isEmpty ? "empty" : "list"
            summary.text = ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)
            self.show(records)
        }
    }

    private func show(_ records: [DownloadRecord]) {
        let key = records.map { "\($0.id):\($0.state):\(Int($0.progress * 100))" }
        guard key != shown else { return }
        shown = key
        list.removeAll()
        let downloads = shell.state.downloads
        for record in records {
            let item = record.item
            let art = Picture()
            art.size(width: 160, height: 90).css("card-art")
            if let saved = downloads.artURL(for: record) {
                art.load(saved)
            } else if let client = shell.state.client {
                art.load(Artwork.landscape(item, client, width: 160))
            }
            let progress = ProgressBar()
            progress.fraction = record.progress
            progress.visible(record.state == .downloading)
            let buttons = Box.horizontal(spacing: 6)
            if record.isDone {
                buttons.append(Button(icon: "media-playback-start-symbolic", "circular", "suggested-action") { [weak self] in
                    self?.shell.window.play(item)
                }.valign(GTK_ALIGN_CENTER).tooltip("Play"))
            }
            if case .failed = record.state {
                buttons.append(Button(icon: "view-refresh-symbolic", "circular", "flat") { downloads.retry(item.id) }.valign(GTK_ALIGN_CENTER).tooltip("Retry"))
            }
            buttons.append(Button(icon: "user-trash-symbolic", "circular", "flat") { downloads.remove(item.id) }.valign(GTK_ALIGN_CENTER).tooltip(record.isDone ? "Remove" : "Cancel"))
            list.append(Box.horizontal(spacing: 16) {
                // A picture's natural size is its image's; the clamp holds it to the row's.
                Clamp(art, maximum: 160, threshold: 160).valign(GTK_ALIGN_CENTER)
                Box.vertical(spacing: 6) {
                    Label(record.title, "heading").ellipsize()
                    Label(record.status, "dim-label", "caption").ellipsize()
                    progress
                }.valign(GTK_ALIGN_CENTER).hexpand()
                buttons
            }.margin(10))
        }
    }
}
