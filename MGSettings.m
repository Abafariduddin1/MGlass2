#import "MGSettings.h"
#import "MGGlass.h"

NSString * const MGSettingsDidChangeNotification = @"com.custom.mangaglass.settingsChanged";
NSString * const MGBookmarksDidChangeNotification = @"com.custom.mangaglass.bookmarksChanged";
static NSUInteger MGPaletteRevision = 1;

static NSUserDefaults *MGDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.custom.mangaglass"];
        [defaults registerDefaults:@{@"direction": @"rtl", @"pairPages": @YES, @"splitSpreads": @YES,
          @"singleCover": @YES, @"cropMargins": @NO, @"grayscale": @NO, @"sharpen": @NO,
          @"lowMemory": @NO, @"amoled": @YES, @"askBookmark": @YES, @"glass": @YES,
          @"floatingFallback": @YES, @"bookmarks": @[], @"theme":@"spotify", @"accentHex":@"1ED760",
          @"backgroundHex":@"080A0C", @"textHex":@"FFFFFF", @"glassStyle":@"regular", @"glassButtons":@YES,
          @"hostText":@YES, @"roundness":@"20", @"dockPosition":@"besideCreate", @"epubFontSize":@"18", @"epubFont":@"serif"}];
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
- (CGFloat)number:(NSString *)key {
    CGFloat value = [MGDefaults() doubleForKey:key];
    if ([key isEqualToString:@"epubFontSize"]) return MIN(32, MAX(14, value));
    if ([key isEqualToString:@"roundness"]) return MIN(28, MAX(8, value));
    return value;
}
- (MGDirection)direction {
    NSString *value = [self text:@"direction"];
    return [value isEqualToString:@"vertical"] ? MGVertical : [value isEqualToString:@"ltr"] ? MGLeftToRight : MGRightToLeft;
}
- (void)setValue:(id)value forPreference:(NSString *)key {
    [MGDefaults() setObject:value forKey:key];
    if (MGIsAppearancePreference(key)) ++MGPaletteRevision;
    [[NSNotificationCenter defaultCenter] postNotificationName:MGSettingsDidChangeNotification object:nil userInfo:@{@"key":key}];
}
- (NSDictionary *)appearance {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"theme", @"accentHex", @"backgroundHex", @"textHex", @"glass", @"glassStyle", @"glassButtons", @"hostText", @"roundness"]) result[key] = [MGDefaults() objectForKey:key];
    return result;
}
- (BOOL)applyAppearance:(NSDictionary *)appearance {
    if (![appearance isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *choices = @{@"theme":@[@"spotify", @"midnight", @"ocean", @"rose", @"pearl", @"custom"], @"glassStyle":@[@"regular", @"clear"], @"roundness":@[@"8", @"14", @"20", @"28"]};
    for (NSString *key in appearance) {
        id value = appearance[key];
        if (![self.appearance.allKeys containsObject:key]) return NO;
        if (choices[key] && ![choices[key] containsObject:value]) return NO;
        if ([@[@"accentHex", @"backgroundHex", @"textHex"] containsObject:key]) {
            if (![value isKindOfClass:[NSString class]] || [value length] != 6 || [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location != NSNotFound) return NO;
        } else if (!choices[key] && ![value isKindOfClass:[NSNumber class]]) return NO;
    }
    for (NSString *key in appearance) [MGDefaults() setObject:appearance[key] forKey:key];
    ++MGPaletteRevision;
    [[NSNotificationCenter defaultCenter] postNotificationName:MGSettingsDidChangeNotification object:nil userInfo:@{@"key":@"theme"}];
    return YES;
}
@end

static NSDictionary *MGChoice(NSString *key, NSString *title, NSArray *values, NSArray *labels) { return @{@"key":key, @"title":title, @"kind":@"choice", @"values":values, @"labels":labels}; }
@implementation MGSettingsViewController {
    NSArray<NSArray<NSDictionary *> *> *_sections;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"MangaGlass Settings";
    _sections = @[
      @[MGChoice(@"theme", @"Theme", @[@"spotify", @"midnight", @"ocean", @"rose", @"pearl", @"custom"], @[@"Spotify", @"Midnight", @"Ocean", @"Rose", @"Pearl", @"Custom"]),
        @{@"key":@"accentHex", @"title":@"Custom accent", @"kind":@"color"}, @{@"key":@"backgroundHex", @"title":@"Custom background", @"kind":@"color"}, @{@"key":@"textHex", @"title":@"Custom text", @"kind":@"color"},
        @{@"key":@"glass", @"title":@"Glass across Spotify and Manga"},
        MGChoice(@"glassStyle", @"Glass material", @[@"regular", @"clear"], @[@"Regular", @"Clear"]),
        @{@"key":@"glassButtons", @"title":@"Glass buttons"}, @{@"key":@"hostText", @"title":@"Match Spotify text to theme"},
        MGChoice(@"roundness", @"Corner shape", @[@"8", @"14", @"20", @"28"], @[@"Soft", @"Rounded", @"Pill", @"Very round"]),
        @{@"key":@"copyTheme", @"title":@"Copy theme", @"kind":@"action"}, @{@"key":@"importTheme", @"title":@"Paste theme", @"kind":@"action"}],
      @[MGChoice(@"direction", @"Reading direction", @[@"rtl", @"ltr", @"vertical"], @[@"Right to left", @"Left to right", @"Vertical strip"]),
        @{@"key":@"pairPages", @"title":@"Two pages in landscape"}, @{@"key":@"splitSpreads", @"title":@"Split wide scans in portrait"}, @{@"key":@"singleCover", @"title":@"Keep the first page single"},
        MGChoice(@"epubFontSize", @"EPUB text size", @[@"14", @"16", @"18", @"20", @"22", @"26", @"30", @"32"], @[@"14", @"16", @"18", @"20", @"22", @"26", @"30", @"32"]),
        MGChoice(@"epubFont", @"EPUB font", @[@"serif", @"sans"], @[@"Serif", @"System"])],
      @[@{@"key":@"cropMargins", @"title":@"Crop white margins"}, @{@"key":@"grayscale", @"title":@"Grayscale manga"}, @{@"key":@"sharpen", @"title":@"Sharpen manga text"}, @{@"key":@"lowMemory", @"title":@"Lower reader memory"}, @{@"key":@"amoled", @"title":@"Pure black manga background"}],
      @[@{@"key":@"askBookmark", @"title":@"Ask to bookmark when leaving"},
        MGChoice(@"dockPosition", @"Manga entry", @[@"besideCreate", @"floating"], @[@"Beside Create", @"Floating button"]),
        @{@"key":@"floatingFallback", @"title":@"Show fallback if dock unavailable"}]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:) name:MGSettingsDidChangeNotification object:nil];
    [self refresh:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.navigationController setNavigationBarHidden:NO animated:animated]; [self.navigationController setToolbarHidden:YES animated:animated]; self.navigationController.interactivePopGestureRecognizer.enabled = YES; }
- (void)refresh:(NSNotification *)notification { (void)notification; self.view.backgroundColor = MGBackgroundColor(); MGInstallGlass(self.view); self.tableView.separatorColor = [MGTextColor() colorWithAlphaComponent:.12]; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return (NSInteger)_sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return (NSInteger)_sections[(NSUInteger)section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return @[@"Spotify and Manga appearance", @"Reading", @"Manga image and memory", @"Bookmarks and dock"][(NSUInteger)section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; return @[@"Custom colors select the Custom theme. Copy and paste themes as JSON. Native Liquid Glass needs iOS 26; earlier versions use a material fallback. Scrolling rows share the screen's material.",
      @"EPUBs use their own chapter order. Font settings apply to reflowable books; fixed layouts keep their design.", @"Normal mode keeps full reader quality. Lower memory is optional. Filters apply to the adaptive manga view.", @"The dock adapter preserves Spotify's existing actions. If its tabs cannot be identified, the fallback appears instead. Bookmarks are saved when you choose."][(NSUInteger)section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView; UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil]; NSDictionary *row = _sections[(NSUInteger)path.section][(NSUInteger)path.row];
    cell.textLabel.text = row[@"title"]; cell.textLabel.textColor = MGTextColor(); cell.textLabel.numberOfLines = 2; cell.backgroundColor = MGSurfaceColor();
    NSString *key = row[@"key"], *kind = row[@"kind"];
    if ([kind isEqualToString:@"choice"]) {
        NSString *value = [[MGSettings shared] text:key]; NSUInteger index = [row[@"values"] indexOfObject:value ?: @""]; cell.detailTextLabel.text = index == NSNotFound ? value : row[@"labels"][index]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([kind isEqualToString:@"color"]) { cell.detailTextLabel.text = [@"#" stringByAppendingString:[[MGSettings shared] text:key]]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    else if ([kind isEqualToString:@"action"]) { cell.textLabel.textColor = MGAccentColor(); }
    else { UISwitch *toggle = [UISwitch new]; toggle.on = [[MGSettings shared] flag:key]; toggle.onTintColor = MGAccentColor(); toggle.accessibilityIdentifier = key; [toggle addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone; }
    return cell;
}
- (void)changed:(UISwitch *)sender { [[MGSettings shared] setValue:@(sender.on) forPreference:sender.accessibilityIdentifier]; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; NSDictionary *row = _sections[(NSUInteger)path.section][(NSUInteger)path.row]; NSString *key = row[@"key"], *kind = row[@"kind"];
    if ([kind isEqualToString:@"choice"]) {
        UIAlertController *menu = [UIAlertController alertControllerWithTitle:row[@"title"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *values = row[@"values"], *labels = row[@"labels"];
        for (NSUInteger i = 0; i < values.count; i++) { NSString *value = values[i]; [menu addAction:[UIAlertAction actionWithTitle:labels[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [[MGSettings shared] setValue:value forPreference:key]; }]]; }
        [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; menu.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:path]; menu.popoverPresentationController.sourceRect = [tableView cellForRowAtIndexPath:path].bounds; [self presentViewController:menu animated:YES completion:nil]; return;
    }
    if ([kind isEqualToString:@"color"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:row[@"title"] message:@"Enter a six-digit hex color, such as 1ED760." preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = [[MGSettings shared] text:key]; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action; NSString *value = [[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByReplacingOccurrencesOfString:@"#" withString:@""];
            NSMutableDictionary *colors=[@{@"theme":@"custom", @"accentHex":[MGHexForColor(MGAccentColor()) substringFromIndex:1], @"backgroundHex":[MGHexForColor(MGBackgroundColor()) substringFromIndex:1], @"textHex":[MGHexForColor(MGTextColor()) substringFromIndex:1]} mutableCopy]; colors[key]=value.uppercaseString;
            if (![[MGSettings shared] applyAppearance:colors]) [self invalidTheme];
        }]]; [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:alert animated:YES completion:nil]; return;
    }
    if ([key isEqualToString:@"copyTheme"]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:[[MGSettings shared] appearance] options:NSJSONWritingPrettyPrinted error:nil]; UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Theme copied");
    } else if ([key isEqualToString:@"importTheme"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Paste theme" message:@"Paste a MangaGlass theme JSON." preferredStyle:UIAlertControllerStyleAlert]; [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"{\"theme\":\"ocean\"}"; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; NSData *data = [alert.textFields.firstObject.text dataUsingEncoding:NSUTF8StringEncoding]; id value = data.length <= 4096 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; if (![[MGSettings shared] applyAppearance:value]) [self invalidTheme]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:alert animated:YES completion:nil];
    }
}
- (void)invalidTheme { dispatch_async(dispatch_get_main_queue(), ^{ UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Invalid theme" message:@"Check the color values and use a theme exported by MangaGlass." preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; if (!self.presentedViewController) [self presentViewController:alert animated:YES completion:nil]; }); }
@end

static UIColor *MGColorFromHex(NSString *hex) {
    unsigned int value = 0; [[NSScanner scannerWithString:hex ?: @"FFFFFF"] scanHexInt:&value];
    return [UIColor colorWithRed:((value >> 16) & 255) / 255.0 green:((value >> 8) & 255) / 255.0 blue:(value & 255) / 255.0 alpha:1];
}
static NSString *MGThemeValue(NSString *key) {
    MGSettings *settings = [MGSettings shared]; NSString *theme = [settings text:@"theme"];
    NSDictionary *themes = @{
      @"spotify":@{@"accentHex":@"1ED760", @"backgroundHex":@"080A0C", @"textHex":@"FFFFFF"},
      @"midnight":@{@"accentHex":@"AB9DFF", @"backgroundHex":@"0C0A16", @"textHex":@"F4F1FF"},
      @"ocean":@{@"accentHex":@"63DCEB", @"backgroundHex":@"07151E", @"textHex":@"EFFBFF"},
      @"rose":@{@"accentHex":@"FFA0BC", @"backgroundHex":@"1C0B15", @"textHex":@"FFF2F7"},
      @"pearl":@{@"accentHex":@"126E48", @"backgroundHex":@"EAF0F4", @"textHex":@"15222D"}};
    return [theme isEqualToString:@"custom"] ? [settings text:key] : (themes[theme] ?: themes[@"spotify"])[key];
}
static NSDictionary<NSString *, UIColor *> *MGPalette(void) {
    static NSDictionary *palette; static NSUInteger revision;
    if (!palette || revision != MGPaletteRevision) { palette = @{@"accentHex":MGColorFromHex(MGThemeValue(@"accentHex")), @"backgroundHex":MGColorFromHex(MGThemeValue(@"backgroundHex")), @"textHex":MGColorFromHex(MGThemeValue(@"textHex"))}; revision = MGPaletteRevision; }
    return palette;
}
UIColor *MGAccentColor(void) { return MGPalette()[@"accentHex"]; }
UIColor *MGBackgroundColor(void) { return MGPalette()[@"backgroundHex"]; }
UIColor *MGTextColor(void) { return MGPalette()[@"textHex"]; }
UIColor *MGSurfaceColor(void) { return [MGTextColor() colorWithAlphaComponent:.07]; }
NSString *MGHexForColor(UIColor *color) {
    CGFloat red = 1, green = 1, blue = 1; [color getRed:&red green:&green blue:&blue alpha:NULL];
    return [NSString stringWithFormat:@"#%02X%02X%02X", (unsigned int)(red * 255), (unsigned int)(green * 255), (unsigned int)(blue * 255)];
}
BOOL MGIsAppearancePreference(NSString *key) { return !key || [@[@"theme", @"accentHex", @"backgroundHex", @"textHex", @"glass", @"glassStyle", @"glassButtons", @"hostText", @"roundness"] containsObject:key]; }

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
