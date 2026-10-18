#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <EGL/egl.h>

// mpv asks for OpenGL entry points by name; GTK 4 on Wayland renders through EGL, so
// eglGetProcAddress answers for the context GtkGLArea makes current.
static inline void *cmpv_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    return (void *)eglGetProcAddress(name);
}

// GL_FRAMEBUFFER_BINDING, without pulling a GL header into Swift.
#define CMPV_GL_FRAMEBUFFER_BINDING 0x8CA6
typedef void (*cmpv_gl_get_integerv)(unsigned int, int *);

static inline int cmpv_current_framebuffer(void) {
    static cmpv_gl_get_integerv get = 0;
    if (!get) get = (cmpv_gl_get_integerv)eglGetProcAddress("glGetIntegerv");
    int fbo = 0;
    if (get) get(CMPV_GL_FRAMEBUFFER_BINDING, &fbo);
    return fbo;
}
