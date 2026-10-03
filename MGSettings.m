#import "MGSettings.h"
#import "MGGlass.h"

NSString * const MGSettingsDidChangeNotification = @"com.custom.mangaglass.settingsChanged";
NSString * const MGBookmarksDidChangeNotification = @"com.custom.mangaglass.bookmarksChanged";

static NSUserDefaults *MGDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.custom.mangaglass"];
        [defaults registerDefaults:@{@"direction": @"rtl", @"pairPages": @YES, @"splitSpreads": @YES,
          @"singleCover": @YES, @"cropMargins": @NO, @"grayscale": @NO, @"sharpen": @NO,
          @"lowMemory": @NO, @"amoled": @YES, @"askBookmark": @YES, @"glass": @YES,
          @"floatingFallback": @YES, @"bookmarks": @[]}];
    });
    return defaults;
}

@implementation MGSettings
+ (instancetype)shared {
    static MGSettings *settings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ settings = [MGSettings new]; });
    return settings;
}
- (BOOL)flag:(NSString *)key { return [MGDefaults() boolForKey:key]; }
- (NSString *)text:(NSString *)key { return [MGDefaults() stringForKey:key]; }
- (MGDirection)direction {
    NSString *value = [self text:@"direction"];
    return [value isEqualToString:@"vertical"] ? MGVertical : [value isEqualToString:@"ltr"] ? MGLeftToRight : MGRightToLeft;
}
- (void)setValue:(id)value forPreference:(NSString *)key {
    [MGDefaults() setObject:value forKey:key];
    [[NSNotificationCenter defaultCenter] postNotificationName:MGSettingsDidChangeNotification object:nil userInfo:@{@"key":key}];
}
@end

@implementation MGBookmarkStore
+ (NSArray<NSDictionary *> *)all {
    id value = [MGDefaults() arrayForKey:@"bookmarks"];
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}
+ (NSDictionary *)bookmarkForKey:(NSString *)key {
    for (NSDictionary *bookmark in [self all]) if ([bookmark[@"key"] isEqualToString:key]) return bookmark;
    return nil;
}
+ (void)save:(NSDictionary *)bookmark {
    if (![bookmark[@"key"] isKindOfClass:[NSString class]]) return;
    NSMutableArray *items = [[self all] mutableCopy];
    NSIndexSet *existing = [items indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        (void)idx; (void)stop; return [item[@"key"] isEqualToString:bookmark[@"key"]];
    }];
    [items removeObjectsAtIndexes:existing];
    [items insertObject:bookmark atIndex:0];
    [MGDefaults() setObject:items forKey:@"bookmarks"];
    [[NSNotificationCenter defaultCenter] postNotificationName:MGBookmarksDidChangeNotification object:nil];
}
+ (void)remove:(NSString *)key {
    NSMutableArray *items = [[self all] mutableCopy];
    NSIndexSet *existing = [items indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        (void)idx; (void)stop; return [item[@"key"] isEqualToString:key];
    }];
    [items removeObjectsAtIndexes:existing];
    [MGDefaults() setObject:items forKey:@"bookmarks"];
    [[NSNotificationCenter defaultCenter] postNotificationName:MGBookmarksDidChangeNotification object:nil];
}
@end

@implementation MGSettingsViewController {
    NSArray<NSArray<NSDictionary *> *> *_sections;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MangaGlass Settings";
    self.view.backgroundColor = [UIColor blackColor];
    _sections = @[
      @[@{@"key":@"direction", @"title":@"Reading direction"},
        @{@"key":@"pairPages", @"title":@"Two pages in landscape"},
        @{@"key":@"splitSpreads", @"title":@"Split wide scans in portrait"},
        @{@"key":@"singleCover", @"title":@"Keep the first page single"}],
      @[@{@"key":@"cropMargins", @"title":@"Crop white margins"},
        @{@"key":@"grayscale", @"title":@"Grayscale"},
        @{@"key":@"sharpen", @"title":@"Sharpen text"},
        @{@"key":@"lowMemory", @"title":@"Lower resolution / less memory"},
        @{@"key":@"amoled", @"title":@"Pure black reader background"}],
      @[@{@"key":@"askBookmark", @"title":@"Ask to bookmark when leaving"},
        @{@"key":@"glass", @"title":@"Glass across Spotify"},
        @{@"key":@"floatingFallback", @"title":@"Floating opener if dock unavailable"}]];
    MGInstallGlass(self.view);
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:.12];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return _sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return _sections[section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return @[@"Reading", @"Image and display", @"Bookmarks and app"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return @[@"Right to left is the manga default. Vertical mode shows a continuous strip.",
      @"Filters are optional. Lower resolution halves the standard page limit. Long strips use a separate pixel budget to keep text readable. Cropping keeps a small safety border.",
      @"Bookmarks are saved only when you choose to save. Settings also apply to an open reader. Glass respects Reduce Transparency."][section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSDictionary *row = _sections[indexPath.section][indexPath.row];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.numberOfLines = 2;
    cell.backgroundColor = [UIColor colorWithWhite:.13 alpha:.65];
    NSString *key = row[@"key"];
    if ([key isEqualToString:@"direction"]) {
        cell.detailTextLabel.text = @{@"rtl":@"Right to left", @"ltr":@"Left to right", @"vertical":@"Vertical"}[[[MGSettings shared] text:key]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        UISwitch *toggle = [UISwitch new];
        toggle.on = [[MGSettings shared] flag:key];
        toggle.accessibilityIdentifier = key;
        [toggle addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    (void)tableView; return cell;
}
- (void)changed:(UISwitch *)sender {
    [[MGSettings shared] setValue:@(sender.on) forPreference:sender.accessibilityIdentifier];
    MGInstallGlass(self.view);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (![[_sections[indexPath.section][indexPath.row] objectForKey:@"key"] isEqualToString:@"direction"]) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Reading direction" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *keys = @[@"rtl", @"ltr", @"vertical"], *names = @[@"Right to left", @"Left to right", @"Vertical strip"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *key = keys[i];
        [menu addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action; [[MGSettings shared] setValue:key forPreference:@"direction"];
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    menu.popoverPresentationController.sourceRect = [tableView cellForRowAtIndexPath:indexPath].bounds;
    [self presentViewController:menu animated:YES completion:nil];
}
@end
