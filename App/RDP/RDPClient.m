// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

#import "RDPClient.h"
#import "RDPCore.h"
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>            // NSPasteboard
#import <libkern/OSByteOrder.h>      // BITMAPFILEHEADER (DIB <-> BMP) little-endian helpers

// Windows clipboard format ids (from winpr/user.h — redefined locally to avoid
// pulling WinPR headers into an Objective-C translation unit).
enum { MRNG_CF_UNICODETEXT = 13, MRNG_CF_DIB = 8, MRNG_CF_DIBV5 = 17 };

@interface RDPClient () {
    RDPCore *_core;
    CGImageRef _pendingImage;   // most recent frame, delivered coalesced on main
    BOOL _updateScheduled;
    NSTimer *_clipboardTimer;   // polls the local pasteboard for changes
    NSString *_sharedFolder;    // macOS folder exposed as a redirected drive (nil = none)
    BOOL _useLegacyGraphics;    // skip EGFX, take the classic bitmap update path
    NSInteger _lastPasteboardChangeCount;
    // Remote clipboard file contents: one request in flight at a time (_fileRequestLock),
    // answered through a semaphore of its own so a late reply to an abandoned request can
    // never release the next one. Guarded by @synchronized(self).
    NSLock *_fileRequestLock;
    uint32_t _fileStreamId;
    dispatch_semaphore_t _fileSema;
    NSData *_fileResponse;
    BOOL _fileResponseOK;
}
- (void)enqueueImage:(CGImageRef)img;
- (void)deliverFileContents:(uint32_t)streamId ok:(BOOL)ok data:(nullable NSData *)data;
- (void)abortRemoteFileRequests;
- (void)applyRemoteClipboardData:(NSData *)data format:(uint32_t)formatId;
- (void)provideLocalClipboardForFormat:(uint32_t)formatId;
- (void)provideLocalClipboardFiles;
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

// The frame goes to the screen as a CALayer's contents. Core Animation takes the bytes
// of a CGImage as they are only when it recognises the format outright — BGRA, alpha
// premultiplied, sRGB. Anything else it re-renders through CoreGraphics on the main
// thread on every frame; with a device-RGB "skip alpha" image that was a colour-space
// conversion per frame, measured at a tenth of the main thread while the app sat idle.
//
// FreeRDP writes the alpha byte on every path this app has seen, but no codec promises
// it, and a frame tagged premultiplied with alpha 0 is a transparent desktop. So the copy
// forces the byte on as it goes: the same streaming pass as the memcpy it replaces.
static void core_onImage(void *ctx, const uint8_t *bgra, int w, int h, int stride) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    size_t len = (size_t)stride * (size_t)h;
    uint32_t *copy = malloc(len);
    if (!copy) return;
    const uint32_t *src = (const uint32_t *)bgra;
    size_t words = len / 4;
    for (size_t i = 0; i < words; i++) copy[i] = src[i] | 0xFF000000u; // byte 3 = alpha, little-endian

    static CGColorSpaceRef cs = NULL;
    if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, copy, len, freeImageData);
    CGBitmapInfo info = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little; // BGRA32, opaque
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)stride, cs, info,
                                   provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!img) return;
    [self enqueueImage:img]; // coalescing: keep only the latest frame for main
    CGImageRelease(img);
}

static void core_onDisconnected(void *ctx, const char *err) {
    NSString *msg = err ? [NSString stringWithUTF8String:err] : nil;
    // Transfer the +1 retain held by core back to ARC: after this callback the
    // client can be safely deallocated (the thread is done).
    RDPClient *self = (__bridge_transfer RDPClient *)ctx;
    [self abortRemoteFileRequests]; // a paste waiting on this session gets its answer now
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate rdpClient:self didDisconnectWithError:msg];
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

