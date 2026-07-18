// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

#import "RDPClient.h"
#import "RDPCore.h"
#import <CoreGraphics/CoreGraphics.h>
#import <libkern/OSByteOrder.h>   // BITMAPFILEHEADER (DIB <-> BMP) little-endian helpers

// Windows clipboard format ids (from winpr/user.h — redefined locally to avoid
// pulling WinPR headers into this Cocoa translation unit, where WinPR's IID
// typedef collides with CoreFoundation's).
enum { MRNG_CF_UNICODETEXT = 13, MRNG_CF_DIB = 8, MRNG_CF_DIBV5 = 17 };

@interface RDPClient () {
    RDPCore *_core;
    CGImageRef _pendingImage;   // most recent frame, delivered coalesced on main
    BOOL _updateScheduled;
    NSTimer *_clipboardTimer;   // polls the local pasteboard for changes
    NSInteger _lastPasteboardChangeCount;
}
- (void)enqueueImage:(CGImageRef)img;
- (void)applyRemoteClipboardData:(NSData *)data format:(uint32_t)formatId;
- (void)provideLocalClipboardForFormat:(uint32_t)formatId;
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

// MARK: - Remote cursor

static void core_onCursorImage(void *ctx, const uint8_t *bgra, int w, int h, int hotspotX, int hotspotY) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    size_t len = (size_t)w * (size_t)h * 4;
    void *copy = malloc(len);
    if (!copy) return;
    memcpy(copy, bgra, len); // synchronous copy: buffer valid only during this call

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, copy, len, freeImageData);
    // Straight-alpha BGRA (not premultiplied). If color-cursor edges show dark
    // fringing, switch to kCGImageAlphaPremultipliedFirst.
    CGBitmapInfo info = kCGImageAlphaFirst | kCGBitmapByteOrder32Little;
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, cs, info,
                                   provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (!img) return;
    dispatch_async(dispatch_get_main_queue(), ^{ // NSImage/NSCursor on main
        NSImage *image = [[NSImage alloc] initWithCGImage:img size:NSMakeSize(w, h)];
        CGImageRelease(img);
        NSCursor *cursor = [[NSCursor alloc] initWithImage:image
                                                   hotSpot:NSMakePoint(hotspotX, hotspotY)];
        [self.delegate rdpClient:self didUpdateCursor:cursor];
    });
}

static void core_onCursorNull(void *ctx) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Transparent 1x1 cursor instead of [NSCursor hide] (which is a global,
        // unbalanced push/pop counter — easy to leak across tabs/reconnects).
        NSImage *blank = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        NSCursor *invisible = [[NSCursor alloc] initWithImage:blank hotSpot:NSZeroPoint];
        [self.delegate rdpClient:self didUpdateCursor:invisible];
    });
}

static void core_onCursorDefault(void *ctx) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate rdpClient:self didUpdateCursor:nil]; // nil = local arrow
    });
}

// MARK: - Clipboard helpers (DIB <-> BMP)

// A CF_DIB payload is a BITMAPINFOHEADER + pixels with NO 14-byte BITMAPFILEHEADER.
// Prepend one so ImageIO/NSBitmapImageRep can decode it.
static NSData *mrng_dibToBmp(NSData *dib) {
    if (dib.length < 40) return nil;
    const uint8_t *b = dib.bytes;
    uint32_t biSize = OSReadLittleInt32(b, 0);
    uint16_t biBitCount = OSReadLittleInt16(b, 14);
    uint32_t biClrUsed = OSReadLittleInt32(b, 32);
    uint32_t paletteSize = 0;
    if (biBitCount <= 8) {
        uint32_t colors = biClrUsed ? biClrUsed : (1u << biBitCount);
        paletteSize = colors * 4;
    }
    uint32_t offBits = 14 + biSize + paletteSize;
    uint32_t fileSize = 14 + (uint32_t)dib.length;
    uint8_t hdr[14] = {0};
    hdr[0] = 'B'; hdr[1] = 'M';
    OSWriteLittleInt32(hdr, 2, fileSize);
    OSWriteLittleInt32(hdr, 10, offBits);
    NSMutableData *out = [NSMutableData dataWithBytes:hdr length:14];
    [out appendData:dib];
    return out;
}

// Reverse: strip the 14-byte BITMAPFILEHEADER to get a raw CF_DIB body.
static NSData *mrng_bmpToDib(NSData *bmp) {
    if (bmp.length <= 14) return nil;
    return [bmp subdataWithRange:NSMakeRange(14, bmp.length - 14)];
}

// MARK: - Clipboard trampolines

// Remote delivered clipboard data we requested -> write to the local pasteboard.
// (Buffer is valid only during the call, so copy synchronously before hopping to main.)
static void core_onClipboardRemoteData(void *ctx, uint32_t formatId, const uint8_t *data, uint32_t size) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    NSData *copy = [NSData dataWithBytes:data length:size];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyRemoteClipboardData:copy format:formatId];
    });
}

// Remote pasted (wants our clipboard) -> answer from the local pasteboard.
static void core_onClipboardDataRequested(void *ctx, uint32_t formatId) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self provideLocalClipboardForFormat:formatId];
    });
}

