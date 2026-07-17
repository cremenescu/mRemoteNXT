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
} RDPCoreCallbacks;

// Special key codes (must match RDPSpecialKey in RDPClient.h).
enum {
    RDPCORE_KEY_ENTER = 1, RDPCORE_KEY_BACKSPACE, RDPCORE_KEY_TAB, RDPCORE_KEY_ESCAPE,
    RDPCORE_KEY_SPACE, RDPCORE_KEY_UP, RDPCORE_KEY_DOWN, RDPCORE_KEY_LEFT, RDPCORE_KEY_RIGHT,
    RDPCORE_KEY_DELETE, RDPCORE_KEY_SHIFT, RDPCORE_KEY_CONTROL, RDPCORE_KEY_ALT, RDPCORE_KEY_COMMAND
};

RDPCore *rdpcore_create(const char *host, int port, const char *user,
                        const char *domain, const char *pass,
                        int width, int height, int scalePercent,
                        RDPCoreCallbacks cb, void *ctx);
void rdpcore_start(RDPCore *core);
void rdpcore_stop(RDPCore *core);
void rdpcore_free(RDPCore *core);

// Diagnostic logging: when enabled, routes FreeRDP's WLog output at DEBUG level
// into <dir>/mRemoteNXT.log so connection failures can be inspected. When
// disabled, raises the log level so nothing is written. Global (affects all
// RDP sessions); safe to call before any connection.
void rdpcore_set_diagnostic_logging(int enabled, const char *dir);
// Live resize of the RDP desktop (via the Display Control channel).
void rdpcore_resize(RDPCore *core, int width, int height, int scalePercent);

void rdpcore_mouse_move(RDPCore *core, int x, int y);
void rdpcore_mouse_button(RDPCore *core, int button, bool down, int x, int y);
void rdpcore_scroll(RDPCore *core, int steps, int x, int y);
void rdpcore_key_unicode(RDPCore *core, uint16_t unicode, bool down);
void rdpcore_key_special(RDPCore *core, int key, bool down);

#ifdef __cplusplus
}
#endif

#endif
