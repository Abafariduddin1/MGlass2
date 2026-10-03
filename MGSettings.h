#pragma once
#import <UIKit/UIKit.h>
#import "MGReaderGeometry.h"

extern NSString * const MGSettingsDidChangeNotification;
extern NSString * const MGBookmarksDidChangeNotification;

@interface MGSettings : NSObject
+ (instancetype)shared;
- (BOOL)flag:(NSString *)key;
- (NSString *)text:(NSString *)key;
- (CGFloat)number:(NSString *)key;
- (void)setValue:(id)value forPreference:(NSString *)key;
- (MGDirection)direction;
- (NSDictionary *)appearance;
- (BOOL)applyAppearance:(NSDictionary *)appearance;
@end

UIColor *MGAccentColor(void);
UIColor *MGBackgroundColor(void);
UIColor *MGTextColor(void);
UIColor *MGSurfaceColor(void);
NSString *MGHexForColor(UIColor *color);
BOOL MGIsAppearancePreference(NSString *key);

@interface MGBookmarkStore : NSObject
+ (NSArray<NSDictionary *> *)all;
+ (NSDictionary *)bookmarkForKey:(NSString *)key;
+ (void)save:(NSDictionary *)bookmark;
+ (void)remove:(NSString *)key;
@end

@interface MGSettingsViewController : UITableViewController
@end
