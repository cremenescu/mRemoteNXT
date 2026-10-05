/* SPDX-License-Identifier: GPL-2.0-or-later
 * mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
 * See LICENSE for full text.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class RDPClient;

/// One entry of the file list the remote session put on its clipboard.
@interface RDPRemoteFile : NSObject
/// Position in the remote's list: what the contents are asked by.
@property (nonatomic, readonly) uint32_t index;
/// Path relative to what was copied, exactly as the remote sent it (backslash-separated).
/// Untrusted: it comes from the server, and must be sanitised before it touches the disk.
@property (nonatomic, readonly, copy) NSString *remotePath;
@property (nonatomic, readonly) BOOL isDirectory;
/// -1 when the remote did not say.
@property (nonatomic, readonly) int64_t size;
@property (nonatomic, readonly, nullable) NSDate *modified;
/// The lock keeping this list readable after the remote clipboard changes; 0 = none.
@property (nonatomic, readonly) uint32_t clipDataId;
@end

@protocol RDPClientDelegate <NSObject>
- (void)rdpClient:(RDPClient *)client didConnectWithWidth:(int)width height:(int)height;
- (void)rdpClient:(RDPClient *)client didUpdateImage:(CGImageRef)image;
- (void)rdpClient:(RDPClient *)client didDisconnectWithError:(nullable NSString *)error;
@optional
/// The server is too old for the graphics pipeline. Remember the host and reconnect
/// with useLegacyGraphics — this connection can no longer be changed.
- (void)rdpClientNeedsLegacyGraphics:(RDPClient *)client;
/// The remote pointer changed shape. `hotSpot` is in image pixels, top-left origin.
- (void)rdpClient:(RDPClient *)client didUpdateCursor:(CGImageRef)image hotSpot:(CGPoint)hotSpot;
/// The remote hid the pointer, or asked for the plain system arrow.
- (void)rdpClientDidHideCursor:(RDPClient *)client;
- (void)rdpClientDidResetCursor:(RDPClient *)client;
/// Files were copied in the remote session. Called on the main thread.
- (void)rdpClient:(RDPClient *)client didCopyRemoteFiles:(NSArray<RDPRemoteFile *> *)files;
@end

/// Wrapper around FreeRDP3: connects on its own thread, software GDI rendering (BGRA),
/// delivers a CGImage to the delegate on each repaint.
@interface RDPClient : NSObject

@property (nonatomic, weak) id<RDPClientDelegate> delegate;

/// Enable/disable FreeRDP diagnostic logging to <directory>/mRemoteNXT.log (DEBUG level).
+ (void)setDiagnosticLogging:(BOOL)enabled directory:(NSString *)directory;

/// One-time OpenSSL init: loads the legacy provider so NTLM (MD4) works against
/// non-AD Windows hosts. Call once at app launch, before any connection.
+ (void)initCrypto;

- (instancetype)initWithHost:(NSString *)host
                        port:(int)port
                    username:(NSString *)username
                      domain:(NSString *)domain
                    password:(NSString *)password
                       width:(int)width
                      height:(int)height
                       scale:(int)scalePercent
                   sharedFolder:(nullable NSString *)sharedFolder
             useLegacyGraphics:(BOOL)useLegacyGraphics;

/// Windows keyboard layout id announced to the server. Set before -start.
- (void)setKeyboardLayout:(uint32_t)klid;

- (void)start;
- (void)stop;
- (void)resizeToWidth:(int)width height:(int)height scale:(int)scalePercent;

// Remote clipboard files. Both BLOCK until the remote answers, one request at a time, so
// they must never be called on the main thread — the answer is delivered on the RDP thread
// and the main thread may be needed meanwhile. They fail on timeout, on a refused request,
// and when the session or its clipboard channel goes away.
- (nullable NSNumber *)sizeOfRemoteFileAtIndex:(uint32_t)index lock:(uint32_t)clipDataId
                                         error:(NSError **)error;
- (nullable NSData *)readRemoteFileAtIndex:(uint32_t)index offset:(uint64_t)offset
                                    length:(uint32_t)length lock:(uint32_t)clipDataId
                                     error:(NSError **)error;
/// Release a lock taken for a remote file list (see RDPRemoteFile.clipDataId).
- (void)unlockRemoteClipboard:(uint32_t)clipDataId;
/// Bracket a transfer of remote clipboard files. While one runs (and for a few seconds
/// after, so the files of a folder are not split by a gap), changes to the Mac clipboard are
/// held back from this session and announced once it is idle.
- (void)beginRemoteFileTransfer;
- (void)endRemoteFileTransfer;
/// The pasteboard was just written on this session's behalf; don't offer it back to the remote.
- (void)noteOwnPasteboardWrite;

// Semantic input (coordinates in the RDP desktop's pixel space).
- (void)mouseMoveToX:(int)x y:(int)y;
- (void)mouseButton:(int)button down:(BOOL)down x:(int)x y:(int)y; // 1=left 2=right 3=middle
- (void)scrollSteps:(int)steps x:(int)x y:(int)y;                  // + up, - down
- (void)keyChar:(uint16_t)unicode down:(BOOL)down;
- (void)keyScancode:(uint8_t)code extended:(BOOL)extended down:(BOOL)down;
- (void)keySpecial:(NSInteger)key down:(BOOL)down;                 // see RDPKey* below

@end

// Special keys for keySpecial:
typedef NS_ENUM(NSInteger, RDPSpecialKey) {
    RDPKeyEnter = 1, RDPKeyBackspace, RDPKeyTab, RDPKeyEscape, RDPKeySpace,
    RDPKeyUp, RDPKeyDown, RDPKeyLeft, RDPKeyRight, RDPKeyDelete,
    RDPKeyShift, RDPKeyControl, RDPKeyAlt, RDPKeyCommand
};

NS_ASSUME_NONNULL_END
