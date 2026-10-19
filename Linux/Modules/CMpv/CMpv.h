#include <epoxy/gl.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <EGL/egl.h>
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif
#include <stdlib.h>

// The C half of drawing libmpv into a GtkGLArea. Everything here is plumbing Swift would
// write clumsily: parameter arrays terminated by an INVALID entry, function pointers mpv
// calls from its own threads, and macros.

// mpv asks for OpenGL entry points by name; GTK 4 renders through EGL on Wayland and on
// modern X11, so eglGetProcAddress answers for the context GtkGLArea makes current.
static inline void *cmpv_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    return (void *)eglGetProcAddress(name);
}

// mpv's hardware-decoding interop wants the Wayland display it will share buffers on.
static inline void *cmpv_wayland_display(GtkWidget *widget) {
#ifdef GDK_WINDOWING_WAYLAND
    GdkDisplay *display = gtk_widget_get_display(widget);
    if (GDK_IS_WAYLAND_DISPLAY(display)) return gdk_wayland_display_get_wl_display(display);
#endif
    (void)widget;
    return NULL;
}

static inline mpv_render_context *cmpv_render_context_create(mpv_handle *mpv, void *wl_display) {
    mpv_opengl_init_params gl = { .get_proc_address = cmpv_get_proc_address, .get_proc_address_ctx = NULL };
    mpv_render_param params[4];
    int n = 0;
    params[n++] = (mpv_render_param){ MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL };
    params[n++] = (mpv_render_param){ MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl };
    if (wl_display) params[n++] = (mpv_render_param){ MPV_RENDER_PARAM_WL_DISPLAY, wl_display };
    params[n] = (mpv_render_param){ MPV_RENDER_PARAM_INVALID, NULL };
    mpv_render_context *ctx = NULL;
    if (mpv_render_context_create(&ctx, mpv, params) < 0) return NULL;
    return ctx;
}

// GtkGLArea renders into its own framebuffer, not 0. Through libepoxy, which GTK itself
// uses, so the call resolves for whichever API (GL or GLES) the area was given.
static inline int cmpv_current_framebuffer(void) {
    GLint fbo = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    return fbo;
}


static inline int cmpv_render(mpv_render_context *ctx, int width, int height) {
    mpv_opengl_fbo target = { .fbo = cmpv_current_framebuffer(), .w = width, .h = height, .internal_format = 0 };
    int flip = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &target },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    return mpv_render_context_render(ctx, params);
}

// A new frame is ready: called on one of mpv's threads, so the redraw is posted to GTK's.
// The area is referenced until the idle runs, so it cannot be finalized under it.
static inline gboolean cmpv_render_idle(gpointer area) {
    gtk_gl_area_queue_render(GTK_GL_AREA(area));
    return G_SOURCE_REMOVE;
}

static inline void cmpv_on_update(void *area) {
    g_idle_add_full(G_PRIORITY_HIGH_IDLE, cmpv_render_idle, g_object_ref(area), g_object_unref);
}
// The context's renderer, current in the calling thread: "llvmpipe (LLVM 21...)" for
// Mesa's software rasterizer.
static inline const char *cmpv_gl_renderer(void) {
    return (const char *)glGetString(GL_RENDERER);
}

static inline void cmpv_set_update_area(mpv_render_context *ctx, GtkWidget *area) {
    mpv_render_context_set_update_callback(ctx, area ? cmpv_on_update : NULL, area);
}

// mpv has events: called on one of its threads; the drain runs on GTK's.
typedef void (*cmpv_drain)(void *data);

typedef struct {
    cmpv_drain drain;
    void *data;
} cmpv_wakeup;

static inline gboolean cmpv_wakeup_idle(gpointer p) {
    cmpv_wakeup *wakeup = p;
    if (wakeup->drain) wakeup->drain(wakeup->data);
    return G_SOURCE_REMOVE;
}

static inline void cmpv_on_wakeup(void *p) {
    g_idle_add(cmpv_wakeup_idle, p);
}

static inline cmpv_wakeup *cmpv_wakeup_install(mpv_handle *mpv, cmpv_drain drain, void *data) {
    cmpv_wakeup *wakeup = malloc(sizeof *wakeup);
    wakeup->drain = drain;
    wakeup->data = data;
    mpv_set_wakeup_callback(mpv, cmpv_on_wakeup, wakeup);
    return wakeup;
}

// After mpv_terminate_destroy no new wakeups come, but some may still be queued; this one
// is queued after them, so it frees the record once they have run.
typedef void (*cmpv_release)(void *data);

typedef struct {
    cmpv_wakeup *wakeup;
    cmpv_release release;
} cmpv_retirement;

static inline gboolean cmpv_retire_idle(gpointer p) {
    cmpv_retirement *retirement = p;
    if (retirement->release) retirement->release(retirement->wakeup->data);
    free(retirement->wakeup);
    free(retirement);
    return G_SOURCE_REMOVE;
}

static inline void cmpv_wakeup_retire(cmpv_wakeup *wakeup, cmpv_release release) {
    wakeup->drain = NULL;
    cmpv_retirement *retirement = malloc(sizeof *retirement);
    retirement->wakeup = wakeup;
    retirement->release = release;
    g_idle_add(cmpv_retire_idle, retirement);
}

// The event's payload, typed: what mpv_event's void pointer holds for each event Swift reads.
static inline mpv_event_property *cmpv_event_property(mpv_event *event) {
    return (mpv_event_property *)event->data;
}

static inline mpv_event_end_file *cmpv_event_end_file(mpv_event *event) {
    return (mpv_event_end_file *)event->data;
}

static inline mpv_event_log_message *cmpv_event_log(mpv_event *event) {
    return (mpv_event_log_message *)event->data;
}