// Remote pointer shape -> CGImage -> delegate (which turns it into an NSCursor).
static void core_onCursorShape(void *ctx, const uint8_t *bgra, int w, int h, int hotX, int hotY) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    if (w <= 0 || h <= 0) return;
    const size_t stride = (size_t)w * 4;
    const size_t len = stride * (size_t)h;
    uint8_t *copy = malloc(len);
    if (!copy) return;
    memcpy(copy, bgra, len);

    // FreeRDP hands back straight alpha; CoreGraphics wants it premultiplied, and without
    // this the semi-transparent edge of a cursor comes out as a bright halo.
    for (size_t i = 0; i < len; i += 4) {
        const uint32_t a = copy[i + 3];
        if (a == 255) continue;
        copy[i + 0] = (uint8_t)((copy[i + 0] * a + 127) / 255);
        copy[i + 1] = (uint8_t)((copy[i + 1] * a + 127) / 255);
        copy[i + 2] = (uint8_t)((copy[i + 2] * a + 127) / 255);
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, copy, len, freeImageData);
    CGBitmapInfo info = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little; // BGRA32
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, stride, cs, info,
                                   provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (!img) return;

    const CGPoint hot = CGPointMake(hotX, hotY);
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(rdpClient:didUpdateCursor:hotSpot:)])
            [self.delegate rdpClient:self didUpdateCursor:img hotSpot:hot];
        CGImageRelease(img);
    });
}

static void core_onCursorHidden(void *ctx) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(rdpClientDidHideCursor:)])
            [self.delegate rdpClientDidHideCursor:self];
    });
}

static void core_onCursorDefault(void *ctx) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(rdpClientDidResetCursor:)])
            [self.delegate rdpClientDidResetCursor:self];
    });
}

// Server too old for the graphics pipeline: hand it to the delegate, which reconnects.
static void core_onLegacyGraphicsSuggested(void *ctx) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(rdpClientNeedsLegacyGraphics:)])
            [self.delegate rdpClientNeedsLegacyGraphics:self];
    });
}

// Remote pasted (wants our clipboard) -> answer from the local pasteboard.
static void core_onClipboardDataRequested(void *ctx, uint32_t formatId) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self provideLocalClipboardForFormat:formatId];
    });
}

// Remote pasted files (Explorer asked for the file list we announced).
static void core_onClipboardFilesRequested(void *ctx) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self provideLocalClipboardFiles];
    });
}

// MARK: - Remote clipboard files

@implementation RDPRemoteFile
- (instancetype)initWithCore:(const RDPCoreRemoteFile *)f index:(uint32_t)index {
    if ((self = [super init])) {
        _index = index;
        NSUInteger len = 0;
        while (len < 260 && f->name[len]) len++;
        _remotePath = [NSString stringWithCharacters:(const unichar *)f->name length:len];
        _isDirectory = f->isDirectory;
        _size = f->hasSize ? (int64_t)f->size : -1;
        // FILETIME counts 100 ns from 1601-01-01; the Unix epoch is 11 644 473 600 s later.
        if (f->hasWriteTime && f->writeTime > 116444736000000000ULL)
            _modified = [NSDate dateWithTimeIntervalSince1970:
                         (double)(f->writeTime - 116444736000000000ULL) / 1e7];
    }
    return self;
}
@end

static void core_onClipboardRemoteFiles(void *ctx, const RDPCoreRemoteFile *files, uint32_t count) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    NSMutableArray<RDPRemoteFile *> *list = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++)
        [list addObject:[[RDPRemoteFile alloc] initWithCore:&files[i] index:i]];
    dispatch_async(dispatch_get_main_queue(), ^{
        id<RDPClientDelegate> d = self.delegate;
        if ([d respondsToSelector:@selector(rdpClient:didCopyRemoteFiles:)])
            [d rdpClient:self didCopyRemoteFiles:list];
    });
}

static void core_onClipboardFileContents(void *ctx, uint32_t streamId, bool ok,
                                         const uint8_t *data, uint32_t size) {
    RDPClient *self = (__bridge RDPClient *)ctx;
    [self deliverFileContents:streamId ok:ok data:(ok && data) ? [NSData dataWithBytes:data length:size] : nil];
}

