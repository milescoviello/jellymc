import CGtk
import Foundation

/// The desktop's media controls: MPRIS over D-Bus.
///
/// Plasma's media applet, the keyboard's media keys, `playerctl` and a paired phone's KDE
/// Connect all drive whatever player publishes `org.mpris.MediaPlayer2`, so this one
/// object is every remote control the desktop has. Adapted from the Music app's
/// NowPlayingCenter: the same publishing rules, for whatever is playing.
///
/// Elapsed time is published on transitions only, with the rate, and clients extrapolate;
/// `Position` is computed when asked, and `Seeked` is sent when an update lands where
/// extrapolation would not have — which is what MPRIS asks for instead of a timer.
@MainActor
final class MediaControls {
    static let shared = MediaControls()

    struct Track: Equatable {
        var id: String
        var title: String
        /// The series for an episode, the artist for a song.
        var artist: String?
        var album: String?
        var duration: Double
    }

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private struct State {
        var track: Track?
        var elapsed: Double = 0
        var stamp = Date.now
        var isPlaying = false
        var rate: Double = 1
        var canGoNext = false
        var artURL: URL?
    }

    private var state = State()
    private var connection: OpaquePointer?
    private var owner: guint = 0

    private static let objectPath = "/org/mpris/MediaPlayer2"
    private static let busName = "org.mpris.MediaPlayer2.jellymc"

    private init() {
        let data = Unmanaged.passUnretained(self).toOpaque()
        owner = g_bus_own_name(
            G_BUS_TYPE_SESSION,
            Self.busName,
            GBusNameOwnerFlags(rawValue: 0),
            { connection, _, data in
                guard let connection, let data else { return }
                let controls = Unmanaged<MediaControls>.fromOpaque(data).takeUnretainedValue()
                nonisolated(unsafe) let pointer = connection
                MainActor.assumeIsolated { controls.register(on: pointer) }
            },
            nil,
            nil,
            data,
            nil
        )
    }

    // MARK: - Publishing

    func update(track: Track, elapsed: Double, isPlaying: Bool, rate: Double = 1, canGoNext: Bool) {
        let previous = state
        let sameTrack = previous.track?.id == track.id
        state.track = track
        state.elapsed = elapsed
        state.stamp = .now
        state.isPlaying = isPlaying
        state.rate = rate
        state.canGoNext = canGoNext
        if !sameTrack { state.artURL = nil }

        var changed: [String: OpaquePointer] = [:]
        if previous.track != track { changed["Metadata"] = metadata() }
        if previous.isPlaying != isPlaying || previous.track == nil { changed["PlaybackStatus"] = playbackStatus() }
        if previous.rate != rate { changed["Rate"] = g_variant_new_double(rate) }
        if previous.canGoNext != canGoNext || previous.track == nil {
            changed["CanGoNext"] = g_variant_new_boolean(canGoNext ? 1 : 0)
        }
        emitChanged(changed)

        if sameTrack {
            let expected = Self.position(previous, at: state.stamp)
            if abs(expected - elapsed) > 1.5 { emitSeeked(elapsed) }
        }
    }

