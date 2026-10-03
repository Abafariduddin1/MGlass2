#pragma once
#import <UIKit/UIKit.h>
#import <PDFKit/PDFKit.h>
#import "MGReaderGeometry.h"

@interface MGPageRequest : NSObject
@property (atomic) BOOL cancelled;
@property (nonatomic, strong) NSURLSessionTask *task;
- (void)cancel;
@end

@interface MGPageProvider : NSObject
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *pages;
@property (nonatomic, strong, readonly) PDFDocument *document;
@property (nonatomic, copy) void (^dimensionsDidChange)(void);
- (instancetype)initWithImages:(NSArray<NSDictionary *> *)pages;
- (NSURLSessionTask *)loadPDF:(NSString *)fileID resourceKey:(NSString *)resourceKey completion:(void (^)(NSError *))completion;
- (NSUInteger)count;
- (CGSize)sizeAtIndex:(NSUInteger)index;
- (MGPageRequest *)imageAtIndex:(NSUInteger)index half:(MGHalf)half completion:(void (^)(UIImage *, NSError *))completion;
- (void)clearRenderedCache;
@end
