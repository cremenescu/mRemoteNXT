/* SPDX-License-Identifier: GPL-2.0-or-later
 * mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
 * See LICENSE for full text.
 */

#include "RDPCore.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/input.h>
#include <freerdp/event.h>
#include <winpr/synch.h>
#include <winpr/error.h>
#include <winpr/wlog.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static UINT32 deviceScaleFor(int scalePercent) {
    if (scalePercent >= 180) return 180;
    if (scalePercent >= 140) return 140;
    return 100;
}

void rdpcore_set_diagnostic_logging(int enabled, const char *dir) {
    wLog *root = WLog_GetRoot();
    if (!root) return;
    if (enabled && dir && dir[0]) {
        WLog_SetLogAppenderType(root, WLOG_APPENDER_FILE);
        wLogAppender *appender = WLog_GetLogAppender(root);
        if (appender) {
            WLog_ConfigureAppender(appender, "outputfilename", (void *)"mRemoteNXT.log");
            WLog_ConfigureAppender(appender, "outputfilepath", (void *)(uintptr_t)dir);
        }
        WLog_OpenAppender(root);
        WLog_SetLogLevel(root, WLOG_DEBUG);
    } else {
        // Effectively silence: only errors, to the default (invisible in a GUI app).
        WLog_SetLogLevel(root, WLOG_ERROR);
    }
}

// Custom context: must start with rdpClientContext (FreeRDP client pattern).
typedef struct {
    rdpClientContext common;
    RDPCore *core;
} mrngContext;

struct RDPCore {
    rdpContext *context; // created by freerdp_client_context_new
    pthread_t thread;
    volatile int stopRequested;
    int started;

    char *host, *user, *domain, *pass;
    int port, width, height, scalePercent;

    DispClientContext *disp;

    RDPCoreCallbacks cb;
    void *ctx;
};

static RDPCore *coreFromContext(rdpContext *context) {
    return ((mrngContext *)context)->core;
}

static void notifyDisconnected(RDPCore *core, const char *err) {
    if (core->cb.onDisconnected) core->cb.onDisconnected(core->ctx, err);
}

// MARK: - Update / graphics

static BOOL mrng_begin_paint(rdpContext *context) { (void)context; return TRUE; }

static BOOL mrng_end_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary_buffer) return TRUE;
    RDPCore *core = coreFromContext(context);
    if (core->cb.onImage)
        core->cb.onImage(core->ctx, gdi->primary_buffer, (int)gdi->width, (int)gdi->height, (int)gdi->stride);
    return TRUE;
}

static BOOL mrng_desktop_resize(rdpContext *context) {
    rdpSettings *s = context->settings;
    UINT32 w = freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, w, h)) return FALSE;
    RDPCore *core = coreFromContext(context);
    if (core->cb.onConnected) core->cb.onConnected(core->ctx, (int)w, (int)h);
    return TRUE;
}

// MARK: - Channels (disp for live resize)

static void on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    rdpContext *ctx = (rdpContext *)context;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        coreFromContext(ctx)->disp = (DispClientContext *)e->pInterface;
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        // Wire the GFX pipeline to gdi -> codec updates (H264/progressive) land in the framebuffer.
        if (ctx->gdi) gdi_graphics_pipeline_init(ctx->gdi, (RdpgfxClientContext *)e->pInterface);
    }
}

static void on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    rdpContext *ctx = (rdpContext *)context;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        coreFromContext(ctx)->disp = NULL;
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        if (ctx->gdi) gdi_graphics_pipeline_uninit(ctx->gdi, (RdpgfxClientContext *)e->pInterface);
    }
}

// MARK: - Instance lifecycle callbacks

static BOOL mrng_pre_connect(freerdp *instance) {
    // The client/common layer wires the channels itself (LoadChannels) -> no need to call load_addins manually.
    (void)instance;
    return TRUE;
}

static BOOL mrng_post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    rdpContext *context = instance->context;
    context->update->BeginPaint = mrng_begin_paint;
    context->update->EndPaint = mrng_end_paint;
    context->update->DesktopResize = mrng_desktop_resize;
    RDPCore *core = coreFromContext(context);
    if (core->cb.onConnected)
        core->cb.onConnected(core->ctx, (int)context->gdi->width, (int)context->gdi->height);
    return TRUE;
}

static void mrng_post_disconnect(freerdp *instance) { gdi_free(instance); }

static DWORD mrng_verify_cert_ex(freerdp *instance, const char *host, UINT16 port,
                                 const char *common_name, const char *subject,
                                 const char *issuer, const char *fingerprint, DWORD flags) {
    (void)instance; (void)host; (void)port; (void)common_name;
    (void)subject; (void)issuer; (void)fingerprint; (void)flags;
    return 2; // accept and remember (self-signed on LAN)
}

// MARK: - Client entry points