    /// Written to a file: an MPRIS client is handed a URL rather than pixels, and the
    /// server's URL would hand every client on the desktop the account's token.
    func setArtwork(_ texture: Texture, for id: String) {
        let directory = Paths.cache.appendingPathComponent("now-playing", isDirectory: true)
        let url = directory.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".png")
        let image = Unchecked(texture)
        Task {
            let written = await Task.detached(priority: .utility) { () -> Bool in
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let data = image.value.pngData() else { return false }
                return (try? data.write(to: url, options: .atomic)) != nil
            }.value
            guard written, state.track?.id == id else { return }
            state.artURL = url
            emitChanged(["Metadata": metadata()])
        }
    }

    func clear() {
        state = State()
        emitChanged(["Metadata": metadata(), "PlaybackStatus": playbackStatus()])
        onPlay = nil
        onPause = nil
        onToggle = nil
        onNext = nil
        onPrevious = nil
        onSeek = nil
    }

    // MARK: - Values

    private static func position(_ state: State, at time: Date) -> Double {
        guard state.isPlaying else { return state.elapsed }
        let moved = state.elapsed + time.timeIntervalSince(state.stamp) * state.rate
        guard let duration = state.track?.duration, duration > 0 else { return moved }
        return min(moved, duration)
    }

    private func playbackStatus() -> OpaquePointer {
        let status = state.track == nil ? "Stopped" : (state.isPlaying ? "Playing" : "Paused")
        return g_variant_new_string(status)
    }

    private static func trackPath(_ id: String?) -> String {
        guard let id else { return "/org/mpris/MediaPlayer2/TrackList/NoTrack" }
        let safe = id.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? String(scalar) : "_"
        }.joined()
        return "/com/milescoviello/jellymc/item/i\(safe)"
    }

    private func metadata() -> OpaquePointer {
        var entries: [(String, OpaquePointer)] = [
            ("mpris:trackid", g_variant_new_object_path(Self.trackPath(state.track?.id))),
        ]
        if let track = state.track {
            entries.append(("xesam:title", g_variant_new_string(track.title)))
            if let artist = track.artist { entries.append(("xesam:artist", Self.strings([artist]))) }
            if let album = track.album { entries.append(("xesam:album", g_variant_new_string(album))) }
            entries.append(("mpris:length", g_variant_new_int64(gint64(track.duration * 1_000_000))))
            if let art = state.artURL { entries.append(("mpris:artUrl", g_variant_new_string(art.absoluteString))) }
        }
        return Self.dictionary(entries)
    }

    private static func strings(_ values: [String]) -> OpaquePointer {
        var children = values.map { g_variant_new_string($0) }
        return g_variant_new_array(cgtk_type_string(), &children, gsize(children.count))
    }

    /// An `a{sv}`.
    private static func dictionary(_ entries: [(String, OpaquePointer)]) -> OpaquePointer {
        var children = entries.map { key, value in
            g_variant_new_dict_entry(g_variant_new_string(key), g_variant_new_variant(value))
        }
        return g_variant_new_array(cgtk_type_vardict_entry(), &children, gsize(children.count))
    }

    private func property(_ name: String) -> OpaquePointer? {
        switch name {
        case "CanQuit", "CanRaise": return g_variant_new_boolean(1)
        case "HasTrackList": return g_variant_new_boolean(0)
        case "Identity": return g_variant_new_string("jellymc")
        case "DesktopEntry": return g_variant_new_string(Desktop.applicationID)
        case "SupportedUriSchemes", "SupportedMimeTypes": return Self.strings([])
        case "PlaybackStatus": return playbackStatus()
        case "Rate": return g_variant_new_double(state.rate)
        case "MinimumRate": return g_variant_new_double(0.5)
        case "MaximumRate": return g_variant_new_double(2)
        case "Metadata": return metadata()
        case "Volume": return g_variant_new_double(1)
        case "Position": return g_variant_new_int64(gint64(Self.position(state, at: .now) * 1_000_000))
        case "CanGoNext": return g_variant_new_boolean(state.canGoNext ? 1 : 0)
        case "CanGoPrevious", "CanPlay", "CanPause", "CanSeek":
            return g_variant_new_boolean(state.track == nil ? 0 : 1)
        case "CanControl": return g_variant_new_boolean(1)
        default: return nil
        }
    }

    private func call(_ method: String, _ parameters: OpaquePointer?) {
        switch method {
        case "Raise": Desktop.raise()
        case "Quit":
            if let application = Desktop.application { g_application_quit(application.cast()) }
        case "Play": onPlay?()
        case "Pause", "Stop": onPause?()
        case "PlayPause": onToggle?()
        case "Next": onNext?()
        case "Previous": onPrevious?()
        case "Seek":
            guard let parameters else { return }
            let offset = Double(g_variant_get_int64(g_variant_get_child_value(parameters, 0))) / 1_000_000
            onSeek?(max(0, Self.position(state, at: .now) + offset))
        case "SetPosition":
            guard let parameters else { return }
            let path = String(cString: g_variant_get_string(g_variant_get_child_value(parameters, 0), nil))
            let position = Double(g_variant_get_int64(g_variant_get_child_value(parameters, 1))) / 1_000_000
            guard path == Self.trackPath(state.track?.id), position >= 0 else { return }
            onSeek?(position)
        default:
            break
        }
    }

    // MARK: - D-Bus

    private func register(on connection: OpaquePointer) {
        self.connection = connection
        var error: UnsafeMutablePointer<GError>?
        guard let node = g_dbus_node_info_new_for_xml(Self.introspection, &error) else {
            if let error { g_error_free(error) }
            return
        }
        defer { g_dbus_node_info_unref(node) }

        var table = GDBusInterfaceVTable()
        table.method_call = { _, _, _, _, method, parameters, invocation, data in
            guard let data, let method else { return }
            let controls = Unmanaged<MediaControls>.fromOpaque(data).takeUnretainedValue()
            let name = String(cString: method)
            nonisolated(unsafe) let parameters = parameters
            MainActor.assumeIsolated { controls.call(name, parameters) }
            g_dbus_method_invocation_return_value(invocation, nil)
        }
        table.get_property = { _, _, _, _, property, _, data in
            guard let data, let property else { return nil }
            let controls = Unmanaged<MediaControls>.fromOpaque(data).takeUnretainedValue()
            let name = String(cString: property)
            return MainActor.assumeIsolated { Unchecked(controls.property(name)) }.value
        }
        // Volume and Rate are accepted and ignored; a client that writes one must not get
        // an error.
        table.set_property = { _, _, _, _, _, _, _, _ in 1 }

        let data = Unmanaged.passUnretained(self).toOpaque()
        for name in ["org.mpris.MediaPlayer2", "org.mpris.MediaPlayer2.Player"] {
            guard let interface = g_dbus_node_info_lookup_interface(node, name) else { continue }
            g_dbus_connection_register_object(connection, Self.objectPath, interface, &table, data, nil, nil)
        }
    }

    private func emitChanged(_ properties: [String: OpaquePointer]) {
        guard let connection, !properties.isEmpty else {
            for value in properties.values { g_variant_unref(g_variant_ref_sink(value)) }
            return
        }
        var children: [OpaquePointer?] = [
            g_variant_new_string("org.mpris.MediaPlayer2.Player"),
            Self.dictionary(properties.map { ($0.key, $0.value) }),
            Self.strings([]),
        ]
        let parameters = g_variant_new_tuple(&children, gsize(children.count))
        g_dbus_connection_emit_signal(connection, nil, Self.objectPath, "org.freedesktop.DBus.Properties", "PropertiesChanged", parameters, nil)
    }

    private func emitSeeked(_ seconds: Double) {
        guard let connection else { return }
        var children: [OpaquePointer?] = [g_variant_new_int64(gint64(seconds * 1_000_000))]
        g_dbus_connection_emit_signal(connection, nil, Self.objectPath, "org.mpris.MediaPlayer2.Player", "Seeked", g_variant_new_tuple(&children, 1), nil)
    }

    private static let introspection = """
    <node>
      <interface name="org.mpris.MediaPlayer2">
        <method name="Raise"/>
        <method name="Quit"/>
        <property name="CanQuit" type="b" access="read"/>
        <property name="CanRaise" type="b" access="read"/>
        <property name="HasTrackList" type="b" access="read"/>
        <property name="Identity" type="s" access="read"/>
        <property name="DesktopEntry" type="s" access="read"/>
        <property name="SupportedUriSchemes" type="as" access="read"/>
        <property name="SupportedMimeTypes" type="as" access="read"/>
      </interface>
      <interface name="org.mpris.MediaPlayer2.Player">
        <method name="Next"/>
        <method name="Previous"/>
        <method name="Pause"/>
        <method name="PlayPause"/>
        <method name="Stop"/>
        <method name="Play"/>
        <method name="Seek"><arg direction="in" name="Offset" type="x"/></method>
        <method name="SetPosition">
          <arg direction="in" name="TrackId" type="o"/>
          <arg direction="in" name="Position" type="x"/>
        </method>
        <method name="OpenUri"><arg direction="in" name="Uri" type="s"/></method>
        <signal name="Seeked"><arg name="Position" type="x"/></signal>
        <property name="PlaybackStatus" type="s" access="read"/>
        <property name="Rate" type="d" access="readwrite"/>
        <property name="Metadata" type="a{sv}" access="read"/>
        <property name="Volume" type="d" access="readwrite"/>
        <property name="Position" type="x" access="read"/>
        <property name="MinimumRate" type="d" access="read"/>
        <property name="MaximumRate" type="d" access="read"/>
        <property name="CanGoNext" type="b" access="read"/>
        <property name="CanGoPrevious" type="b" access="read"/>
        <property name="CanPlay" type="b" access="read"/>
        <property name="CanPause" type="b" access="read"/>
        <property name="CanSeek" type="b" access="read"/>
        <property name="CanControl" type="b" access="read"/>
      </interface>
    </node>
    """
}
