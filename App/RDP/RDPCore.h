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

/// One entry of the file list the remote put on its clipboard (files copied in Explorer).
/// name is the path relative to what was copied — UTF-16, backslash-separated, NUL-terminated
/// within the 260 characters Windows allows. Folders come as their own entries, before or
/// after their contents; the position in the list is the index the contents are asked by.
typedef struct {
    uint16_t name[260];
    bool isDirectory;
    bool hasSize;
    uint64_t size;
    bool hasWriteTime;
    uint64_t writeTime;   // FILETIME: 100 ns intervals since 1601-01-01 UTC
} RDPCoreRemoteFile;

typedef struct {
    void (*onConnected)(void *ctx, int width, int height);
    // bgra = live buffer (valid only during the callback); the consumer copies synchronously.
    void (*onImage)(void *ctx, const uint8_t *bgra, int width, int height, int stride);
    void (*onDisconnected)(void *ctx, const char *error); // error == NULL => normal
    // Clipboard (cliprdr). Buffers are valid only during the callback — copy synchronously.
    void (*onClipboardRemoteFormats)(void *ctx, bool hasText, bool hasImage); // remote copied something
    void (*onClipboardRemoteData)(void *ctx, uint32_t formatId, const uint8_t *data, uint32_t size);
    void (*onClipboardDataRequested)(void *ctx, uint32_t formatId); // remote wants our clipboard
    // Remote wants the files we announced: answer with rdpcore_clipboard_provide_files().
    void (*onClipboardFilesRequested)(void *ctx);
    // Remote copied files. The array is valid only during the callback. clipDataId is the
    // lock that keeps them readable after the remote clipboard changes (0 = the server
    // cannot lock); pass it with every contents request and release it when done.
    void (*onClipboardRemoteFiles)(void *ctx, const RDPCoreRemoteFile *files, uint32_t count,
                                   uint32_t clipDataId);
    // Answer to rdpcore_clipboard_request_file_contents, matched by streamId. data is valid
    // only during the callback; for a size request it is 8 bytes, little-endian.
    void (*onClipboardFileContents)(void *ctx, uint32_t streamId, bool ok,
                                    const uint8_t *data, uint32_t size);
    // The clipboard channel went away: nothing outstanding will be answered.
    void (*onClipboardChannelClosed)(void *ctx);
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
    /// The RD Gateway sent a message to show: a logon notice, or terms that have to be
    /// accepted before it lets the connection through (consentMandatory). Called on the RDP
    /// thread, which waits for the answer; true = go on, false = abandon the connection.
    bool (*onGatewayMessage)(void *ctx, bool consentMandatory, const char *message);
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
// Announce a Windows keyboard layout id for the session. Must be called before
// rdpcore_start; 0 leaves it unset and the server uses its own.
void rdpcore_set_keyboard_layout(RDPCore *core, uint32_t klid);
// Reach the host through an RD Gateway. Must be called before rdpcore_start. usage: 1 =
// always, 2 = detect (TSC_PROXY_MODE_*). sameCredentials says the gateway takes the
// session's own logon; the credentials passed here are used either way, so they must be the
// right ones for the gateway.
void rdpcore_set_gateway(RDPCore *core, const char *host, int port, int usage, bool sameCredentials,
                         const char *user, const char *domain, const char *pass);
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
bool rdpcore_clipboard_announce(RDPCore *core, bool hasText, bool hasImage, bool hasFiles);
void rdpcore_clipboard_provide(RDPCore *core, const uint8_t *data, uint32_t size);
// Answer a prior onClipboardFilesRequested with a text/uri-list: one "file://<absolute
// path>" per line, CRLF-separated, paths unencoded. The descriptors go out now; the
// contents are streamed later, on demand, as the remote reads each file.
void rdpcore_clipboard_provide_files(RDPCore *core, const char *uriList, uint32_t size);
// Ask the remote for a file on ITS clipboard, by its index in the list onClipboardRemoteFiles
// reported: the size (sizeOnly) or `length` bytes from `offset`. The answer arrives through
// onClipboardFileContents with the same streamId. Returns false when the channel is not up.
bool rdpcore_clipboard_request_file_contents(RDPCore *core, uint32_t streamId, uint32_t listIndex,
                                             bool sizeOnly, uint64_t offset, uint32_t length,
                                             uint32_t clipDataId);
// Release a lock reported by onClipboardRemoteFiles; the server may then drop those files.
void rdpcore_clipboard_unlock(RDPCore *core, uint32_t clipDataId);

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