static void *thread_proc(void *arg) {
    RDPCore *core = (RDPCore *)arg;
    freerdp *instance = core->context->instance;

    if (!freerdp_connect(instance)) {
        UINT32 err = freerdp_get_last_error(core->context);
        const char *name = freerdp_get_last_error_name(err);
        char msg[256];
        snprintf(msg, sizeof(msg), "Connection failed: %s", name ? name : "unknown");
        notifyDisconnected(core, msg);
        return NULL;
    }

    rdpContext *context = core->context;
    while (!core->stopRequested && !freerdp_shall_disconnect_context(context)) {
        HANDLE handles[64];
        DWORD n = freerdp_get_event_handles(context, handles, 64);
        if (n == 0) break;
        DWORD st = WaitForMultipleObjects(n, handles, FALSE, 200);
        if (st == WAIT_FAILED) break;
        if (!freerdp_check_event_handles(context)) break;
    }

    freerdp_disconnect(instance);

    // Report the reason: nothing if the user closed it, otherwise the last error / "closed by server".
    const char *msg = NULL;
    char buf[256];
    if (!core->stopRequested) {
        UINT32 err = freerdp_get_last_error(core->context);
        if (err != FREERDP_ERROR_SUCCESS) {
            const char *name = freerdp_get_last_error_name(err);
            snprintf(buf, sizeof(buf), "Disconnected: %s", name ? name : "unknown");
            msg = buf;
        } else {
            msg = "Session closed (possibly taken over by another connection).";
        }
    }
    notifyDisconnected(core, msg);
    return NULL;
}

static BOOL mrng_client_global_init(void) { return TRUE; }
static void mrng_client_global_uninit(void) {}

static BOOL mrng_client_new(freerdp *instance, rdpContext *context) {
    (void)context;
    instance->PreConnect = mrng_pre_connect;
    instance->PostConnect = mrng_post_connect;
    instance->PostDisconnect = mrng_post_disconnect;
    instance->VerifyCertificateEx = mrng_verify_cert_ex;
    PubSub_SubscribeChannelConnected(context->pubSub, on_channel_connected);
    PubSub_SubscribeChannelDisconnected(context->pubSub, on_channel_disconnected);
    return TRUE;
}

static void mrng_client_free(freerdp *instance, rdpContext *context) {
    (void)instance; (void)context;
}

static int mrng_client_start(rdpContext *context) {
    RDPCore *core = coreFromContext(context);
    if (core->started) return 0;
    core->started = 1;
    pthread_create(&core->thread, NULL, thread_proc, core);
    return 0;
}

static int mrng_client_stop(rdpContext *context) {
    RDPCore *core = coreFromContext(context);
    core->stopRequested = 1;
    freerdp_abort_connect_context(context);
    return 0;
}

// MARK: - Public API

static char *dupstr(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

RDPCore *rdpcore_create(const char *host, int port, const char *user,
                        const char *domain, const char *pass,
                        int width, int height, int scalePercent,
                        RDPCoreCallbacks cb, void *ctx) {
    RDPCore *core = calloc(1, sizeof(RDPCore));
    if (!core) return NULL;
    core->host = dupstr(host);
    core->user = dupstr(user);
    core->domain = dupstr(domain);
    core->pass = dupstr(pass);
    core->port = port > 0 ? port : 3389;
    core->width = width > 0 ? width : 1280;
    core->height = height > 0 ? height : 800;
    core->scalePercent = (scalePercent >= 100 && scalePercent <= 500) ? scalePercent : 100;
    core->cb = cb;
    core->ctx = ctx;

    RDP_CLIENT_ENTRY_POINTS ep;
    memset(&ep, 0, sizeof(ep));
    ep.Size = sizeof(ep);
    ep.Version = RDP_CLIENT_INTERFACE_VERSION;
    ep.ContextSize = sizeof(mrngContext);
    ep.GlobalInit = mrng_client_global_init;
    ep.GlobalUninit = mrng_client_global_uninit;
    ep.ClientNew = mrng_client_new;
    ep.ClientFree = mrng_client_free;
    ep.ClientStart = mrng_client_start;
    ep.ClientStop = mrng_client_stop;

    rdpContext *context = freerdp_client_context_new(&ep);
    if (!context) {
        free(core->host); free(core->user); free(core->domain); free(core->pass);
        free(core);
        return NULL;
    }
    ((mrngContext *)context)->core = core;
    core->context = context;

    rdpSettings *s = context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, core->host);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)core->port);
    if (core->user && core->user[0])     freerdp_settings_set_string(s, FreeRDP_Username, core->user);
    if (core->domain && core->domain[0]) freerdp_settings_set_string(s, FreeRDP_Domain, core->domain);
    if (core->pass && core->pass[0])     freerdp_settings_set_string(s, FreeRDP_Password, core->pass);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)core->width);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)core->height);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, TRUE);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, (UINT32)core->scalePercent);
    freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor, deviceScaleFor(core->scalePercent));
    freerdp_settings_set_bool(s, FreeRDP_SupportDynamicChannels, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, TRUE);
    // GFX pipeline (essential on Win10/11 — otherwise it falls back to the slow legacy bitmap path).
    // The pipeline is wired to gdi in on_channel_connected (RDPGFX_DVC_CHANNEL_NAME).
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_NetworkAutoDetect, TRUE);

    return core;
}

