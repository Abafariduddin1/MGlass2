#pragma once
#import <Foundation/Foundation.h>

@interface MGEpubBook : NSObject
@property (nonatomic, strong, readonly) NSURL *directory;
@property (nonatomic, copy, readonly) NSArray<NSURL *> *chapters;
@property (nonatomic, copy, readonly) NSArray<NSString *> *chapterTitles;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, readonly) BOOL fixedLayout;
@property (nonatomic, readonly) BOOL rightToLeft;
+ (instancetype)openURL:(NSURL *)file error:(NSError **)error;
@end
