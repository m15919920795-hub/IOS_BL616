#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface JPEGRenderer : NSObject
@property(nonatomic, copy, nullable) void (^decodeError)(void);
- (instancetype)initWithImageView:(UIImageView *)imageView;
/* Main queue only. Keep one decoding frame and one latest pending JPEG. */
- (void)resetForGeneration:(uint64_t)generation;
- (void)submitJPEG:(NSData *)jpeg generation:(uint64_t)generation;
@end
NS_ASSUME_NONNULL_END
