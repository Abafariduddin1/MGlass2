#import "MGPageProvider.h"
#import "MGCloudClient.h"
#import "MGSettings.h"
#import <ImageIO/ImageIO.h>
#import <CoreImage/CoreImage.h>
#include <math.h>
#include <stdlib.h>

@implementation MGPageRequest
- (void)cancel { self.cancelled = YES; [self.task cancel]; }
@end

@interface MGPDFRasterSource : NSObject
@property (nonatomic, readonly) CGPDFDocumentRef document;
- (instancetype)initWithURL:(NSURL *)file;
@end
@implementation MGPDFRasterSource
- (instancetype)initWithURL:(NSURL *)file {
    if ((self = [super init])) { _document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)file); if (!_document) return nil; }
    return self;
}
- (void)dealloc { if (_document) CGPDFDocumentRelease(_document); }
@end

@interface MGPageProvider ()
@property (nonatomic, copy, readwrite) NSArray<NSDictionary *> *pages;
@property (nonatomic, strong, readwrite) PDFDocument *document;
@end

static UIImage *MGCompactImage(UIImage *image) {
    CGImageRef original = image.CGImage; if (!original) return image;
    size_t width = CGImageGetWidth(original), height = CGImageGetHeight(original);
    if (!width || !height || width > SIZE_MAX / 4) return image;
    CGColorSpaceRef originalSpace = CGImageGetColorSpace(original);
    CGColorSpaceRef space = originalSpace && CGColorSpaceGetModel(originalSpace) == kCGColorSpaceModelRGB ? CGColorSpaceRetain(originalSpace) : CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space); if (!bitmap) return image;
    CGContextSetBlendMode(bitmap, kCGBlendModeCopy); CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), original);
    CGImageRef compact = CGBitmapContextCreateImage(bitmap);
    UIImage *result = compact ? [UIImage imageWithCGImage:compact scale:1 orientation:UIImageOrientationUp] : image;
    if (compact) CGImageRelease(compact); CGContextRelease(bitmap); return result;
}
static UIImage *MGProcessImage(UIImage *image, MGHalf half, BOOL crop, BOOL grayscale, BOOL sharpen, CIContext *context, CGSize *contentSize) {
    CGImageRef original = image.CGImage;
    if (!original) return nil;
    size_t width = CGImageGetWidth(original), height = CGImageGetHeight(original);
    CGRect region = CGRectMake(0, 0, width, height);
    CGImageRef current = CGImageCreateWithImageInRect(original, region);
    if (!current) return nil;
    if (crop) {
        const size_t sampleWidth = 128, sampleHeight = 128;
        uint8_t *pixels = calloc(sampleWidth * sampleHeight * 4, 1);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmap = pixels ? CGBitmapContextCreate(pixels, sampleWidth, sampleHeight, 8, sampleWidth * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
        CGColorSpaceRelease(space);
        if (bitmap) {
            CGContextSetRGBFillColor(bitmap, 1, 1, 1, 1);
            CGContextFillRect(bitmap, CGRectMake(0, 0, sampleWidth, sampleHeight));
            CGContextTranslateCTM(bitmap, 0, sampleHeight);
            CGContextScaleCTM(bitmap, 1, -1);
            CGContextDrawImage(bitmap, CGRectMake(0, 0, sampleWidth, sampleHeight), current);
            MGUnitRect unit = MGContentBounds(pixels, sampleWidth, sampleHeight, sampleWidth * 4);
            CGRect bounds = CGRectIntegral(CGRectMake(unit.x * CGImageGetWidth(current), unit.y * CGImageGetHeight(current), unit.width * CGImageGetWidth(current), unit.height * CGImageGetHeight(current)));
            CGImageRef trimmed = CGImageCreateWithImageInRect(current, bounds);
            if (trimmed) { CGImageRelease(current); current = trimmed; }
            CGContextRelease(bitmap);
        }
        free(pixels);
    }
    // Crop the whole scan before splitting it; splitting first can turn a small
    // centred scan into two almost blank halves and report the wrong aspect ratio.
    if (contentSize) *contentSize = CGSizeMake(CGImageGetWidth(current), CGImageGetHeight(current));
    if (half != MGWholePage) {
        size_t cut = CGImageGetWidth(current) / 2;
        CGRect halfRect = half == MGLeftHalf ? CGRectMake(0, 0, cut, CGImageGetHeight(current)) : CGRectMake(cut, 0, CGImageGetWidth(current) - cut, CGImageGetHeight(current));
        CGImageRef part = CGImageCreateWithImageInRect(current, halfRect);
        if (part) { CGImageRelease(current); current = part; }
    }
    UIImage *result = [UIImage imageWithCGImage:current scale:1 orientation:UIImageOrientationUp];
    if (grayscale || sharpen) {
        CIImage *input = [CIImage imageWithCGImage:current];
        CGRect extent = input.extent;
        if (grayscale) {
            CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
            [filter setValue:input forKey:kCIInputImageKey];
            [filter setValue:@0 forKey:kCIInputSaturationKey];
            input = filter.outputImage ?: input;
        }
        if (sharpen) {
            CIFilter *filter = [CIFilter filterWithName:@"CISharpenLuminance"];
            [filter setValue:input forKey:kCIInputImageKey];
            [filter setValue:@.35 forKey:kCIInputSharpnessKey];
            input = filter.outputImage ?: input;
        }
        CGImageRef processed = [context createCGImage:input fromRect:extent];
        if (processed) { result = [UIImage imageWithCGImage:processed]; CGImageRelease(processed); }
    }
    // A subimage can retain its parent's entire pixel buffer. Copy just the
    // displayed region so the cache cost reflects actual retained pixel memory.
    if (crop || half != MGWholePage) result = MGCompactImage(result);
    CGImageRelease(current);
    return result;
}

static NSUInteger MGRenderPixelLimit(CGSize size, BOOL lowMemory) {
    CGFloat ratio = size.height / MAX(1, size.width);
    if (ratio <= 3) return lowMemory ? 1536 : 3072;
    // A normal page cap would make long strips unreadable. Keep a bounded pixel
    // budget instead: up to 12 MP / 16,384 px, or 4 MP / 8,192 px in low-memory mode.
    double pixels = (lowMemory ? 4.0 : 12.0) * 1024 * 1024;
    return (NSUInteger)MIN(lowMemory ? 8192 : 16384, sqrt(pixels * ratio));
}

static CGSize MGPDFPageSize(CGPDFPageRef reference) {
    if (!reference) return CGSizeZero;
    CGSize size = CGPDFPageGetBoxRect(reference, kCGPDFCropBox).size;
    NSInteger rotation = CGPDFPageGetRotationAngle(reference);
    return labs(rotation) % 180 == 90 ? CGSizeMake(size.height, size.width) : size;
}

static UIImage *MGRasterPDFPage(CGPDFPageRef reference, CGSize sourceSize, NSUInteger maxPixel) {
    if (!reference || !isfinite(sourceSize.width) || !isfinite(sourceSize.height) || sourceSize.width <= 0 || sourceSize.height <= 0) return nil;
    CGFloat factor = maxPixel / MAX(sourceSize.width, sourceSize.height);
    size_t width = MAX(1, (size_t)ceil(sourceSize.width * factor));
    size_t height = MAX(1, (size_t)ceil(sourceSize.height * factor));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) return nil;
    CGRect rect = CGRectMake(0, 0, width, height);
    CGContextSetRGBFillColor(bitmap, 1, 1, 1, 1); CGContextFillRect(bitmap, rect);
    CGContextConcatCTM(bitmap, CGPDFPageGetDrawingTransform(reference, kCGPDFCropBox, rect, 0, true));
    CGContextDrawPDFPage(bitmap, reference);
    CGImageRef snapshot = CGBitmapContextCreateImage(bitmap);
    UIImage *image = snapshot ? [UIImage imageWithCGImage:snapshot scale:1 orientation:UIImageOrientationUp] : nil;
    if (snapshot) CGImageRelease(snapshot);
    CGContextRelease(bitmap);
    return image;
}

