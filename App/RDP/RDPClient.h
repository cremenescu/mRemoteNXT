/* SPDX-License-Identifier: GPL-2.0-or-later
 * mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
 * See LICENSE for full text.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class RDPClient;

@protocol RDPClientDelegate <NSObject>
- (void)rdpClient:(RDPClient *)client didConnectWithWidth:(int)width height:(int)height;
- (void)rdpClient:(RDPClient *)client didUpdateImage:(CGImageRef)image;
- (void)rdpClient:(RDPClient *)client didDisconnectWithError:(nullable NSString *)error;
@end

/// Wrapper around FreeRDP3: connects on its own thread, software GDI rendering (BGRA),
/// delivers a CGImage to the delegate on each repaint.
@interface RDPClient : NSObject

@property (nonatomic, weak) id<RDPClientDelegate> delegate;

- (instancetype)initWithHost:(NSString *)host
                        port:(int)port
                    username:(NSString *)username
                      domain:(NSString *)domain
                    password:(NSString *)password
                       width:(int)width
                      height:(int)height
                       scale:(int)scalePercent;

- (void)start;
- (void)stop;
- (void)resizeToWidth:(int)width height:(int)height scale:(int)scalePercent;

// Semantic input (coordinates in the RDP desktop's pixel space).
- (void)mouseMoveToX:(int)x y:(int)y;
- (void)mouseButton:(int)button down:(BOOL)down x:(int)x y:(int)y; // 1=left 2=right 3=middle
- (void)scrollSteps:(int)steps x:(int)x y:(int)y;                  // + up, - down
- (void)keyChar:(uint16_t)unicode down:(BOOL)down;
- (void)keySpecial:(NSInteger)key down:(BOOL)down;                 // see RDPKey* below

@end

// Special keys for keySpecial:
typedef NS_ENUM(NSInteger, RDPSpecialKey) {
    RDPKeyEnter = 1, RDPKeyBackspace, RDPKeyTab, RDPKeyEscape, RDPKeySpace,
    RDPKeyUp, RDPKeyDown, RDPKeyLeft, RDPKeyRight, RDPKeyDelete,
    RDPKeyShift, RDPKeyControl, RDPKeyAlt, RDPKeyCommand
};

NS_ASSUME_NONNULL_END
