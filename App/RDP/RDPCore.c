/* SPDX-License-Identifier: GPL-2.0-or-later
 * mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
 * See LICENSE for full text.
 */

#include "RDPCore.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/client/cmdline.h>   // freerdp_client_add_device_channel
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

#include <openssl/provider.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>                    // isalnum (share name sanitising)

static UINT32 deviceScaleFor(int scalePercent) {
    if (scalePercent >= 180) return 180;
    if (scalePercent >= 140) return 140;
    return 100;
}

void rdpcore_init_crypto(const char *modules_dir) {
    static int done = 0;
    if (done) return;
    done = 1;
    // OpenSSL 3 moved MD4 into the "legacy" provider — a separate loadable
    // module (legacy.dylib) that is neither built into libcrypto nor activated
    // by default. NLA/CredSSP against a standalone (workgroup) Windows host —
    // e.g. an EC2 Windows instance with no AD/Kerberos — authenticates with
    // NTLM, which computes the NT hash with MD4. Without the legacy provider
    // WinPR logs "Failed to initialize digest md4", the security context comes
    // back SEC_E_NO_CREDENTIALS, and the whole connection is reported as the
    // misleading ERRCONNECT_CONNECT_TRANSPORT_FAILED.
    //
    // In the packaged .app legacy.dylib is bundled under Contents/Frameworks;
    // modules_dir points there so OpenSSL can find it (its compiled-in default
    // path is the build machine's Homebrew dir, absent on the user's Mac). For
    // dev builds modules_dir is NULL and OpenSSL keeps its built-in search path.
    // Activating any provider suppresses the implicit default, so load both —
    // TLS still needs SHA-2 etc. from the default provider.
    if (modules_dir && modules_dir[0]) {
        OSSL_PROVIDER_set_default_search_path(NULL, modules_dir);
    }
    OSSL_PROVIDER_load(NULL, "legacy");
    OSSL_PROVIDER_load(NULL, "default");
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

    // disp/cliprdr are assigned on the RDP thread (channel connect) but read from
    // the main thread (rdpcore_resize, clipboard senders); chanLock guards them so
    // a disconnect racing a main-thread call can't dereference a torn-down context.
    pthread_mutex_t chanLock;
    DispClientContext *disp;
    CliprdrClientContext *cliprdr;
    UINT32 pendingClipboardFormat; // format of the request currently awaiting a reply
    UINT32 clipboardWantedFormat;  // latest format the remote offered
    int clipboardRequestInFlight;  // a ClientFormatDataRequest is outstanding
    int clipboardReady;            // Monitor Ready seen: safe to announce formats

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

// MARK: - Clipboard (cliprdr)

// Monitor Ready is the point where the clipboard handshake actually opens. Per
// MS-RDPECLIP the client answers with its OWN capabilities and then a format list;
// skipping the capabilities leaves the server without our long-format-name support
// and it then never announces its own clipboard (nothing can be copied from Windows).
// Announcing before this arrives is a protocol violation, so this is also what flips
// clipboardReady on for rdpcore_clipboard_announce().
static UINT mrng_cliprdr_monitor_ready(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *e) {
    (void)e;
    RDPCore *core = (RDPCore *)cliprdr->custom;

    CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    // Long format names only: no file-clip flags, since file transfer isn't implemented.
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    CLIPRDR_CAPABILITIES caps = {0};
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    UINT rc = cliprdr->ClientCapabilities(cliprdr, &caps);
    if (rc != CHANNEL_RC_OK) return rc;

    CLIPRDR_FORMAT_LIST list = {0};
    rc = cliprdr->ClientFormatList(cliprdr, &list);

    // The pasteboard poll retries until this is set, so whatever is already on the
    // local clipboard gets offered as soon as the channel is legitimately open.
    pthread_mutex_lock(&core->chanLock);
    core->clipboardReady = 1;
    pthread_mutex_unlock(&core->chanLock);
    return rc;
}

// Issue a single data request and mark it in flight. pendingClipboardFormat then
// always matches the one response we're waiting for.
static void mrng_cliprdr_issue_request(CliprdrClientContext *cliprdr, RDPCore *core, UINT32 fmt) {
    core->clipboardRequestInFlight = 1;
    core->pendingClipboardFormat = fmt;
    CLIPRDR_FORMAT_DATA_REQUEST req = {0};
    req.requestedFormatId = fmt;
    cliprdr->ClientFormatDataRequest(cliprdr, &req);
}

// Remote copied something: ack the list, report the formats, and fetch the best one
// (text preferred, else image). Only one request is outstanding at a time so a
// response is never attributed to a format from a later, overlapping list.
static UINT mrng_cliprdr_server_format_list(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *fl) {
    RDPCore *core = (RDPCore *)cliprdr->custom;
    bool hasText = false;
    UINT32 imageFormat = 0; // prefer CF_DIB, fall back to CF_DIBV5 if that's all the server offers
    for (UINT32 i = 0; i < fl->numFormats; i++) {
        UINT32 id = fl->formats[i].formatId;
        if (id == CF_UNICODETEXT) hasText = true;
        else if (id == CF_DIB) imageFormat = CF_DIB;
        else if (id == CF_DIBV5 && imageFormat == 0) imageFormat = CF_DIBV5;
    }
    CLIPRDR_FORMAT_LIST_RESPONSE resp = {0};
    resp.common.msgFlags = CB_RESPONSE_OK;
    cliprdr->ClientFormatListResponse(cliprdr, &resp);

    if (core->cb.onClipboardRemoteFormats)
        core->cb.onClipboardRemoteFormats(core->ctx, hasText, imageFormat != 0);

    UINT32 want = hasText ? CF_UNICODETEXT : imageFormat;
    core->clipboardWantedFormat = want;
    if (want && !core->clipboardRequestInFlight)
        mrng_cliprdr_issue_request(cliprdr, core, want);
    return CHANNEL_RC_OK;
}

// Remote pasted (asked for our clipboard): hand the format id to the app, which
// answers asynchronously via rdpcore_clipboard_provide().
static UINT mrng_cliprdr_server_format_data_request(CliprdrClientContext *cliprdr,
                                                     const CLIPRDR_FORMAT_DATA_REQUEST *req) {
    RDPCore *core = (RDPCore *)cliprdr->custom;
    if (core->cb.onClipboardDataRequested)
        core->cb.onClipboardDataRequested(core->ctx, req->requestedFormatId);
    return CHANNEL_RC_OK;
}

// Remote delivered the data we requested -> push it to the local pasteboard.
static UINT mrng_cliprdr_server_format_data_response(CliprdrClientContext *cliprdr,
                                                     const CLIPRDR_FORMAT_DATA_RESPONSE *resp) {
    RDPCore *core = (RDPCore *)cliprdr->custom;
    if ((resp->common.msgFlags & CB_RESPONSE_OK) && core->cb.onClipboardRemoteData)
        core->cb.onClipboardRemoteData(core->ctx, core->pendingClipboardFormat,
                                       resp->requestedFormatData, resp->common.dataLen);
    // Request complete. If the remote offered a different format meanwhile, fetch it now.
    core->clipboardRequestInFlight = 0;
    if (core->clipboardWantedFormat && core->clipboardWantedFormat != core->pendingClipboardFormat)
        mrng_cliprdr_issue_request(cliprdr, core, core->clipboardWantedFormat);
    return CHANNEL_RC_OK;
}

static void on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    rdpContext *ctx = (rdpContext *)context;
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        // cliprdr is a STATIC (SVC) channel — same PubSub event, _SVC_ name macro.
        RDPCore *core = coreFromContext(ctx);
        CliprdrClientContext *c = (CliprdrClientContext *)e->pInterface;
        c->custom = core;
        c->MonitorReady = mrng_cliprdr_monitor_ready;
        c->ServerFormatList = mrng_cliprdr_server_format_list;
        c->ServerFormatDataRequest = mrng_cliprdr_server_format_data_request;
        c->ServerFormatDataResponse = mrng_cliprdr_server_format_data_response;
        pthread_mutex_lock(&core->chanLock);
        core->cliprdr = c;
        pthread_mutex_unlock(&core->chanLock);
        return;
    }
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        RDPCore *core = coreFromContext(ctx);
        pthread_mutex_lock(&core->chanLock);
        core->disp = (DispClientContext *)e->pInterface;
        pthread_mutex_unlock(&core->chanLock);
        // Re-apply the latest requested desktop size now that the Display Control
        // channel is up. A session restored on launch connects while its view is
        // still tiny (min 640x480), then the view lays out full-size and calls
        // rdpcore_resize BEFORE this channel exists — that resize updates
        // core->width/height but can't be sent yet, so the desktop would stay
        // stuck small. Flush it here once disp is available.
        rdpcore_resize(core, core->width, core->height, core->scalePercent);
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        // Wire the GFX pipeline to gdi -> codec updates (H264/progressive) land in the framebuffer.
        if (ctx->gdi) gdi_graphics_pipeline_init(ctx->gdi, (RdpgfxClientContext *)e->pInterface);
    }
}

