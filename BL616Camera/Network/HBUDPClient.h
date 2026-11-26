#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, HBClientState) {
    HBClientDisconnected, HBClientConnecting, HBClientReady,
    HBClientStarting, HBClientStreaming, HBClientStopping, HBClientDisconnecting
};
@class HBUDPClient;
@protocol HBUDPClientDelegate <NSObject>
/* All delegate callbacks run on the main queue. */
- (void)client:(HBUDPClient *)client didUpdateStatus:(NSDictionary<NSString *, id> *)status;
- (void)client:(HBUDPClient *)client didReceiveJPEG:(NSData *)jpeg generation:(uint64_t)generation;
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
- (void)setNeutralTXTestEnabled:(BOOL)enabled;
@end
NS_ASSUME_NONNULL_END
