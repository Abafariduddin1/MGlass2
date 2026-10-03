#pragma once
#import <Foundation/Foundation.h>

@interface MGCloudClient : NSObject
+ (instancetype)shared;
- (NSURLSessionDataTask *)listFolder:(NSString *)folderID resourceKey:(NSString *)resourceKey
                         completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion;
- (NSURLSessionDownloadTask *)downloadFile:(NSString *)fileID resourceKey:(NSString *)resourceKey
                                     kind:(NSString *)kind completion:(void (^)(NSURL *, NSError *))completion;
@end
