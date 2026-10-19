import CGtk
import Foundation

/// Icons no theme can be counted on for. Written out once and added to the icon theme's
/// search path, so they are named like any other icon and recoloured with the text.
@MainActor
enum Icons {
    private static let svgs: [String: String] = [
        // A funnel: Plex's filter button.
        "jellymc-filter-symbolic": """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
          <path fill="#2e3436" d="M1.5 2h13a.5.5 0 0 1 .38.82L10 8.6V13a.5.5 0 0 1-.28.45l-3 1.5A.5.5 0 0 1 6 14.5V8.6L1.12 2.82A.5.5 0 0 1 1.5 2z"/>
        </svg>
        """,
    ]

    static func install() {
        let base = Paths.cache.appendingPathComponent("icons", isDirectory: true)
        let folder = base.appendingPathComponent("hicolor/scalable/actions", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, svg) in svgs {
            let file = folder.appendingPathComponent("\(name).svg")
            if (try? String(contentsOf: file, encoding: .utf8)) != svg {
                try? svg.write(to: file, atomically: true, encoding: .utf8)
            }
        }
        guard let display = gdk_display_get_default(), let theme = gtk_icon_theme_get_for_display(display) else { return }
        gtk_icon_theme_add_search_path(theme, base.path)
    }
}
