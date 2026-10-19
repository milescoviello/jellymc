import CGtk
import Foundation

/// No screen saver, dimming or lock while a video is open.
///
/// GTK's own inhibit reaches GNOME's session manager, but on Plasma it goes nowhere: Plasma
/// listed no inhibition with a video playing, and dimmed the screen over it. So the
/// freedesktop ScreenSaver interface, which Plasma, Xfce and most others implement, is
/// asked too. Both are held together and let go together.
@MainActor
final class IdleInhibitor {
    private var gtkCookie: guint = 0
    /// The session's cookie, once its answer comes back.
    private var screenSaverCookie: UInt32?
    private var wanted = false

    func hold(_ reason: String) {
        guard !wanted else { return }
        wanted = true
        if let application = Desktop.application {
            gtkCookie = gtk_application_inhibit(application.cast(), Desktop.window?.cast(), GTK_APPLICATION_INHIBIT_IDLE, reason)
        }
        // A D-Bus round trip, off the main thread: a session that is slow to answer must
        // not hold up the player.
        Task.detached {
            let cookie = Self.call("Inhibit", reason: reason)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.wanted {
                    self.screenSaverCookie = cookie
                } else if let cookie {
                    // Let go before the answer came: hand it straight back.
                    Task.detached { _ = Self.call("UnInhibit", cookie: cookie) }
                }
            }
        }
    }

    func release() {
        guard wanted else { return }
        wanted = false
        if gtkCookie != 0, let application = Desktop.application {
            gtk_application_uninhibit(application.cast(), gtkCookie)
        }
        gtkCookie = 0
        if let cookie = screenSaverCookie {
            screenSaverCookie = nil
            Task.detached { _ = Self.call("UnInhibit", cookie: cookie) }
        }
    }

    /// `Inhibit(app, reason) -> cookie` or `UnInhibit(cookie)` on the session bus.
    private nonisolated static func call(_ method: String, reason: String = "", cookie: UInt32 = 0) -> UInt32? {
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil) else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(bus)) }
        var arguments: [OpaquePointer?] = method == "Inhibit"
            ? [g_variant_new_string("jellymc"), g_variant_new_string(reason)]
            : [g_variant_new_uint32(cookie)]
        let parameters = arguments.withUnsafeMutableBufferPointer { buffer in
            g_variant_new_tuple(buffer.baseAddress, gsize(buffer.count))
        }
        let reply = g_dbus_connection_call_sync(
            bus, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
            method, parameters, nil, GDBusCallFlags(rawValue: 0), 3000, nil, nil
        )
        guard let reply else { return nil }
        defer { g_variant_unref(reply) }
        guard method == "Inhibit", let value = g_variant_get_child_value(reply, 0) else { return nil }
        defer { g_variant_unref(value) }
        return g_variant_get_uint32(value)
    }
}
