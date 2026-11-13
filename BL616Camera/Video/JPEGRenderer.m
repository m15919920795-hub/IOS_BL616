#import "JPEGRenderer.h"
#import <ImageIO/ImageIO.h>

@interface JPEGRenderer ()
@property(atomic) uint64_t generation;
@end
@implementation JPEGRenderer {
    __weak UIImageView *_imageView;
    dispatch_queue_t _queue;
    NSData *_pending;
    BOOL _busy;
}
- (instancetype)initWithImageView:(UIImageView *)imageView {
    if ((self = [super init])) {
        _imageView = imageView;
        _queue = dispatch_queue_create("com.guanxukeji.bl616.jpeg", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)resetForGeneration:(uint64_t)generation {
    self.generation = generation;
    _pending = nil;
    _imageView.image = nil;
}
- (void)submitJPEG:(NSData *)jpeg generation:(uint64_t)generation {
    if (generation != self.generation) return;
    _pending = jpeg;
    [self decodeNext];
}
- (void)decodeNext {
    if (_busy || !_pending) return;
    NSData *jpeg = _pending; _pending = nil; _busy = YES;
    uint64_t generation = self.generation;
    dispatch_async(_queue, ^{
        @autoreleasepool {
            UIImage *image = nil;
            if (generation == self.generation && jpeg.length >= 4) {
                const uint8_t *bytes = jpeg.bytes;
                if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
                    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
                    if (source) {
                        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
                        uint64_t width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
                        uint64_t height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
                        if (width && height && width <= 4096 && height <= 4096 && width * height <= 16777216) {
                            NSDictionary *options = @{(__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES};
                            CGImageRef cg = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
                            if (cg) { image = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
                        }
                        CFRelease(source);
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation == self.generation) {
                    if (image) self->_imageView.image = image;
                    else if (self.decodeError) self.decodeError();
                }
                self->_busy = NO;
                [self decodeNext];
            });
        }
    });
}
@end