static void core_onClipboardChannelClosed(void *ctx) {
    [(__bridge RDPClient *)ctx abortRemoteFileRequests];
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
                       width:(int)width height:(int)height scale:(int)scalePercent
                sharedFolder:(NSString *)sharedFolder
           useLegacyGraphics:(BOOL)useLegacyGraphics {
    if (self = [super init]) {
        _host = [host copy];
        _port = port;
        _username = [username copy];
        _domain = [domain copy];
        _password = [password copy];
        _width = width;
        _height = height;
        _scale = scalePercent;
        _sharedFolder = [sharedFolder copy];
        _useLegacyGraphics = useLegacyGraphics;
    }
    return self;
}

- (void)start {
    if (_core) return;
    RDPCoreCallbacks cb = {
        .onConnected = core_onConnected,
        .onImage = core_onImage,
        .onDisconnected = core_onDisconnected,
        .onClipboardRemoteData = core_onClipboardRemoteData,
        .onClipboardDataRequested = core_onClipboardDataRequested,
        .onClipboardFilesRequested = core_onClipboardFilesRequested,
        .onClipboardRemoteFiles = core_onClipboardRemoteFiles,
        .onClipboardFileContents = core_onClipboardFileContents,
        .onClipboardChannelClosed = core_onClipboardChannelClosed,
        .onLegacyGraphicsSuggested = core_onLegacyGraphicsSuggested,
        .onCursorShape = core_onCursorShape,
        .onCursorHidden = core_onCursorHidden,
        .onCursorDefault = core_onCursorDefault,
    };
    // core holds a +1 retain on self for the lifetime of the connection
    // (released in core_onDisconnected).
    void *ctx = (__bridge_retained void *)self;
    _core = rdpcore_create(self.host.UTF8String, self.port,
                           self.username.UTF8String, self.domain.UTF8String,
                           self.password.UTF8String, self.width, self.height, self.scale,
                           _sharedFolder.length ? _sharedFolder.fileSystemRepresentation : NULL,
                           _useLegacyGraphics ? 1 : 0,
                           cb, ctx);
    rdpcore_start(_core);

    // Poll the local pasteboard; on change, announce the available formats so the
    // remote can paste from the Mac. Weak self so the timer never keeps us alive.
    // Start at -1 so the first tick offers whatever is ALREADY on the pasteboard,
    // and only advance the marker once the announce reaches the channel (so we keep
    // retrying until cliprdr connects).
    _lastPasteboardChangeCount = -1;
    __weak RDPClient *weakSelf = self;
    _clipboardTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
        RDPClient *strong = weakSelf;
        if (!strong) { [t invalidate]; return; }
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        NSInteger cc = pb.changeCount;
        if (cc == strong->_lastPasteboardChangeCount) return;
        NSArray<NSPasteboardType> *types = pb.types;
        BOOL hasText = [types containsObject:NSPasteboardTypeString];
        BOOL hasImage = [types containsObject:NSPasteboardTypeTIFF] || [types containsObject:NSPasteboardTypePNG];
        // Finder puts the names on as text as well, so both go out: Explorer takes the
        // file list, Notepad takes the names — the same split Windows makes itself.
        BOOL hasFiles = [types containsObject:NSPasteboardTypeFileURL];
        if (rdpcore_clipboard_announce(strong->_core, hasText, hasImage, hasFiles))
            strong->_lastPasteboardChangeCount = cc;
    }];
}

- (void)stop {
    if (_core) rdpcore_stop(_core);
    [_clipboardTimer invalidate];
    _clipboardTimer = nil;
    [self abortRemoteFileRequests];
}

- (void)noteOwnPasteboardWrite {
    _lastPasteboardChangeCount = NSPasteboard.generalPasteboard.changeCount;
}

- (void)deliverFileContents:(uint32_t)streamId ok:(BOOL)ok data:(NSData *)data {
    @synchronized (self) {
        // Only the request still being waited for; anything else is a late reply.
        if (!_fileSema || streamId != _fileStreamId) return;
        _fileResponse = data;
        _fileResponseOK = ok;
        dispatch_semaphore_signal(_fileSema);
        _fileSema = nil;
    }
}

- (void)abortRemoteFileRequests {
    @synchronized (self) {
        if (!_fileSema) return;
        _fileResponse = nil;
        _fileResponseOK = NO;
        dispatch_semaphore_signal(_fileSema);
        _fileSema = nil;
    }
}

static NSError *mrng_fileError(NSString *what) {
    return [NSError errorWithDomain:@"ro.cremenescu.mRemoteNXT.RemoteFiles" code:1
                           userInfo:@{NSLocalizedDescriptionKey: what}];
}

