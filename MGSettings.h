#pragma once
#import <UIKit/UIKit.h>
#import "MGReaderGeometry.h"

extern NSString * const MGSettingsDidChangeNotification;
extern NSString * const MGBookmarksDidChangeNotification;

@interface MGSettings : NSObject
+ (instancetype)shared;
- (BOOL)flag:(NSString *)key;
- (NSString *)text:(NSString *)key;
- (void)setValue:(id)value forPreference:(NSString *)key;
- (MGDirection)direction;
@end

@interface MGBookmarkStore : NSObject
+ (NSArray<NSDictionary *> *)all;
+ (NSDictionary *)bookmarkForKey:(NSString *)key;
+ (void)save:(NSDictionary *)bookmark;
+ (void)remove:(NSString *)key;
@end

@interface MGSettingsViewController : UITableViewController
@end
