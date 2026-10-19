import CGtk
import CSoup
import Foundation

/// A WebSocket that hands text messages to the main actor, and says once when it is gone.
/// libsoup here, in GLib's main loop with the rest of the app: it sleeps until the server
/// says something. Foundation's URLSessionWebSocketTask on Linux kept its write source
/// armed and spun the dispatch manager thread at 80% of a core, with nothing to send.
@MainActor
final class SocketTransport {
    var onText: (@MainActor (String) -> Void)?
    /// Called once, with why, when the socket closes or could not open. Not after `close()`.
    var onClose: (@MainActor (String) -> Void)?

    private let url: String
    private let authorization: String
    nonisolated(unsafe) private let session: OpaquePointer
    nonisolated(unsafe) private let cancellable: UnsafeMutablePointer<GCancellable>
    private var connection: OpaquePointer?
    private var callbacks: UnsafeMutablePointer<csoup_callbacks>?
    private var closed = false

    init(url: URL, authorization: String) {
        self.url = url.absoluteString
        self.authorization = authorization
        session = OpaquePointer(UnsafeMutableRawPointer(soup_session_new()!))
        cancellable = g_cancellable_new()!
    }

    func open() {
        let callbacks = UnsafeMutablePointer<csoup_callbacks>.allocate(capacity: 1)
        callbacks.initialize(to: csoup_callbacks(
            open: { connection, data in
                guard let data, let connection else { return }
                let socket = Unmanaged<SocketTransport>.fromOpaque(data).takeUnretainedValue()
                nonisolated(unsafe) let pointer = connection
                MainActor.assumeIsolated { socket.opened(pointer) }
            },
            fail: { message, data in
                guard let data else { return }
                let socket = Unmanaged<SocketTransport>.fromOpaque(data).takeUnretainedValue()
                let text = message.map { String(cString: $0) } ?? "could not connect"
                MainActor.assumeIsolated { socket.ended(text) }
            },
            text: { bytes, length, data in
                guard let data, let bytes else { return }
                let socket = Unmanaged<SocketTransport>.fromOpaque(data).takeUnretainedValue()
                let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(length)), as: UTF8.self)
                MainActor.assumeIsolated { socket.onText?(text) }
            },
            closed: { data in
                guard let data else { return }
                let socket = Unmanaged<SocketTransport>.fromOpaque(data).takeUnretainedValue()
                MainActor.assumeIsolated { socket.ended("the server closed it") }
            },
            // Held until the callbacks are freed, so a late one never finds it gone.
            data: Unmanaged.passRetained(self).toOpaque()
        ))
        self.callbacks = callbacks
        csoup_connect(session.cast(), url, authorization, callbacks, cancellable)
    }

    func send(_ text: String) {
        guard let connection, !closed else { return }
        soup_websocket_connection_send_text(connection.cast(), text)
    }

    func close() {
        guard !closed else { return }
        closed = true
        g_cancellable_cancel(cancellable)
        if let connection, soup_websocket_connection_get_state(connection.cast()) == SOUP_WEBSOCKET_STATE_OPEN {
            soup_websocket_connection_close(connection.cast(), gushort(SOUP_WEBSOCKET_CLOSE_GOING_AWAY.rawValue), nil)
        }
        release()
    }

    private func opened(_ connection: OpaquePointer) {
        guard !closed else {
            soup_websocket_connection_close(connection.cast(), gushort(SOUP_WEBSOCKET_CLOSE_GOING_AWAY.rawValue), nil)
            g_object_unref(UnsafeMutableRawPointer(connection))
            return
        }
        self.connection = connection
    }

    private func ended(_ reason: String) {
        guard !closed else { return }
        closed = true
        release()
        onClose?(reason)
    }

    /// Lets go of the connection and, on the next turn of the loop (libsoup may still be in
    /// the middle of calling us), of the callbacks and the hold on self.
    private func release() {
        if let connection {
            g_signal_handlers_disconnect_matched(UnsafeMutableRawPointer(connection), GSignalMatchType(rawValue: 1 << 4), 0, 0, nil, nil, callbacks)
            g_object_unref(UnsafeMutableRawPointer(connection))
            self.connection = nil
        }
        guard let callbacks else { return }
        self.callbacks = nil
        nonisolated(unsafe) let pointer = callbacks
        Task { @MainActor in
            if let data = pointer.pointee.data { Unmanaged<SocketTransport>.fromOpaque(data).release() }
            pointer.deallocate()
        }
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(cancellable))
        g_object_unref(UnsafeMutableRawPointer(session))
    }
}
