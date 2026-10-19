import CGtk

/// The app's stylesheet: cards, the hero, and the player's bars.
@MainActor
enum Style {
    static func install() {
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        // The library looks best dark, as every media app does.
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_DARK)
    }

    static let css = """
    .card { padding: 6px; border-radius: 12px; }
    .card-art { border-radius: 8px; background-color: alpha(currentColor, 0.08); }
    .card-title { font-weight: 600; }
    .card-progress trough { min-height: 4px; border-radius: 2px; background-color: alpha(black, 0.55); }
    .card-progress progress { min-height: 4px; border-radius: 2px; background-color: @accent_bg_color; }
    .card-played { background-color: @accent_bg_color; color: @accent_fg_color; border-radius: 999px; padding: 3px; }
    .card-grid { padding: 18px; }
    .card-grid > child { padding: 4px; }
    .hero-shade { background-image: linear-gradient(to bottom, alpha(@window_bg_color, 0.1) 0%, alpha(@window_bg_color, 0.55) 55%, @window_bg_color 100%); }
    .played-on { color: @accent_color; }
    .player { background-color: black; }
    .player-top { background-image: linear-gradient(to bottom, alpha(black, 0.75), alpha(black, 0)); color: white; padding: 12px 18px 48px 18px; }
    .player-bottom { background-image: linear-gradient(to top, alpha(black, 0.85), alpha(black, 0)); color: white; padding: 48px 22px 14px 22px; }
    .player-top button, .player-bottom button { color: white; }
    .player-time { font-feature-settings: "tnum"; color: alpha(white, 0.85); }
    .osd-pill { background-color: alpha(#141414, 0.88); color: white; border-radius: 999px; padding: 10px 22px; font-weight: 700; }
    .up-next { background-color: alpha(#141414, 0.94); color: white; border-radius: 14px; padding: 14px; }
    .stats { background-color: alpha(black, 0.7); color: white; border-radius: 10px; padding: 12px; font-family: monospace; font-size: 0.85em; }
    .seek-preview { background-color: alpha(#141414, 0.92); color: white; border-radius: 10px; padding: 6px; }
    .seek-preview picture { border-radius: 6px; }
    .seek-preview-time { font-feature-settings: "tnum"; font-weight: 700; }
    .error-box { background-color: alpha(black, 0.8); color: white; border-radius: 14px; padding: 20px; }
    """
}
