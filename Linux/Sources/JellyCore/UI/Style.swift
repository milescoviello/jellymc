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

    /// One of eight colours for a name, the same every time: genre tiles.
    static func tint(for name: String) -> String {
        // FNV-1a, stable across runs, unlike hashValue.
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return "tint-\(hash % 8)"
    }

    static let css = """
    :root { --accent-bg-color: #e5a00d; --accent-fg-color: rgb(0 0 0 / 87%); --accent-color: #f0b53a; }
    @define-color accent_bg_color #e5a00d;
    @define-color accent_fg_color rgba(0, 0, 0, 0.87);
    @define-color accent_color #f0b53a;
    .card { padding: 6px; border-radius: 12px; }
    .count-badge { background-color: #e5a00d; color: rgba(0, 0, 0, 0.87); border-radius: 999px; padding: 1px 7px; font-weight: 800; font-size: 0.8em; min-width: 12px; }
    .cast-art { border-radius: 999px; background-color: alpha(currentColor, 0.08); }
    .genre-tile { border-radius: 10px; padding: 18px; min-height: 64px; font-weight: 800; font-size: 1.1em; color: white; }
    .detail-poster { border-radius: 10px; box-shadow: 0 8px 28px alpha(black, 0.55); }
    .rating { font-weight: 700; }
    .tint-0 { background-image: linear-gradient(135deg, #7b2ff7, #2a0a5e); }
    .tint-1 { background-image: linear-gradient(135deg, #e5a00d, #6b4500); }
    .tint-2 { background-image: linear-gradient(135deg, #1e88e5, #0b2f5c); }
    .tint-3 { background-image: linear-gradient(135deg, #d81b60, #4d0721); }
    .tint-4 { background-image: linear-gradient(135deg, #43a047, #0f3d12); }
    .tint-5 { background-image: linear-gradient(135deg, #f4511e, #5a1a05); }
    .tint-6 { background-image: linear-gradient(135deg, #00acc1, #00393f); }
    .tint-7 { background-image: linear-gradient(135deg, #8d6e63, #2e221d); }
    .alphabet-letter { min-height: 0; min-width: 0; padding: 0 6px; font-size: 0.75em; font-weight: 700; }
    .credit-title { color: alpha(currentColor, 0.6); }
    .card-art { border-radius: 8px; background-color: alpha(currentColor, 0.08); }
    .card-title { font-weight: 600; }
    .card-progress trough { min-height: 4px; border-radius: 2px; background-color: alpha(black, 0.55); }
    .card-progress progress { min-height: 4px; border-radius: 2px; background-color: @accent_bg_color; }
        .card-grid { padding: 18px; }
    .card-grid > child { padding: 4px; }
    .hero-shade { background-image: linear-gradient(to bottom, alpha(@window_bg_color, 0.1) 0%, alpha(@window_bg_color, 0.55) 55%, @window_bg_color 100%); }
    .played-on { color: @accent_color; }
    .player { background-color: black; }
    .player-top { background-image: linear-gradient(to bottom, alpha(black, 0.75), alpha(black, 0)); color: white; padding: 12px 18px 48px 18px; }
    .player-bottom { background-image: linear-gradient(to top, alpha(black, 0.85), alpha(black, 0)); color: white; padding: 48px 22px 14px 22px; }
    .player-top button, .player-bottom button { color: white; }
    .player-play { min-width: 52px; min-height: 52px; }
    .player-play image { -gtk-icon-size: 28px; }
    .player-bottom scale highlight { background-color: #e5a00d; }
    .player-bottom scale marks indicator { min-height: 8px; min-width: 3px; color: #e5a00d; }
    .player-time { font-feature-settings: "tnum"; color: alpha(white, 0.85); }
    .osd-pill { background-color: alpha(#141414, 0.88); color: white; border-radius: 999px; padding: 10px 22px; font-weight: 700; }
    .up-next { background-color: alpha(#141414, 0.94); color: white; border-radius: 14px; padding: 14px; }
    .stats { background-color: alpha(black, 0.7); color: white; border-radius: 10px; padding: 12px; font-family: monospace; font-size: 0.85em; }
    .seek-preview { background-color: alpha(#141414, 0.92); color: white; border-radius: 10px; padding: 6px; }
    .seek-preview picture { border-radius: 6px; }
    .seek-preview-time { font-feature-settings: "tnum"; font-weight: 700; }
    .error-box { background-color: alpha(black, 0.8); color: white; border-radius: 14px; padding: 20px; }
    .pin-dot { min-width: 14px; min-height: 14px; border-radius: 999px; border: 1.5px solid alpha(currentColor, 0.7); }
    .pin-dot.filled { background-color: currentColor; }
    .pin-key { min-width: 64px; min-height: 64px; font-size: 1.6em; font-weight: 400; }
    image.accent { color: #e5a00d; }
    @keyframes pin-shake { 0% { margin-left: 0; } 20% { margin-left: 18px; } 40% { margin-left: 0; margin-right: 18px; } 60% { margin-right: 0; margin-left: 12px; } 80% { margin-left: 0; margin-right: 8px; } 100% { margin-right: 0; } }
    .pin-shake { animation: pin-shake 0.4s ease-out; }
    """
}
