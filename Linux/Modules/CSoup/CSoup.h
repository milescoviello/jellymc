#include <libsoup/soup.h>

// libsoup's WebSocket client, for the server's socket: it runs in GLib's main loop, where
// the app's GTK code already is, and sleeps between messages. Foundation's on Linux spun
// a CPU core at 80% with nothing to say.

typedef void (*csoup_on_open)(SoupWebsocketConnection *connection, void *data);
typedef void (*csoup_on_fail)(const char *message, void *data);
typedef void (*csoup_on_text)(const char *text, gsize length, void *data);
typedef void (*csoup_on_closed)(void *data);

typedef struct {
    csoup_on_open open;
    csoup_on_fail fail;
    csoup_on_text text;
    csoup_on_closed closed;
    void *data;
} csoup_callbacks;

static inline void csoup_message_cb(SoupWebsocketConnection *self, gint type, GBytes *message, gpointer user) {
    (void)self;
    csoup_callbacks *callbacks = user;
    if (type != SOUP_WEBSOCKET_DATA_TEXT || !callbacks->text) return;
    gsize length = 0;
    const char *bytes = g_bytes_get_data(message, &length);
    callbacks->text(bytes, length, callbacks->data);
}

static inline void csoup_closed_cb(SoupWebsocketConnection *self, gpointer user) {
    (void)self;
    csoup_callbacks *callbacks = user;
    if (callbacks->closed) callbacks->closed(callbacks->data);
}

static inline void csoup_connected(GObject *source, GAsyncResult *result, gpointer user) {
    csoup_callbacks *callbacks = user;
    GError *error = NULL;
    SoupWebsocketConnection *connection = soup_session_websocket_connect_finish(SOUP_SESSION(source), result, &error);
    if (!connection) {
        if (callbacks->fail) callbacks->fail(error ? error->message : "could not connect", callbacks->data);
        if (error) g_error_free(error);
        return;
    }
    // The server sends a ForceKeepAlive and expects KeepAlive back; libsoup's own pings
    // keep the TCP side alive too.
    soup_websocket_connection_set_keepalive_interval(connection, 30);
    g_signal_connect(connection, "message", G_CALLBACK(csoup_message_cb), callbacks);
    g_signal_connect(connection, "closed", G_CALLBACK(csoup_closed_cb), callbacks);
    if (callbacks->open) callbacks->open(connection, callbacks->data);
}

/// Connects; the callbacks live until `csoup_free_callbacks`, after the connection is gone.
static inline void csoup_connect(SoupSession *session, const char *url, const char *authorization, csoup_callbacks *callbacks, GCancellable *cancellable) {
    SoupMessage *message = soup_message_new("GET", url);
    if (!message) {
        if (callbacks->fail) callbacks->fail("not a usable address", callbacks->data);
        return;
    }
    soup_message_headers_replace(soup_message_get_request_headers(message), "Authorization", authorization);
    soup_session_websocket_connect_async(session, message, NULL, NULL, G_PRIORITY_DEFAULT, cancellable, csoup_connected, callbacks);
    g_object_unref(message);
}
