/* SPDX-License-Identifier: GPL-2.0-or-later
 * mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
 * See LICENSE for full text.
 */

// Pure C interface over FreeRDP. Do NOT include Foundation/Cocoa headers here, so
// WinPR's IID typedef doesn't collide with CoreFoundation's (CFPlugInCOM).
#ifndef RDPCORE_H
#define RDPCORE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RDPCore RDPCore;

typedef struct {
    void (*onConnected)(void *ctx, int width, int height);
    // bgra = live buffer (valid only during the callback); the consumer copies synchronously.
    void (*onImage)(void *ctx, const uint8_t *bgra, int width, int height, int stride);
    void (*onDisconnected)(void *ctx, const char *error); // error == NULL => normal
    // Clipboard (cliprdr). Buffers are valid only during the callback — copy synchronously.
    void (*onClipboardRemoteFormats)(void *ctx, bool hasText, bool hasImage); // remote copied something
    void (*onClipboardRemoteData)(void *ctx, uint32_t formatId, const uint8_t *data, uint32_t size);
    void (*onClipboardDataRequested)(void *ctx, uint32_t formatId); // remote wants our clipboard
    /// The server turned out to be too old for the graphics pipeline, and this session
    /// negotiated it anyway. Fired once, right after connecting: the caller should
    /// remember the host and reconnect with useLegacyGraphics.
    void (*onLegacyGraphicsSuggested)(void *ctx);
    /// The remote pointer shape changed. bgra is premultiplied BGRA of width*height
    /// pixels in REMOTE pixels, valid only during the callback — copy synchronously.
    /// hotX/hotY are the click point inside that image.
    void (*onCursorShape)(void *ctx, const uint8_t *bgra, int width, int height,
                          int hotX, int hotY);
    /// The remote hid the pointer, or asked for the plain system arrow.
    void (*onCursorHidden)(void *ctx);
    void (*onCursorDefault)(void *ctx);
} RDPCoreCallbacks;

// Special key codes (must match RDPSpecialKey in RDPClient.h).
enum {
    RDPCORE_KEY_ENTER = 1, RDPCORE_KEY_BACKSPACE, RDPCORE_KEY_TAB, RDPCORE_KEY_ESCAPE,
    RDPCORE_KEY_SPACE, RDPCORE_KEY_UP, RDPCORE_KEY_DOWN, RDPCORE_KEY_LEFT, RDPCORE_KEY_RIGHT,
    RDPCORE_KEY_DELETE, RDPCORE_KEY_SHIFT, RDPCORE_KEY_CONTROL, RDPCORE_KEY_ALT, RDPCORE_KEY_COMMAND
};

// sharePath = absolute path of a macOS folder to expose in the session as a
// redirected drive (read/write, so files move both ways). NULL or empty disables
// device redirection entirely — nothing on this Mac is reachable from the remote.
// useLegacyGraphics != 0 skips the graphics pipeline and takes the classic bitmap
// update path — needed by servers that negotiate EGFX and then never paint with it.
RDPCore *rdpcore_create(const char *host, int port, const char *user,
                        const char *domain, const char *pass,
                        int width, int height, int scalePercent,
                        const char *sharePath, int useLegacyGraphics,
                        RDPCoreCallbacks cb, void *ctx);
void rdpcore_start(RDPCore *core);
void rdpcore_stop(RDPCore *core);
void rdpcore_free(RDPCore *core);

// One-time OpenSSL setup: loads the legacy provider so MD4 is available for
// NTLM (NLA/CredSSP against non-AD Windows hosts). modules_dir is the directory
// holding the bundled legacy.dylib (Contents/Frameworks in the packaged app),
// or NULL to keep OpenSSL's built-in module search path (dev builds). Idempotent
// and safe to call before any connection.
void rdpcore_init_crypto(const char *modules_dir);

// Diagnostic logging: when enabled, routes FreeRDP's WLog output at DEBUG level
// into <dir>/mRemoteNXT.log so connection failures can be inspected. When
// disabled, raises the log level so nothing is written. Global (affects all
// RDP sessions); safe to call before any connection.
void rdpcore_set_diagnostic_logging(int enabled, const char *dir);
// Live resize of the RDP desktop (via the Display Control channel).
void rdpcore_resize(RDPCore *core, int width, int height, int scalePercent);

// Clipboard (cliprdr) senders, called from the app layer:
// announce = tell the remote what our local clipboard now holds.
//   Returns true only if the clipboard channel was up and the offer was sent, so
//   the caller can retry until it connects (and offer a pre-session clipboard).
// provide  = answer a prior onClipboardDataRequested(formatId); NULL/0 => decline.
bool rdpcore_clipboard_announce(RDPCore *core, bool hasText, bool hasImage);
void rdpcore_clipboard_provide(RDPCore *core, const uint8_t *data, uint32_t size);

void rdpcore_mouse_move(RDPCore *core, int x, int y);
void rdpcore_mouse_button(RDPCore *core, int button, bool down, int x, int y);
void rdpcore_scroll(RDPCore *core, int steps, int x, int y);
void rdpcore_key_unicode(RDPCore *core, uint16_t unicode, bool down);
void rdpcore_key_special(RDPCore *core, int key, bool down);
// Raw set-1 scancode. Needed for keyboard shortcuts: Windows treats unicode key
// events as literal text and ignores the modifier state, so Ctrl+C sent as
// "Ctrl down + unicode c" just types a 'c'. Sending the scancode lets the server
// combine it with the modifier scancodes into a real accelerator.
void rdpcore_key_scancode(RDPCore *core, uint8_t code, bool extended, bool down);

#ifdef __cplusplus
}
#endif

#endif