@implementation RDPClient

+ (void)setDiagnosticLogging:(BOOL)enabled directory:(NSString *)directory {
    rdpcore_set_diagnostic_logging(enabled ? 1 : 0, directory.UTF8String);
}

+ (void)initCrypto {
    // Point OpenSSL at the bundled legacy provider only if it's actually there
    // (packaged .app). In a plain dev build Frameworks has no legacy.dylib, so
    // pass NULL and let OpenSSL use its built-in (Homebrew) module search path.
    NSString *frameworks = [[NSBundle mainBundle] privateFrameworksPath];
    NSString *module = [frameworks stringByAppendingPathComponent:@"legacy.dylib"];
    const char *dir = NULL;
    if (frameworks.length && [[NSFileManager defaultManager] fileExistsAtPath:module]) {
        dir = frameworks.fileSystemRepresentation;
    }
    rdpcore_init_crypto(dir);
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
    RDPCoreCallbacks cb = {
        .onConnected = core_onConnected,
        .onImage = core_onImage,
        .onCursorImage = core_onCursorImage,
        .onCursorNull = core_onCursorNull,
        .onCursorDefault = core_onCursorDefault,
        .onClipboardRemoteData = core_onClipboardRemoteData,
        .onClipboardDataRequested = core_onClipboardDataRequested,
        .onDisconnected = core_onDisconnected,
    };
    // core holds a +1 retain on self for the lifetime of the connection
    // (released in core_onDisconnected).
    void *ctx = (__bridge_retained void *)self;
    _core = rdpcore_create(self.host.UTF8String, self.port,
                           self.username.UTF8String, self.domain.UTF8String,
                           self.password.UTF8String, self.width, self.height, self.scale, cb, ctx);
    rdpcore_start(_core);

    // Poll the local pasteboard; on change, announce the available formats so the
    // remote can paste from the Mac. Weak self so the timer never keeps us alive.
    _lastPasteboardChangeCount = NSPasteboard.generalPasteboard.changeCount;
    __weak RDPClient *weakSelf = self;
    _clipboardTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
        RDPClient *strong = weakSelf;
        if (!strong) { [t invalidate]; return; }
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        NSInteger cc = pb.changeCount;
        if (cc == strong->_lastPasteboardChangeCount) return;
        strong->_lastPasteboardChangeCount = cc;
        NSArray<NSPasteboardType> *types = pb.types;
        BOOL hasText = [types containsObject:NSPasteboardTypeString];
        BOOL hasImage = [types containsObject:NSPasteboardTypeTIFF] || [types containsObject:NSPasteboardTypePNG];
        rdpcore_clipboard_announce(strong->_core, hasText, hasImage);
    }];
}

- (void)stop {
    if (_core) rdpcore_stop(_core);
    [_clipboardTimer invalidate];
    _clipboardTimer = nil;
}

- (void)resizeToWidth:(int)width height:(int)height scale:(int)scalePercent {
    if (_core) rdpcore_resize(_core, width, height, scalePercent);
}

- (void)dealloc {
    [_clipboardTimer invalidate];
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

// MARK: - Clipboard (main-thread bodies; access private ivars)

- (void)applyRemoteClipboardData:(NSData *)data format:(uint32_t)formatId {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    if (formatId == MRNG_CF_UNICODETEXT) {
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
        if (s) {
            [pb clearContents];
            [pb setString:s forType:NSPasteboardTypeString];
            _lastPasteboardChangeCount = pb.changeCount; // don't re-announce our own write
        }
    } else if (formatId == MRNG_CF_DIB || formatId == MRNG_CF_DIBV5) {
        NSData *bmp = mrng_dibToBmp(data);
        NSBitmapImageRep *rep = bmp ? [NSBitmapImageRep imageRepWithData:bmp] : nil;
        if (rep) {
            [pb clearContents];
            [pb setData:rep.TIFFRepresentation forType:NSPasteboardTypeTIFF];
            _lastPasteboardChangeCount = pb.changeCount;
        }
    }
}

- (void)provideLocalClipboardForFormat:(uint32_t)formatId {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSData *out = nil;
    if (formatId == MRNG_CF_UNICODETEXT) {
        NSString *s = [pb stringForType:NSPasteboardTypeString];
        if (s) {
            NSMutableData *d = [[s dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
            uint16_t nul = 0; [d appendBytes:&nul length:2]; // CF_UNICODETEXT is NUL-terminated
            out = d;
        }
    } else if (formatId == MRNG_CF_DIB || formatId == MRNG_CF_DIBV5) {
        NSData *tiff = [pb dataForType:NSPasteboardTypeTIFF];
        NSBitmapImageRep *rep = tiff ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
        NSData *bmp = rep ? [rep representationUsingType:NSBitmapImageFileTypeBMP properties:@{}] : nil;
        out = mrng_bmpToDib(bmp);
    }
    rdpcore_clipboard_provide(_core, out.bytes, (uint32_t)out.length); // nil -> declines
}

@end
