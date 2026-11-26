#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, HBClientState) {
    HBClientDisconnected, HBClientConnecting, HBClientReady,
    HBClientStarting, HBClientStreaming, HBClientStopping, HBClientDisconnecting
};
@class HBUDPClient, UIImage;
@protocol HBUDPClientDelegate <NSObject>
/* Both callbacks run on the main queue. Clear a previous image when generation changes. */
- (void)client:(HBUDPClient *)client didUpdateState:(HBClientState)state
    generation:(uint64_t)generation localPort:(uint16_t)localPort message:(NSString *)message;

/* The JPEG has been reassembled and decoded. Pass this UIImage to your display layer. */
- (void)client:(HBUDPClient *)client didReceiveImage:(UIImage *)image generation:(uint64_t)generation;
@end

@interface HBUDPClient : NSObject
@property(nonatomic, weak, nullable) id<HBUDPClientDelegate> delegate;
- (void)connectToHost:(NSString *)host remotePort:(uint16_t)remotePort localPort:(uint16_t)localPort;
- (void)disconnect;
- (void)startVideo;
- (void)stopVideo;
/* Copy raw control bytes into subsequent B ACKs. Pass nil to stop sending control.
 * Returns NO for empty/oversize data or when setting data outside active playback. */
- (BOOL)setTXControlData:(nullable NSData *)data;
@end
NS_ASSUME_NONNULL_END
