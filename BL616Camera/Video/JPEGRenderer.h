#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/* Synchronous ImageIO decoding. Call from a background queue. */
FOUNDATION_EXPORT UIImage * _Nullable HBDecodeJPEG(NSData *jpeg);
NS_ASSUME_NONNULL_END
