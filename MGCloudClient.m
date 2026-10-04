#import "MGCloudClient.h"
#import "MGConfig.h"
#import <CommonCrypto/CommonDigest.h>

static NSError *MGCloudError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"MangaGlass.Cloud" code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"Cloud request failed."}];
}

@implementation MGCloudClient {
    NSURLSession *_session;
    NSURL *_cacheDirectory;
    dispatch_queue_t _fileQueue;
}
+ (instancetype)shared {
    static MGCloudClient *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ client = [MGCloudClient new]; });
    return client;
}
- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 45;
        configuration.timeoutIntervalForResource = 240;
        configuration.HTTPMaximumConnectionsPerHost = 3;
        _session = [NSURLSession sessionWithConfiguration:configuration];
        _cacheDirectory = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"MangaGlass" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:_cacheDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        _fileQueue = dispatch_queue_create("com.custom.mangaglass.files", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (NSURL *)URLForPath:(NSString *)path IDKey:(NSString *)key ID:(NSString *)identifier resourceKey:(NSString *)resourceKey {
    NSURLComponents *components = [NSURLComponents componentsWithString:[MG_WORKER_URL stringByAppendingString:path]];
    NSMutableArray *query = [NSMutableArray array];
    if (identifier.length) [query addObject:[NSURLQueryItem queryItemWithName:key value:identifier]];
    if (resourceKey.length) [query addObject:[NSURLQueryItem queryItemWithName:@"resourceKey" value:resourceKey]];
    components.queryItems = query;
    return components.URL;
}
- (NSURLSessionDataTask *)listFolder:(NSString *)folderID resourceKey:(NSString *)resourceKey
                         completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    NSURL *url = [self URLForPath:@"/api/library" IDKey:@"folderId" ID:folderID resourceKey:resourceKey];
    NSURLSessionDataTask *task = [_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        id body = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *items = nil;
        if (!error && (status < 200 || status >= 300)) {
            NSString *message = [body isKindOfClass:[NSDictionary class]] && [body[@"error"] isKindOfClass:[NSDictionary class]] ? body[@"error"][@"message"] : nil;
            error = MGCloudError([message isKindOfClass:[NSString class]] ? message : @"The library could not be loaded. Try again.", status);
        }
        if (!error && ![body isKindOfClass:[NSArray class]]) error = MGCloudError(@"The server returned invalid library data.", 502);
        if (!error) {
            NSMutableArray *valid = [NSMutableArray array];
            for (id value in body) {
                if (![value isKindOfClass:[NSDictionary class]] || ![value[@"id"] isKindOfClass:[NSString class]] ||
                    ![value[@"name"] isKindOfClass:[NSString class]] || ![@[@"image", @"folder", @"pdf", @"epub", @"audio", @"video", @"document"] containsObject:value[@"type"]]) continue;
                NSMutableDictionary *item = [value mutableCopy];
                if (![item[@"resourceKey"] isKindOfClass:[NSString class]]) [item removeObjectForKey:@"resourceKey"];
                if (![item[@"width"] isKindOfClass:[NSNumber class]]) [item removeObjectForKey:@"width"];
                if (![item[@"height"] isKindOfClass:[NSNumber class]]) [item removeObjectForKey:@"height"];
                [valid addObject:item];
            }
            [valid sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                BOOL af = [a[@"type"] isEqualToString:@"folder"], bf = [b[@"type"] isEqualToString:@"folder"];
                if (af != bf) return af ? NSOrderedAscending : NSOrderedDescending;
                return [a[@"name"] localizedStandardCompare:b[@"name"]];
            }];
            items = valid;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(items, error); });
    }];
    [task resume];
    return task;
}
- (NSURL *)cacheURL:(NSString *)fileID kind:(NSString *)kind {
    NSData *data = [fileID dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *name = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [name appendFormat:@"%02x", digest[i]];
    return [_cacheDirectory URLByAppendingPathComponent:[name stringByAppendingPathExtension:kind]];
}
- (NSURL *)mediaURLForFile:(NSString *)fileID resourceKey:(NSString *)resourceKey {
    return [self URLForPath:@"/api/page" IDKey:@"fileId" ID:fileID resourceKey:resourceKey];
}
- (void)discardDownloadedFile:(NSURL *)file completion:(void (^)(void))completion {
    dispatch_async(_fileQueue, ^{
        NSString *prefix=[self->_cacheDirectory.path.stringByStandardizingPath stringByAppendingString:@"/"];
        if (file.isFileURL && [file.path.stringByStandardizingPath hasPrefix:prefix]) [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(); });
    });
}
- (void)trimCacheKeeping:(NSURL *)current {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *files = [manager contentsOfDirectoryAtURL:_cacheDirectory includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *first = nil, *second = nil;
        [a getResourceValue:&first forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&second forKey:NSURLContentModificationDateKey error:nil];
        return [(first ?: [NSDate distantPast]) compare:(second ?: [NSDate distantPast])];
    }];
    unsigned long long total = 0;
    for (NSURL *file in files) { NSNumber *size = nil; [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil]; total += size.unsignedLongLongValue; }
    for (NSURL *file in files) {
        if (total <= 256ULL * 1024 * 1024) break;
        if ([file isEqual:current]) continue;
        NSNumber *size = nil; [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if ([manager removeItemAtURL:file error:nil]) total -= MIN(total, size.unsignedLongLongValue);
    }
}
- (NSURLSessionDownloadTask *)downloadFile:(NSString *)fileID resourceKey:(NSString *)resourceKey
                                     kind:(NSString *)kind completion:(void (^)(NSURL *, NSError *))completion {
    NSURL *cached = [self cacheURL:fileID kind:kind];
    NSDate *modified = nil;
    [cached getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
    if (modified && -modified.timeIntervalSinceNow < 86400) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return nil;
    }
    NSURL *url = [self URLForPath:@"/api/page" IDKey:@"fileId" ID:fileID resourceKey:resourceKey];
    NSURLSessionDownloadTask *task = [_session downloadTaskWithURL:url completionHandler:^(NSURL *temporary, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (!error && (status < 200 || status >= 300)) error = MGCloudError(@"This page could not be downloaded. Check your connection and Drive sharing, then retry.", status);
        if (!error && status == 206) error = MGCloudError(@"The server returned only part of this file. Retry the download.", status);
        NSURL *result = nil;
        // NSURLSession removes the temporary URL when this callback returns.
        // Move synchronously on our file queue, never on the UI thread.
        if (!error && temporary) dispatch_sync(self->_fileQueue, ^{
            [[NSFileManager defaultManager] removeItemAtURL:cached error:nil];
            [[NSFileManager defaultManager] moveItemAtURL:temporary toURL:cached error:nil];
            [self trimCacheKeeping:cached];
        });
        if (!error && [[NSFileManager defaultManager] fileExistsAtPath:cached.path]) result = cached;
        else if (!error) error = MGCloudError(@"The downloaded file could not be saved.", 500);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
    }];
    [task resume];
    return task;
}
@end