@implementation MGPageProvider {
    NSMutableArray<NSValue *> *_sizes;
    NSCache<NSString *, UIImage *> *_cache;
    dispatch_queue_t _renderQueue;
    CIContext *_context;
    MGPDFRasterSource *_rasterSource;
}
- (instancetype)init { return [self initWithImages:@[]]; }
- (instancetype)initWithImages:(NSArray<NSDictionary *> *)pages {
    if ((self = [super init])) {
        self.pages = pages;
        _sizes = [NSMutableArray array];
        for (NSDictionary *page in pages) {
            CGFloat width = [page[@"width"] doubleValue], height = [page[@"height"] doubleValue];
            [_sizes addObject:[NSValue valueWithCGSize:width > 0 && height > 0 ? CGSizeMake(width, height) : CGSizeZero]];
        }
        _cache = [NSCache new];
        _cache.totalCostLimit = [[MGSettings shared] flag:@"lowMemory"] ? 18 * 1024 * 1024 : 48 * 1024 * 1024;
        _cache.countLimit = 8;
        _renderQueue = dispatch_queue_create("com.custom.mangaglass.render", DISPATCH_QUEUE_SERIAL);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(memoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)memoryWarning:(NSNotification *)notification { (void)notification; [self clearRenderedCache]; }
- (void)clearRenderedCache { [_cache removeAllObjects]; _cache.totalCostLimit = [[MGSettings shared] flag:@"lowMemory"] ? 18 * 1024 * 1024 : 48 * 1024 * 1024; }
- (NSUInteger)count { return self.document ? self.document.pageCount : self.pages.count; }
- (CGSize)sizeAtIndex:(NSUInteger)index { return index < _sizes.count ? _sizes[index].CGSizeValue : CGSizeZero; }
- (NSURLSessionTask *)loadPDF:(NSString *)fileID resourceKey:(NSString *)resourceKey completion:(void (^)(NSError *))completion {
    __weak typeof(self) weakSelf = self;
    return [[MGCloudClient shared] downloadFile:fileID resourceKey:resourceKey kind:@"pdf" completion:^(NSURL *file, NSError *error) {
        typeof(self) owner = weakSelf;
        if (!owner) return;
        if (error) { completion(error); return; }
        dispatch_async(owner->_renderQueue, ^{
            PDFDocument *document = [[PDFDocument alloc] initWithURL:file];
            MGPDFRasterSource *raster = [[MGPDFRasterSource alloc] initWithURL:file];
            NSMutableArray *sizes = [NSMutableArray array];
            if (document && !document.isLocked && raster.document) for (NSUInteger i = 0; i < CGPDFDocumentGetNumberOfPages(raster.document); i++) {
                CGPDFPageRef page = CGPDFDocumentGetPage(raster.document, i + 1);
                CGSize size = MGPDFPageSize(page);
                [sizes addObject:[NSValue valueWithCGSize:size]];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!document || document.isLocked || !sizes.count) {
                    completion([NSError errorWithDomain:@"MangaGlass.PDF" code:1 userInfo:@{NSLocalizedDescriptionKey:@"This PDF is empty, password protected, or could not be opened."}]);
                    return;
                }
                owner.document = document;
                owner->_rasterSource = raster;
                owner->_sizes = sizes;
                completion(nil);
            });
        });
    }];
}
- (MGPageRequest *)imageAtIndex:(NSUInteger)index half:(MGHalf)half completion:(void (^)(UIImage *, NSError *))completion {
    MGPageRequest *request = [MGPageRequest new];
    if (index >= self.count) { request.cancelled = YES; return request; }
    MGSettings *settings = [MGSettings shared];
    BOOL low = [settings flag:@"lowMemory"], crop = [settings flag:@"cropMargins"] || (self.document && [settings flag:@"adaptiveFit"]), gray = [settings flag:@"grayscale"], sharp = [settings flag:@"sharpen"];
    NSString *cacheKey = [NSString stringWithFormat:@"%lu-%d-%d%d%d%d", (unsigned long)index, (int)half, low, crop, gray, sharp];
    UIImage *cached = [_cache objectForKey:cacheKey];
    if (cached) { dispatch_async(dispatch_get_main_queue(), ^{ if (!request.cancelled) completion(cached, nil); }); return request; }
    // The native PDFView owns PDFKit's document on the UI side. Raster jobs use
    // a separate Core Graphics document on this provider's serial render queue.
    MGPDFRasterSource *raster = _rasterSource;
    void (^render)(NSURL *, NSError *) = ^(NSURL *file, NSError *error) {
        if (request.cancelled) return;
        if (error) { completion(nil, error); return; }
        dispatch_async(self->_renderQueue, ^{
            @autoreleasepool {
                if (request.cancelled) return;
                UIImage *raw = nil;
                CGSize actual = CGSizeZero;
                if (raster) {
                    CGPDFPageRef page = CGPDFDocumentGetPage(raster.document, index + 1);
                    CGSize sourceSize = MGPDFPageSize(page);
                    raw = MGRasterPDFPage(page, sourceSize, MGRenderPixelLimit(sourceSize, low));
                    actual = sourceSize;
                } else {
                    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)file, NULL);
                    if (source) {
                        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
                        CGFloat width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
                        CGFloat height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
                        NSInteger orientation = [properties[(__bridge NSString *)kCGImagePropertyOrientation] integerValue];
                        actual = orientation >= 5 && orientation <= 8 ? CGSizeMake(height, width) : CGSizeMake(width, height);
                        NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
                            (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES,
                            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@(MGRenderPixelLimit(actual, low))};
                        CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
                        if (thumb) { raw = [UIImage imageWithCGImage:thumb]; CGImageRelease(thumb); }
                        CFRelease(source);
                    }
                }
                if ((gray || sharp) && !self->_context) self->_context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO}];
                CGSize contentSize = CGSizeZero;
                UIImage *image = MGProcessImage(raw, half, crop, gray, sharp, self->_context, &contentSize);
                if (crop && contentSize.width > 0 && contentSize.height > 0) actual = contentSize;
                if (image) [self->_cache setObject:image forKey:cacheKey cost:CGImageGetBytesPerRow(image.CGImage) * CGImageGetHeight(image.CGImage)];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (request.cancelled) return;
                    if (actual.width > 0 && actual.height > 0 && index < self->_sizes.count && !CGSizeEqualToSize(actual, self->_sizes[index].CGSizeValue)) {
                        self->_sizes[index] = [NSValue valueWithCGSize:actual];
                        if (self.dimensionsDidChange) self.dimensionsDidChange();
                    }
                    NSError *failure = image ? nil : [NSError errorWithDomain:@"MangaGlass.Image" code:1 userInfo:@{NSLocalizedDescriptionKey:@"This page could not be rendered. Tap Retry."}];
                    completion(image, failure);
                });
            }
        });
    };
    if (raster) render(nil, nil);
    else {
        NSDictionary *page = self.pages[index];
        request.task = [[MGCloudClient shared] downloadFile:page[@"id"] resourceKey:page[@"resourceKey"] kind:@"image" completion:render];
    }
    return request;
}
@end
