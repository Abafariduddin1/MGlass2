#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "MangaViewController.h"
#import "MGGlass.h"
#import "MGSettings.h"
#include <math.h>

// An owned tab bar routes each item to its original action. Spotify's tab views,
// transforms, controller order and coordinate-based hit tests stay untouched.
@interface MGTabDockView : UIView
@end
@implementation MGTabDockView
@end
@interface MGReplacementTabBar : UITabBar
@end
@implementation MGReplacementTabBar
@end
@interface MGDockEntry : NSObject
@property (nonatomic, weak) UIControl *control;
@property (nonatomic, weak) UITabBarController *controller;
@property (nonatomic, weak) UITabBarItem *originalItem;
@property (nonatomic) NSUInteger originalIndex;
@property (nonatomic, copy) NSString *title, *role;
@property (nonatomic, strong) UIImage *image, *selectedImage;
@end
@implementation MGDockEntry
@end
static char MGDockCoordinatorKey;
static BOOL MGSpotifyWindow(UIWindow *window) {
    if (!window.rootViewController) return NO;
    NSMutableArray *queue=[NSMutableArray arrayWithObject:window.rootViewController];
    for (NSUInteger i=0; i<queue.count && i<32; i++) {
        UIViewController *controller=queue[i]; NSString *name=NSStringFromClass(controller.class);
        NSBundle *bundle=[NSBundle bundleForClass:controller.class];
        if ([name hasPrefix:@"SPT"] || [bundle.bundleIdentifier.lowercaseString containsString:@"spotify"] || bundle==NSBundle.mainBundle) return YES;
        if (queue.count<32) [queue addObjectsFromArray:controller.childViewControllers];
    }
    return NO;
}
@interface MGDockCoordinator : NSObject <UITabBarDelegate>
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIView *dock;
@property (nonatomic, strong) MGTabDockView *cover;
@property (nonatomic, strong) MGReplacementTabBar *bar;
@property (nonatomic, copy) NSArray<MGDockEntry *> *entries;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
@property (nonatomic) BOOL queued, refreshing, appearanceDirty;
@property (nonatomic) CGPoint floatingCenter;
@property (nonatomic, weak) UIControl *lastActivated;
- (void)refresh;
- (void)schedule;
@end
static NSString *MGDockLabel(UIView *view) {
    NSMutableArray *words=[NSMutableArray array];
    if (view.accessibilityLabel.length) [words addObject:view.accessibilityLabel];
    if (view.accessibilityIdentifier.length) [words addObject:view.accessibilityIdentifier];
    NSMutableArray *queue=[NSMutableArray arrayWithObject:view];
    for (NSUInteger i=0; i<queue.count && i<24; i++) {
        UIView *child=queue[i];
        if ([child isKindOfClass:[UILabel class]] && ((UILabel *)child).text.length) [words addObject:((UILabel *)child).text];
        if ([child isKindOfClass:[UIButton class]] && ((UIButton *)child).currentTitle.length) [words addObject:((UIButton *)child).currentTitle];
        if (queue.count<24) [queue addObjectsFromArray:child.subviews];
    }
    return [words componentsJoinedByString:@" "].lowercaseString;
}
static NSString *MGDockRole(NSString *label) {
    if ([label containsString:@"create"]) return @"create";
    if ([label containsString:@"library"]) return @"library";
    if ([label containsString:@"search"]) return @"search";
    if ([label containsString:@"home"]) return @"home";
    return nil;
}
static NSString *MGDockTitle(NSString *role) { return @{@"home":@"Home",@"search":@"Search",@"library":@"Library",@"create":@"Create"}[role]; }
static NSString *MGDockSymbol(NSString *role, BOOL selected) {
    if ([role isEqualToString:@"home"]) return selected ? @"house.fill" : @"house";
    if ([role isEqualToString:@"library"]) return selected ? @"books.vertical.fill" : @"books.vertical";
    if ([role isEqualToString:@"create"]) return @"plus";
    return @"magnifyingglass";
}
static UIView *MGFindDock(UIWindow *window) {
    NSMutableArray<UIView *> *queue=[window.subviews mutableCopy];
    for (NSUInteger i=0; i<queue.count && i<400; i++) {
        UIView *view=queue[i];
        if (view.hidden || view.alpha<.01 || [view isKindOfClass:[MGTabDockView class]]) continue;
        NSString *name=NSStringFromClass(view.class).lowercaseString;
        CGRect rect=[view convertRect:view.bounds toView:window];
        BOOL candidate=[view isKindOfClass:[UITabBar class]] || [name containsString:@"tabbar"] || [name containsString:@"bottomnavigation"];
        if (candidate && ![view isKindOfClass:[MGReplacementTabBar class]] && rect.size.width>window.bounds.size.width*.6 && rect.size.height>=32 && rect.size.height<=160 && CGRectGetMinY(rect)>=window.bounds.size.height*.65 && CGRectGetMinY(rect)<window.bounds.size.height) return view;
        if (![view isKindOfClass:[UIVisualEffectView class]] && ![view isKindOfClass:[UIImageView class]] && queue.count<500) [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}
static UITabBarController *MGTabController(UIViewController *root, UITabBar *bar) {
    if (!root) return nil;
    NSMutableArray *queue=[NSMutableArray arrayWithObject:root];
    for (NSUInteger i=0; i<queue.count && i<80; i++) {
        UIViewController *controller=queue[i];
        if (controller.isViewLoaded && [controller isKindOfClass:[UITabBarController class]] && ((UITabBarController *)controller).tabBar==bar) return (id)controller;
        if (queue.count<80) [queue addObjectsFromArray:controller.childViewControllers];
    }
    return nil;
}
static NSArray<MGDockEntry *> *MGDockEntries(UIView *dock, UIWindow *window) {
    NSMutableArray *result=[NSMutableArray array];
    if ([dock isKindOfClass:[UITabBar class]]) {
        UITabBar *native=(id)dock; UITabBarController *controller=MGTabController(window.rootViewController,native);
        if (controller && native.items.count==controller.viewControllers.count && native.items.count<=5) {
            for (NSUInteger i=0; i<native.items.count; i++) {
                UITabBarItem *item=native.items[i]; NSString *role=MGDockRole([NSString stringWithFormat:@"%@ %@ %@",item.title ?: @"",item.accessibilityLabel ?: @"",item.accessibilityIdentifier ?: @""].lowercaseString);
                if (!role) return @[];
                MGDockEntry *entry=[MGDockEntry new]; entry.controller=controller; entry.originalItem=item; entry.originalIndex=i; entry.role=role; entry.title=item.title.length ? item.title : MGDockTitle(role);
                entry.image=item.image ?: [UIImage systemImageNamed:MGDockSymbol(role,NO)]; entry.selectedImage=item.selectedImage ?: [UIImage systemImageNamed:MGDockSymbol(role,YES)]; [result addObject:entry];
            }
            return result;
        }
    }
    NSMutableArray<UIView *> *queue=[dock.subviews mutableCopy];
    for (NSUInteger i=0; i<queue.count && i<160; i++) {
        UIView *view=queue[i]; if (view.hidden || view.alpha<.01) continue;
        if ([view isKindOfClass:[UIControl class]]) {
            UIControl *control=(id)view;
            NSString *label=MGDockLabel(view);
            if (!MGDockRole(label) && view.superview.bounds.size.width<dock.bounds.size.width*.45) label=MGDockLabel(view.superview);
            NSString *role=MGDockRole(label);
            UIControlEvents events=control.allControlEvents;
            if (role && control.allTargets.count && (events & (UIControlEventTouchUpInside|UIControlEventPrimaryActionTriggered))) {
                CGRect rect=[view convertRect:view.bounds toView:window];
                if (rect.size.width>=24 && rect.size.height>=24 && CGRectGetMidY(rect)>window.bounds.size.height*.75) {
                    MGDockEntry *entry=[MGDockEntry new]; entry.control=control; entry.role=role; entry.title=MGDockTitle(role); entry.image=[UIImage systemImageNamed:MGDockSymbol(role,NO)]; entry.selectedImage=[UIImage systemImageNamed:MGDockSymbol(role,YES)]; [result addObject:entry]; continue;
                }
            }
        }
        if (![view isKindOfClass:[UIImageView class]] && ![view isKindOfClass:[UIVisualEffectView class]] && queue.count<160) [queue addObjectsFromArray:view.subviews];
    }
    [result sortUsingComparator:^NSComparisonResult(MGDockEntry *a, MGDockEntry *b) {
        CGFloat x=[a.control convertRect:a.control.bounds toView:window].origin.x, y=[b.control convertRect:b.control.bounds toView:window].origin.x;
        return x<y ? NSOrderedAscending : x>y ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableSet *roles=[NSMutableSet set]; CGFloat firstY=0;
    for (MGDockEntry *entry in result) {
        if ([roles containsObject:entry.role]) return @[];
        [roles addObject:entry.role]; CGFloat y=CGRectGetMidY([entry.control convertRect:entry.control.bounds toView:window]);
        if (firstY && fabs(y-firstY)>20) return @[]; firstY=y;
    }
    return result;
}
@implementation MGDockCoordinator
- (instancetype)init {
    if ((self=[super init])) {
        self.appearanceDirty=YES;
        for (NSString *name in @[MGSettingsDidChangeNotification,UIAccessibilityReduceTransparencyStatusDidChangeNotification,UIDeviceOrientationDidChangeNotification,UIApplicationDidBecomeActiveNotification,UIApplicationWillResignActiveNotification]) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:) name:name object:nil];
    } return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)changed:(NSNotification *)notification { if (MGIsAppearancePreference(notification.userInfo[@"key"])) self.appearanceDirty=YES; [self schedule]; }
- (void)schedule {
    if (!NSThread.isMainThread) { __weak typeof(self) weakSelf=self; dispatch_async(dispatch_get_main_queue(),^{ [weakSelf schedule]; }); return; }
    if (self.queued || self.refreshing) return; self.queued=YES; __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{ typeof(self) owner=weakSelf; if (!owner) return; owner.queued=NO; [owner refresh]; });
}
- (void)refresh {
    if (self.refreshing || !NSThread.isMainThread) return;
    self.refreshing=YES; [self updateDock]; self.refreshing=NO;
}
- (BOOL)matchesEntries:(NSArray<MGDockEntry *> *)entries {
    if (entries.count!=self.entries.count) return NO;
    for (NSUInteger i=0; i<entries.count; i++) {
        MGDockEntry *a=entries[i], *b=self.entries[i];
        if (a.control!=b.control || a.controller!=b.controller || a.originalItem!=b.originalItem || a.originalIndex!=b.originalIndex || ![a.title isEqualToString:b.title] || ![a.role isEqualToString:b.role]) return NO;
    }
    return YES;
}
- (BOOL)placeInDock:(UIView *)dock {
    NSArray<MGDockEntry *> *entries=MGDockEntries(dock,self.window);
    if (entries.count<2 || entries.count>5) return NO;
    NSUInteger create=NSNotFound;
    for (NSUInteger i=0; i<entries.count; i++) if ([entries[i].role isEqualToString:@"create"]) create=i;
    if (create==NSNotFound || self.window.bounds.size.width/(entries.count+1)<52) return NO;
    if (!self.cover) {
        self.cover=[MGTabDockView new]; self.bar=[MGReplacementTabBar new]; self.bar.delegate=self;
        [self.cover addSubview:self.bar]; [self.window addSubview:self.cover];
    }
    if (![self matchesEntries:entries]) {
        self.entries=entries; NSMutableArray *items=[NSMutableArray array];
        for (NSUInteger i=0; i<entries.count; i++) {
            MGDockEntry *entry=entries[i]; UITabBarItem *item=[[UITabBarItem alloc] initWithTitle:entry.title image:entry.image selectedImage:entry.selectedImage]; item.tag=(NSInteger)i; [items addObject:item];
            if (i==create) { UITabBarItem *manga=[[UITabBarItem alloc] initWithTitle:@"Manga" image:[UIImage systemImageNamed:@"book.closed"] tag:-1]; manga.accessibilityHint=@"Open books, video, audio and bookmarks."; [items addObject:manga]; }
        }
        [self.bar setItems:items animated:NO]; self.appearanceDirty=YES;
    }
    CGRect rect=[dock convertRect:dock.bounds toView:self.window]; CGFloat bottom=self.window.safeAreaInsets.bottom;
    CGFloat top=MAX(CGRectGetMinY(rect),self.window.bounds.size.height-bottom-49);
    CGRect frame=CGRectMake(rect.origin.x,top,rect.size.width,self.window.bounds.size.height-top);
    if (!CGRectEqualToRect(self.cover.frame,frame)) { self.cover.frame=frame; self.bar.frame=self.cover.bounds; }
    if (self.appearanceDirty) { self.cover.backgroundColor=MGBackgroundColor(); MGStyleBar(self.bar); self.appearanceDirty=NO; }
    self.cover.hidden=NO; self.button.hidden=YES; [self syncSelection]; [self.window bringSubviewToFront:self.cover]; return YES;
}
- (void)syncSelection {
    NSInteger selected=-1;
    for (NSUInteger i=0; i<self.entries.count; i++) {
        MGDockEntry *entry=self.entries[i];
        if ((entry.controller && entry.controller.selectedIndex==entry.originalIndex) || entry.control.selected || (entry.control.accessibilityTraits & UIAccessibilityTraitSelected)) { selected=(NSInteger)i; break; }
        if (entry.control && entry.control==self.lastActivated) selected=(NSInteger)i;
    }
    if (selected<0) selected=0;
    for (UITabBarItem *item in self.bar.items) if (item.tag==selected && self.bar.selectedItem!=item) { self.bar.selectedItem=item; break; }
}
- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    (void)tabBar;
    if (item.tag==-1) { [self syncSelection]; MGPresentLibrary(self.window); self.cover.hidden=YES; return; }
    if (item.tag<0 || (NSUInteger)item.tag>=self.entries.count) return;
    MGDockEntry *entry=self.entries[(NSUInteger)item.tag];
    if (entry.controller) {
        UITabBarController *controller=entry.controller;
        if (entry.originalIndex>=controller.viewControllers.count || entry.originalIndex>=controller.tabBar.items.count || controller.tabBar.items[entry.originalIndex]!=entry.originalItem) { [self schedule]; return; }
        UIViewController *target=controller.viewControllers[entry.originalIndex]; id<UITabBarControllerDelegate> delegate=controller.delegate;
        if ([delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)] && ![delegate tabBarController:controller shouldSelectViewController:target]) { [self syncSelection]; return; }
        controller.selectedViewController=target;
        if ([delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)]) [delegate tabBarController:controller didSelectViewController:target];
    } else {
        UIControl *source=entry.control;
        if (!source.window || !source.enabled) { [self schedule]; return; }
        self.lastActivated=source;
        UIControlEvents event=(source.allControlEvents & UIControlEventTouchUpInside) ? UIControlEventTouchUpInside : UIControlEventPrimaryActionTriggered;
        [source sendActionsForControlEvents:event];
    }
    [self syncSelection]; [self schedule];
}
- (void)updateDock {
    UIWindow *window=self.window;
    if (!window || !window.isKeyWindow || window.windowLevel!=UIWindowLevelNormal || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) { self.cover.hidden=YES; self.button.hidden=YES; return; }
    if (window.rootViewController.presentedViewController || !MGSpotifyWindow(window)) { self.cover.hidden=YES; self.button.hidden=YES; return; }
    UIView *dock=MGFindDock(window);
    if (dock!=self.dock) { self.dock=dock; self.entries=nil; self.lastActivated=nil; }
    if (dock && [[[MGSettings shared] text:@"dockPosition"] isEqualToString:@"besideCreate"] && [self placeInDock:dock]) return;
    self.cover.hidden=YES;
    if (![[MGSettings shared] flag:@"floatingFallback"] && ![[[MGSettings shared] text:@"dockPosition"] isEqualToString:@"floating"]) { self.button.hidden=YES; return; }
    if (!self.button) {
        self.button=[UIButton buttonWithType:UIButtonTypeSystem]; [self.button setTitle:@"Manga" forState:UIControlStateNormal]; [self.button setImage:[UIImage systemImageNamed:@"book.closed"] forState:UIControlStateNormal];
        self.button.accessibilityLabel=@"Manga"; [self.button addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        self.pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]; [self.button addGestureRecognizer:self.pan]; [window addSubview:self.button];
    }
    MGStyleButton(self.button); self.button.hidden=NO;
    CGRect safe=window.safeAreaLayoutGuide.layoutFrame;
    if (CGPointEqualToPoint(self.floatingCenter,CGPointZero)) self.floatingCenter=CGPointMake(CGRectGetMaxX(safe)-66,CGRectGetMaxY(safe)-148);
    self.floatingCenter=CGPointMake(MIN(CGRectGetMaxX(safe)-56,MAX(CGRectGetMinX(safe)+56,self.floatingCenter.x)),MIN(CGRectGetMaxY(safe)-22,MAX(CGRectGetMinY(safe)+22,self.floatingCenter.y)));
    self.button.frame=CGRectMake(self.floatingCenter.x-52,self.floatingCenter.y-22,104,44); [window bringSubviewToFront:self.button];
}
- (void)open { MGPresentLibrary(self.window); self.button.hidden=YES; self.cover.hidden=YES; }
- (void)drag:(UIPanGestureRecognizer *)gesture { CGPoint delta=[gesture translationInView:self.window]; self.floatingCenter=CGPointMake(self.button.center.x+delta.x,self.button.center.y+delta.y); [gesture setTranslation:CGPointZero inView:self.window]; [self refresh]; }
@end
static void MGRefreshDock(UIWindow *window) {
    if (!NSThread.isMainThread || !window || window.windowLevel!=UIWindowLevelNormal || !window.isKeyWindow || !MGSpotifyWindow(window)) return;
    MGDockCoordinator *coordinator=objc_getAssociatedObject(window,&MGDockCoordinatorKey);
    if (!coordinator) { coordinator=[MGDockCoordinator new]; coordinator.window=window; objc_setAssociatedObject(window,&MGDockCoordinatorKey,coordinator,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    [coordinator schedule];
}
%group MangaGlassHooks
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    MGStyleHostController(self);
    MGRefreshDock(self.view.window);
}
%end
%hook UINavigationBar
- (void)didMoveToWindow {
    %orig;
    if (self.window) MGStyleBar(self);
}
%end
%hook UITabBar
- (void)layoutSubviews {
    %orig;
    if (![self isKindOfClass:[MGReplacementTabBar class]]) MGRefreshDock(self.window);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window && ![self isKindOfClass:[MGReplacementTabBar class]]) { MGStyleBar(self); MGRefreshDock(self.window); }
}
%end
%hook UIToolbar
- (void)didMoveToWindow {
    %orig;
    if (self.window) MGStyleBar(self);
}
%end
%hook UIButton
- (void)didMoveToWindow {
    %orig;
    MGStyleHostControl(self);
}
%end
%hook UILabel
- (void)didMoveToWindow {
    %orig;
    MGStyleHostControl(self);
}
%end
%hook UITableView
- (void)didMoveToWindow {
    %orig;
    MGStyleHostListSurface(self);
}
%end
%hook UICollectionView
- (void)didMoveToWindow {
    %orig;
    MGStyleHostListSurface(self);
}
%end
%hook UITableViewCell
- (void)didMoveToWindow {
    %orig;
    MGStyleHostListSurface(self);
}
%end
%hook UICollectionViewCell
- (void)didMoveToWindow {
    %orig;
    MGStyleHostListSurface(self);
}
%end
%hook UIWindow
- (void)resignKeyWindow {
    %orig;
    [objc_getAssociatedObject(self,&MGDockCoordinatorKey) schedule];
}
- (void)becomeKeyWindow {
    %orig;
    MGRefreshDock(self);
}
%end
%end
%ctor {
    @autoreleasepool {
        NSString *bundle=[NSBundle mainBundle].bundleIdentifier.lowercaseString;
        if ([bundle containsString:@"spotify"] || NSClassFromString(@"SPTNowPlayingViewController")) {
            %init(MangaGlassHooks);
        }
    }
}