static void on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    rdpContext *ctx = (rdpContext *)context;
    RDPCore *core = coreFromContext(ctx);
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&core->chanLock);
        core->disp = NULL;
        pthread_mutex_unlock(&core->chanLock);
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&core->chanLock);
        core->cliprdr = NULL;
        core->clipboardReady = 0;
        pthread_mutex_unlock(&core->chanLock);
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

// Called when a host's TLS certificate DIFFERS from the one we stored on a
// previous connection — typically a host that was reinstalled/rebuilt and
// regenerated its self-signed RDP cert. Without this callback FreeRDP falls
// back to its default handler, which prompts on stdin; a GUI app has no stdin,
// so it rejects and the connect aborts with ERRCONNECT_PRE_CONNECT_FAILED.
// Same policy as first-time certs: accept and remember (admin tool on a trusted
// LAN, hosts we manage ourselves).
static DWORD mrng_verify_changed_cert_ex(freerdp *instance, const char *host, UINT16 port,
                                         const char *common_name, const char *subject,
                                         const char *issuer, const char *new_fingerprint,
                                         const char *old_subject, const char *old_issuer,
                                         const char *old_fingerprint, DWORD flags) {
    (void)instance; (void)host; (void)port; (void)common_name;
    (void)subject; (void)issuer; (void)new_fingerprint;
    (void)old_subject; (void)old_issuer; (void)old_fingerprint; (void)flags;
    return 2; // accept and remember the new cert
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
    instance->VerifyChangedCertificateEx = mrng_verify_changed_cert_ex;
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
                        const char *sharePath,
                        RDPCoreCallbacks cb, void *ctx) {
    RDPCore *core = calloc(1, sizeof(RDPCore));
    if (!core) return NULL;
    pthread_mutex_init(&core->chanLock, NULL);
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
    // THE crash fix: force single-threaded codec decoding. The startup crash
    // (EXC_BAD_ACCESS / heap corruption in progressive_decompress ->
    // winpr_SubmitThreadpoolWork, NULL work object) came from FreeRDP's
    // multi-threaded tile decoder racing on its shared thread pool when several
    // RDP sessions decode GFX concurrently — e.g. restore-sessions reconnecting
    // many saved sessions at once. DISABLE_THREADS makes every codec decode on
    // the session's own thread, killing that race at the root regardless of which
    // codec the server picks. (Disabling GfxProgressive did NOT help: older hosts
    // negotiate GFX caps < v10 which have no H264, so the server keeps sending
    // progressive surfaces no matter what — the thread pool, not the codec, was
    // the bug.) Single-threaded decode of a normal desktop is plenty fast on
    // Apple Silicon; the thread pool only matters for huge multi-monitor walls.
    freerdp_settings_set_uint32(s, FreeRDP_ThreadingFlags, THREADING_FLAGS_DISABLE_THREADS);
    // Keep the full modern codec set enabled: H264/AVC444 on hosts that negotiate
    // GFX caps >= v10, RemoteFX Progressive on the older ones (their only efficient
    // codec). Safe now that decoding is single-threaded.
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_NetworkAutoDetect, TRUE);
    // Skip TLS certificate verification entirely. These are self-signed Windows
    // hosts on a trusted LAN, reached by IP — so every cert is self-signed, the
    // name never matches (CN is the FQDN, we connect by IP), and a reinstalled
    // host presents a "changed" cert. FreeRDP's verification path chokes on that
    // combination (self-signed + name-mismatch + changed): it fails internally
    // (x509_utils_from_pem: BIO_new failed) before honouring the accept
    // callbacks, aborting the connect. The app's policy is already accept-all
    // (mrng_verify_cert_ex / mrng_verify_changed_cert_ex return 2), so ignoring
    // verification outright is the reliable way to express that — same as mstsc
    // "don't ask again" / mRemoteNG on a managed network. The Verify*Ex callbacks
    // stay wired as a fallback if this is ever made configurable per-host.
    freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, TRUE);
    // Clipboard redirection (cliprdr). Enabling it makes client/common load the
    // channel; the handlers are wired in on_channel_connected.
    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, TRUE);
    // Drive redirection: only the folder the user picked in Settings, mapped
    // read/write so files move both ways (\\tsclient\\<name> in the session).
    // No folder configured -> device redirection stays off and nothing on this Mac
    // is reachable from the remote. The folder is never created here: it must be
    // one the user already chose, so we can't silently expose an unexpected path.
    if (sharePath && sharePath[0]) {
        freerdp_settings_set_bool(s, FreeRDP_DeviceRedirection, TRUE);
        // Name the share after the folder so it's recognisable in Explorer, keeping
        // only characters that are safe in a Windows share name.
        char shareName[64] = {0};
        const char *base = strrchr(sharePath, '/');
        base = (base && base[1]) ? base + 1 : sharePath;
        size_t n = 0;
        for (size_t i = 0; base[i] && n < sizeof(shareName) - 1; i++) {
            unsigned char ch = (unsigned char)base[i];
            if (isalnum(ch) || ch == '-' || ch == '_') shareName[n++] = (char)ch;
            else if (ch == ' ' && n > 0 && shareName[n - 1] != '_') shareName[n++] = '_';
        }
        if (n == 0) snprintf(shareName, sizeof(shareName), "mRemoteNXT");
        // FreeRDP strdup's these into its device collection, so locals are fine.
        const char *driveParams[3] = { "drive", shareName, sharePath };
        freerdp_client_add_device_channel(s, 3, driveParams);
    }

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
    pthread_mutex_destroy(&core->chanLock);
    free(core);
}