void rdpcore_start(RDPCore *core) {
    if (!core || !core->context) return;
    freerdp_client_start(core->context); // -> ClientStart -> thread_proc
}

void rdpcore_stop(RDPCore *core) {
    if (!core || !core->context) return;
    freerdp_client_stop(core->context);
}

void rdpcore_free(RDPCore *core) {
    if (!core) return;
    if (core->context) {
        core->stopRequested = 1;
        freerdp_abort_connect_context(core->context);
        if (core->started) pthread_join(core->thread, NULL);
        freerdp_client_context_free(core->context);
        core->context = NULL;
    }
    free(core->host); free(core->user); free(core->domain); free(core->pass);
    free(core);
}

void rdpcore_resize(RDPCore *core, int width, int height, int scalePercent) {
    if (!core) return;
    width -= width % 2; height -= height % 2;
    core->width = width; core->height = height;
    core->scalePercent = (scalePercent >= 100 && scalePercent <= 500) ? scalePercent : 100;
    DispClientContext *disp = core->disp;
    if (!disp || !disp->SendMonitorLayout) return;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
    memset(&layout, 0, sizeof(layout));
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = (UINT32)width;
    layout.Height = (UINT32)height;
    layout.Orientation = 0;
    layout.DesktopScaleFactor = (UINT32)core->scalePercent;
    layout.DeviceScaleFactor = deviceScaleFor(core->scalePercent);
    disp->SendMonitorLayout(disp, 1, &layout);
}

static rdpInput *coreInput(RDPCore *core) {
    return (core && core->context) ? core->context->input : NULL;
}

void rdpcore_mouse_move(RDPCore *core, int x, int y) {
    rdpInput *in = coreInput(core); if (!in) return;
    freerdp_input_send_mouse_event(in, PTR_FLAGS_MOVE, (UINT16)x, (UINT16)y);
}

void rdpcore_mouse_button(RDPCore *core, int button, bool down, int x, int y) {
    rdpInput *in = coreInput(core); if (!in) return;
    UINT16 flags = down ? PTR_FLAGS_DOWN : 0;
    switch (button) {
        case 1: flags |= PTR_FLAGS_BUTTON1; break;
        case 2: flags |= PTR_FLAGS_BUTTON2; break;
        case 3: flags |= PTR_FLAGS_BUTTON3; break;
        default: return;
    }
    freerdp_input_send_mouse_event(in, flags, (UINT16)x, (UINT16)y);
}

void rdpcore_scroll(RDPCore *core, int steps, int x, int y) {
    rdpInput *in = coreInput(core); if (!in) return;
    int delta = steps * 120;
    UINT16 flags = PTR_FLAGS_WHEEL;
    if (delta < 0) { flags |= PTR_FLAGS_WHEEL_NEGATIVE; delta = -delta; }
    if (delta > 0xFF) delta = 0xFF;
    flags |= (UINT16)(delta & 0xFF);
    freerdp_input_send_mouse_event(in, flags, (UINT16)x, (UINT16)y);
}

void rdpcore_key_unicode(RDPCore *core, uint16_t unicode, bool down) {
    rdpInput *in = coreInput(core); if (!in) return;
    UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;
    freerdp_input_send_unicode_keyboard_event(in, flags, unicode);
}

void rdpcore_key_special(RDPCore *core, int key, bool down) {
    rdpInput *in = coreInput(core); if (!in) return;
    UINT8 code = 0; BOOL ext = FALSE;
    switch (key) {
        case RDPCORE_KEY_ENTER:     code = 0x1C; break;
        case RDPCORE_KEY_BACKSPACE: code = 0x0E; break;
        case RDPCORE_KEY_TAB:       code = 0x0F; break;
        case RDPCORE_KEY_ESCAPE:    code = 0x01; break;
        case RDPCORE_KEY_SPACE:     code = 0x39; break;
        case RDPCORE_KEY_UP:        code = 0x48; ext = TRUE; break;
        case RDPCORE_KEY_DOWN:      code = 0x50; ext = TRUE; break;
        case RDPCORE_KEY_LEFT:      code = 0x4B; ext = TRUE; break;
        case RDPCORE_KEY_RIGHT:     code = 0x4D; ext = TRUE; break;
        case RDPCORE_KEY_DELETE:    code = 0x53; ext = TRUE; break;
        case RDPCORE_KEY_SHIFT:     code = 0x2A; break;
        case RDPCORE_KEY_CONTROL:   code = 0x1D; break;
        case RDPCORE_KEY_ALT:       code = 0x38; break;
        case RDPCORE_KEY_COMMAND:   code = 0x5B; ext = TRUE; break;
        default: return;
    }
    UINT16 flags = down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    if (ext) flags |= KBD_FLAGS_EXTENDED;
    freerdp_input_send_keyboard_event(in, flags, code);
}