- (nullable NSData *)remoteFileRequest:(uint32_t)index sizeOnly:(BOOL)sizeOnly
                                offset:(uint64_t)offset length:(uint32_t)length
                                 error:(NSError **)error {
    NSAssert(!NSThread.isMainThread, @"remote file reads block until the server answers");
    @synchronized (self) { if (!_fileRequestLock) _fileRequestLock = [NSLock new]; }
    [_fileRequestLock lock];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    uint32_t sid;
    @synchronized (self) {
        sid = ++_fileStreamId;
        _fileSema = sema;
        _fileResponse = nil;
        _fileResponseOK = NO;
    }
    BOOL sent = _core && rdpcore_clipboard_request_file_contents(_core, sid, index, sizeOnly, offset, length);
    // Thirty seconds of silence for one chunk means the remote is not going to answer:
    // its clipboard changed under us, or the link is gone.
    BOOL answered = sent && dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0;
    NSData *data;
    BOOL ok;
    @synchronized (self) {
        if (_fileSema == sema) _fileSema = nil; // timed out: stop listening for it
        data = _fileResponse;
        ok = _fileResponseOK;
        _fileResponse = nil;
    }
    [_fileRequestLock unlock];
    if (!sent) { if (error) *error = mrng_fileError(@"The session's clipboard is not available."); return nil; }
    if (!answered) { if (error) *error = mrng_fileError(@"The remote computer stopped answering."); return nil; }
    if (!ok || !data) {
        if (error) *error = mrng_fileError(@"The remote computer refused the file — it may have copied something else since.");
        return nil;
    }
    return data;
}

- (nullable NSNumber *)sizeOfRemoteFileAtIndex:(uint32_t)index error:(NSError **)error {
    NSData *d = [self remoteFileRequest:index sizeOnly:YES offset:0 length:8 error:error];
    if (!d) return nil;
    if (d.length < 8) { if (error) *error = mrng_fileError(@"The remote computer sent a malformed size."); return nil; }
    uint64_t v = 0;
    memcpy(&v, d.bytes, 8);
    return @((int64_t)OSSwapLittleToHostInt64(v));
}

- (nullable NSData *)readRemoteFileAtIndex:(uint32_t)index offset:(uint64_t)offset
                                    length:(uint32_t)length error:(NSError **)error {
    return [self remoteFileRequest:index sizeOnly:NO offset:offset length:length error:error];
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
- (void)setKeyboardLayout:(uint32_t)klid { rdpcore_set_keyboard_layout(_core, klid); }
- (void)keyChar:(uint16_t)unicode down:(BOOL)down { rdpcore_key_unicode(_core, unicode, down); }
- (void)keyScancode:(uint8_t)code extended:(BOOL)extended down:(BOOL)down {
    rdpcore_key_scancode(_core, code, extended, down);
}
- (void)keySpecial:(NSInteger)key down:(BOOL)down { rdpcore_key_special(_core, (int)key, down); }

- (void)applyRemoteClipboardData:(NSData *)data format:(uint32_t)formatId {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    if (formatId == MRNG_CF_UNICODETEXT) {
        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
        str = [str stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
        if (str) {
            [pb clearContents];
            [pb setString:str forType:NSPasteboardTypeString];
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
        NSString *str = [pb stringForType:NSPasteboardTypeString];
        if (str) {
            NSMutableData *d = [[str dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
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

// The file list goes to FreeRDP as text/uri-list, one "file://<path>" per line. Paths are
// left unencoded on purpose: both winpr (which builds the descriptors) and the file helper
// (which later serves the bytes) run the same percent-decoder over them, and the helper
// checks whether an entry is a folder on the *raw* line — so a folder with a space in its
// name would be read as a plain file if it arrived as "My%20Folder". Only a literal "%XX"
// in a name is misread this way, which upstream shares.
- (void)provideLocalClipboardFiles {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[NSURL.class]
                                               options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableString *list = [NSMutableString string];
    for (NSURL *u in urls) {
        NSString *path = u.path;
        if (path.length == 0 || [path containsString:@"\n"] || [path containsString:@"\r"]) continue;
        [list appendFormat:@"file://%@\r\n", path];
    }
    NSData *bytes = [list dataUsingEncoding:NSUTF8StringEncoding];
    // Length includes the terminator: winpr's parser walks to a NUL it expects to be there.
    rdpcore_clipboard_provide_files(_core, bytes.length ? list.UTF8String : NULL,
                                    bytes.length ? (uint32_t)bytes.length + 1 : 0);
}

@end
