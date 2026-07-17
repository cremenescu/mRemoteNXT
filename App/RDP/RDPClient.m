// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

#import "RDPClient.h"
#import "RDPCore.h"
#import <CoreGraphics/CoreGraphics.h>

@interface RDPClient () {
    RDPCore *_core;
    CGImageRef _pendingImage;   // most recent frame, delivered coalesced on main
    BOOL _updateScheduled;
}
- (void)enqueueImage:(CGImageRef)img;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *domain;
@property (nonatomic, copy) NSString *password;
@property (nonatomic) int port;
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) int scale;
@end

static void freeImageData(void *info, const void *data, size_t size) { free((void *)data); }

static void core_onConnected(void *ctx, int w, int h) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate rdpClient:self didConnectWithWidth:w height:h];
    });
}

static void core_onImage(void *ctx, const uint8_t *bgra, int w, int h, int stride) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    size_t len = (size_t)stride * (size_t)h;
    void *copy = malloc(len);
    if (!copy) return;
    memcpy(copy, bgra, len);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, copy, len, freeImageData);
    CGBitmapInfo info = kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little; // BGRA32
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)stride, cs, info,
                                   provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (!img) return;
    [self enqueueImage:img]; // coalescing: keep only the latest frame for main
    CGImageRelease(img);
}

static void core_onDisconnected(void *ctx, const char *err) {
    NSString *msg = err ? [NSString stringWithUTF8String:err] : nil;
    // Transfer the +1 retain held by core back to ARC: after this callback the
    // client can be safely deallocated (the thread is done).
    RDPClient *self = (__bridge_transfer RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate rdpClient:self didDisconnectWithError:msg];
    });
}

@implementation RDPClient

+ (void)setDiagnosticLogging:(BOOL)enabled directory:(NSString *)directory {
    rdpcore_set_diagnostic_logging(enabled ? 1 : 0, directory.UTF8String);
}

- (instancetype)initWithHost:(NSString *)host port:(int)port username:(NSString *)username
                      domain:(NSString *)domain password:(NSString *)password
                       width:(int)width height:(int)height scale:(int)scalePercent {
    if (self = [super init]) {
        _host = [host copy];
        _port = port;
        _username = [username copy];
        _domain = [domain copy];
        _password = [password copy];
        _width = width;
        _height = height;
        _scale = scalePercent;
    }
    return self;
}

- (void)start {
    if (_core) return;
    RDPCoreCallbacks cb = { core_onConnected, core_onImage, core_onDisconnected };
    // core holds a +1 retain on self for the lifetime of the connection
    // (released in core_onDisconnected).
    void *ctx = (__bridge_retained void *)self;
    _core = rdpcore_create(self.host.UTF8String, self.port,
                           self.username.UTF8String, self.domain.UTF8String,
                           self.password.UTF8String, self.width, self.height, self.scale, cb, ctx);
    rdpcore_start(_core);
}

- (void)stop {
    if (_core) rdpcore_stop(_core);
}

- (void)resizeToWidth:(int)width height:(int)height scale:(int)scalePercent {
    if (_core) rdpcore_resize(_core, width, height, scalePercent);
}

- (void)dealloc {
    if (_core) rdpcore_free(_core); // thread already finished (onDisconnected transferred the retain)
    if (_pendingImage) CGImageRelease(_pendingImage);
}

// Coalescing: if main is busy, intermediate frames are replaced -> we only show the latest.
- (void)enqueueImage:(CGImageRef)img {
    @synchronized (self) {
        if (_pendingImage) CGImageRelease(_pendingImage);
        _pendingImage = CGImageRetain(img);
        if (_updateScheduled) return;
        _updateScheduled = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        CGImageRef toDeliver;
        @synchronized (self) {
            toDeliver = self->_pendingImage;
            self->_pendingImage = NULL;
            self->_updateScheduled = NO;
        }
        if (toDeliver) {
            [self.delegate rdpClient:self didUpdateImage:toDeliver];
            CGImageRelease(toDeliver);
        }
    });
}

- (void)mouseMoveToX:(int)x y:(int)y { rdpcore_mouse_move(_core, x, y); }
- (void)mouseButton:(int)button down:(BOOL)down x:(int)x y:(int)y { rdpcore_mouse_button(_core, button, down, x, y); }
- (void)scrollSteps:(int)steps x:(int)x y:(int)y { rdpcore_scroll(_core, steps, x, y); }
- (void)keyChar:(uint16_t)unicode down:(BOOL)down { rdpcore_key_unicode(_core, unicode, down); }
- (void)keySpecial:(NSInteger)key down:(BOOL)down { rdpcore_key_special(_core, (int)key, down); }

@end