void rdpcore_resize(RDPCore *core, int width, int height, int scalePercent) {
    if (!core) return;
    width -= width % 2; height -= height % 2;
    core->width = width; core->height = height;
    core->scalePercent = (scalePercent >= 100 && scalePercent <= 500) ? scalePercent : 100;
    pthread_mutex_lock(&core->chanLock);
    DispClientContext *disp = core->disp;
    if (!disp || !disp->SendMonitorLayout) { pthread_mutex_unlock(&core->chanLock); return; }
    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
    memset(&layout, 0, sizeof(layout));
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = (UINT32)width;
    layout.Height = (UINT32)height;
    layout.Orientation = 0;
    layout.DesktopScaleFactor = (UINT32)core->scalePercent;
    layout.DeviceScaleFactor = deviceScaleFor(core->scalePercent);
    disp->SendMonitorLayout(disp, 1, &layout);
    pthread_mutex_unlock(&core->chanLock);
}

// MARK: - Clipboard senders (called from the app layer)

bool rdpcore_clipboard_announce(RDPCore *core, bool hasText, bool hasImage) {
    if (!core) return false;
    pthread_mutex_lock(&core->chanLock);
    // Not until Monitor Ready: a format list sent before the handshake is a protocol
    // violation and the server may drop it. Returning false keeps the caller retrying.
    CliprdrClientContext *c = core->clipboardReady ? core->cliprdr : NULL;
    bool sent = false;
    if (c) {
        CLIPRDR_FORMAT formats[2];
        memset(formats, 0, sizeof(formats));
        UINT32 n = 0;
        if (hasText)  { formats[n].formatId = CF_UNICODETEXT; n++; }
        if (hasImage) { formats[n].formatId = CF_DIB;         n++; }
        CLIPRDR_FORMAT_LIST list = {0};
        list.numFormats = n;
        list.formats = n ? formats : NULL;
        c->ClientFormatList(c, &list);
        sent = true;
    }
    pthread_mutex_unlock(&core->chanLock);
    return sent;
}

void rdpcore_clipboard_provide(RDPCore *core, const uint8_t *data, uint32_t size) {
    if (!core) return;
    pthread_mutex_lock(&core->chanLock);
    CliprdrClientContext *c = core->cliprdr;
    if (c) {
        CLIPRDR_FORMAT_DATA_RESPONSE resp = {0};
        resp.common.msgFlags = (data && size) ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
        resp.common.dataLen = size;
        resp.requestedFormatData = (const BYTE *)data;
        c->ClientFormatDataResponse(c, &resp); // FreeRDP consumes the buffer synchronously
    }
    pthread_mutex_unlock(&core->chanLock);
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

void rdpcore_key_scancode(RDPCore *core, uint8_t code, bool extended, bool down) {
    rdpInput *in = coreInput(core); if (!in) return;
    UINT16 flags = down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    if (extended) flags |= KBD_FLAGS_EXTENDED;
    freerdp_input_send_keyboard_event(in, flags, code);
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
