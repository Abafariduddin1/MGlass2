#pragma once
#import <Foundation/Foundation.h>

@interface MGCloudClient : NSObject
+ (instancetype)shared;
- (NSURL *)mediaURLForFile:(NSString *)fileID resourceKey:(NSString *)resourceKey;
- (NSURLSessionDataTask *)listFolder:(NSString *)folderID resourceKey:(NSString *)resourceKey
                         completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion;
- (NSURLSessionDownloadTask *)downloadFile:(NSString *)fileID resourceKey:(NSString *)resourceKey
                                     kind:(NSString *)kind completion:(void (^)(NSURL *, NSError *))completion;
@end
