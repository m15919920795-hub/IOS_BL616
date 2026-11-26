#import "JPEGRenderer.h"
#import <ImageIO/ImageIO.h>

UIImage *HBDecodeJPEG(NSData *jpeg) {
    if (jpeg.length < 4) return nil;
    const uint8_t *bytes = jpeg.bytes;
    if (bytes[0] != 0xFF || bytes[1] != 0xD8) return nil;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!source) return nil;

    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    uint64_t width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    uint64_t height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    UIImage *image = nil;
    if (width && height && width <= 4096 && height <= 4096) {
        NSDictionary *options = @{(__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES};
        CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        if (cgImage) {
            image = [UIImage imageWithCGImage:cgImage];
            CGImageRelease(cgImage);
        }
    }
    CFRelease(source);
    return image;
}
