#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "MangaViewController.h"
#import "MGGlass.h"
#import "MGSettings.h"
#include <math.h>

static char MGDockCoordinatorKey;
@interface MGDockCoordinator : NSObject
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIView *dock;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
@property (nonatomic, strong) NSMapTable<UIView *, NSValue *> *originalTransforms;
@property (nonatomic) BOOL queued;
@property (nonatomic) CGPoint floatingCenter;
- (void)refresh;
- (void)schedule;
@end
static UIView *MGFindDock(UIWindow *window) {
    NSMutableArray<UIView *> *queue=[window.subviews mutableCopy];
    for (NSUInteger i=0; i<queue.count && i<500; i++) {
        UIView *view=queue[i]; if (view.hidden || view.alpha<.01) continue;
        NSString *name=NSStringFromClass(view.class).lowercaseString; CGRect rect=[view convertRect:view.bounds toView:window];
        BOOL candidate=[view isKindOfClass:[UITabBar class]] || [name containsString:@"tabbar"] || [name containsString:@"bottomnavigation"];
        if (candidate && rect.size.width>window.bounds.size.width*.6 && rect.size.height>=32 && rect.size.height<=180 && CGRectGetMinY(rect)>=window.bounds.size.height*.55 && CGRectGetMinY(rect)<window.bounds.size.height) return view;
        if (![view isKindOfClass:[UIVisualEffectView class]] && ![view isKindOfClass:[UIImageView class]] && queue.count<650) [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}
static NSString *MGDockLabel(UIView *view) {
    NSMutableArray *words=[NSMutableArray array]; if (view.accessibilityLabel.length) [words addObject:view.accessibilityLabel]; if (view.accessibilityIdentifier.length) [words addObject:view.accessibilityIdentifier];
    NSMutableArray *queue=[NSMutableArray arrayWithObject:view];
    for (NSUInteger i=0; i<queue.count && i<20; i++) { UIView *child=queue[i]; if ([child isKindOfClass:[UILabel class]] && ((UILabel *)child).text.length) [words addObject:((UILabel *)child).text]; if ([child isKindOfClass:[UIButton class]] && ((UIButton *)child).currentTitle.length) [words addObject:((UIButton *)child).currentTitle]; if (queue.count<20) [queue addObjectsFromArray:child.subviews]; }
    return [words componentsJoinedByString:@" "].lowercaseString;
}
static NSArray<UIView *> *MGDockItems(UIView *dock, UIWindow *window) {
    NSMutableArray *result=[NSMutableArray array], *queue=[dock.subviews mutableCopy];
    for (NSUInteger i=0; i<queue.count && i<120; i++) {
        UIView *view=queue[i]; if (view.hidden || view.alpha<.01) continue;
        BOOL button=[view isKindOfClass:[UIControl class]] || (view.isAccessibilityElement && (view.accessibilityTraits & UIAccessibilityTraitButton));
        if (button && view.bounds.size.width>=28 && view.bounds.size.height>=28 && MGDockLabel(view).length) { [result addObject:view]; continue; }
        if (![view isKindOfClass:[UIVisualEffectView class]] && ![view isKindOfClass:[UIImageView class]] && queue.count<120) [queue addObjectsFromArray:view.subviews];
    }
    [result sortUsingComparator:^NSComparisonResult(UIView *first, UIView *second) {
        CGFloat a=[first.superview convertPoint:first.center toView:window].x, b=[second.superview convertPoint:second.center toView:window].x;
        return a<b ? NSOrderedAscending : a>b ? NSOrderedDescending : NSOrderedSame;
    }];
    return result;
}
@implementation MGDockCoordinator
- (instancetype)init {
    if ((self=[super init])) {
        self.originalTransforms=[NSMapTable weakToStrongObjectsMapTable];
        for (NSString *name in @[MGSettingsDidChangeNotification,UIAccessibilityReduceTransparencyStatusDidChangeNotification,UIDeviceOrientationDidChangeNotification]) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:) name:name object:nil];
    } return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)changed:(NSNotification *)notification { (void)notification; [self schedule]; }
- (void)schedule {
    if (self.queued) return; self.queued=YES; __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{ typeof(self) owner=weakSelf; if (!owner) return; owner.queued=NO; [owner refresh]; });
}
- (void)restoreTabs {
    for (UIView *view in self.originalTransforms.keyEnumerator.allObjects) { NSValue *value=[self.originalTransforms objectForKey:view]; if (value) view.transform=value.CGAffineTransformValue; }
    [self.originalTransforms removeAllObjects];
}
- (BOOL)placeInDock:(UIView *)dock {
    NSArray<UIView *> *items=MGDockItems(dock,self.window); if (items.count<2 || items.count>6) return NO;
    NSUInteger create=NSNotFound;
    for (NSUInteger i=0; i<items.count; i++) if ([MGDockLabel(items[i]) containsString:@"create"]) { create=i; break; }
    if (create==NSNotFound) return NO;
    CGRect rect=[dock convertRect:dock.bounds toView:self.window], safe=self.window.safeAreaLayoutGuide.layoutFrame;
    CGFloat left=MAX(CGRectGetMinX(rect),CGRectGetMinX(safe))+4, right=MIN(CGRectGetMaxX(rect),CGRectGetMaxX(safe))-4;
    CGFloat slot=(right-left)/(items.count+1); if (slot<52) return NO;
    NSUInteger insertion=create+1;
    for (NSUInteger i=0; i<items.count; i++) {
        UIView *view=items[i]; NSValue *saved=[self.originalTransforms objectForKey:view];
        if (!saved) { saved=[NSValue valueWithCGAffineTransform:view.transform]; [self.originalTransforms setObject:saved forKey:view]; }
        CGAffineTransform original=saved.CGAffineTransformValue;
        CGFloat scale=MIN(1,(slot-6)/MAX(1,view.bounds.size.width)); CGAffineTransform target=CGAffineTransformScale(original,scale,scale);
        NSUInteger index=i<insertion ? i : i+1;
        CGPoint center=[self.window convertPoint:CGPointMake(left+(index+.5)*slot,0) toView:view.superview];
        target.tx=center.x-view.center.x; target.ty=original.ty;
        if (!CGAffineTransformEqualToTransform(view.transform,target)) view.transform=target;
    }
    UIView *createView=items[create]; CGPoint createCenter=[createView.superview convertPoint:createView.center toView:self.window];
    CGFloat height=MIN(58,MAX(44,createView.bounds.size.height));
    self.button.frame=CGRectMake(left+insertion*slot+3,createCenter.y-height/2,slot-6,height);
    if (@available(iOS 15.0,*)) {
        UIButtonConfiguration *configuration=[self.button.configuration copy] ?: [UIButtonConfiguration plainButtonConfiguration];
        configuration.title=@"Manga"; configuration.image=[UIImage systemImageNamed:@"book.closed"]; configuration.imagePlacement=NSDirectionalRectEdgeTop; configuration.imagePadding=3; configuration.contentInsets=NSDirectionalEdgeInsetsMake(3,3,3,3);
        configuration.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *attributes) { NSMutableDictionary *result=[attributes mutableCopy]; result[NSFontAttributeName]=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; return result; }; self.button.configuration=configuration;
    } else { [self.button setTitle:@"Manga" forState:UIControlStateNormal]; [self.button setImage:nil forState:UIControlStateNormal]; self.button.titleLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightMedium]; }
    self.pan.enabled=NO; return YES;
}
- (void)refresh {
    UIWindow *window=self.window; if (!window || !window.isKeyWindow || window.windowLevel!=UIWindowLevelNormal) return;
    UIViewController *top=window.rootViewController;
    while (top) { if ([top isKindOfClass:[MGNavigationController class]]) { self.button.hidden=YES; return; } top=top.presentedViewController; }
    UIView *dock=MGFindDock(window);
    if (self.dock!=dock) { [self restoreTabs]; self.dock=dock; }
    if (!self.button) {
        self.button=[UIButton buttonWithType:UIButtonTypeSystem]; [self.button setTitle:@"Manga" forState:UIControlStateNormal]; [self.button setImage:[UIImage systemImageNamed:@"book.closed"] forState:UIControlStateNormal];
        self.button.accessibilityLabel=@"Manga"; self.button.accessibilityHint=@"Open books, video, audio, and bookmarks."; [self.button addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        self.pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]; [self.button addGestureRecognizer:self.pan]; [window addSubview:self.button];
    }
    MGStyleButton(self.button); self.button.hidden=NO;
    if (dock && [[[MGSettings shared] text:@"dockPosition"] isEqualToString:@"besideCreate"] && [self placeInDock:dock]) {
        if (![dock isKindOfClass:[UITabBar class]]) MGInstallGlass(dock);
        [window bringSubviewToFront:self.button]; return;
    }
    [self restoreTabs];
    if (![[MGSettings shared] flag:@"floatingFallback"] && ![[[MGSettings shared] text:@"dockPosition"] isEqualToString:@"floating"]) { self.button.hidden=YES; return; }
    CGRect safe=window.safeAreaLayoutGuide.layoutFrame;
    if (CGPointEqualToPoint(self.floatingCenter,CGPointZero)) self.floatingCenter=CGPointMake(CGRectGetMaxX(safe)-66,CGRectGetMaxY(safe)-92);
    self.floatingCenter=CGPointMake(MIN(CGRectGetMaxX(safe)-56,MAX(CGRectGetMinX(safe)+56,self.floatingCenter.x)),MIN(CGRectGetMaxY(safe)-22,MAX(CGRectGetMinY(safe)+22,self.floatingCenter.y)));
    self.button.frame=CGRectMake(self.floatingCenter.x-52,self.floatingCenter.y-22,104,44); self.pan.enabled=YES;
    if (@available(iOS 15.0,*)) { UIButtonConfiguration *configuration=[self.button.configuration copy] ?: [UIButtonConfiguration plainButtonConfiguration]; configuration.imagePlacement=NSDirectionalRectEdgeLeading; configuration.contentInsets=NSDirectionalEdgeInsetsMake(7,10,7,10); configuration.titleTextAttributesTransformer=nil; self.button.configuration=configuration; }
    [window bringSubviewToFront:self.button];
}
- (void)open { MGPresentLibrary(self.window); }
- (void)drag:(UIPanGestureRecognizer *)gesture { if (!self.pan.enabled) return; CGPoint delta=[gesture translationInView:self.window]; self.floatingCenter=CGPointMake(self.button.center.x+delta.x,self.button.center.y+delta.y); [gesture setTranslation:CGPointZero inView:self.window]; [self refresh]; }
@end
static MGDockCoordinator *MGCoordinator(UIWindow *window) {
    if (!window || window.windowLevel!=UIWindowLevelNormal || !window.isKeyWindow) return nil;
    MGDockCoordinator *coordinator=objc_getAssociatedObject(window,&MGDockCoordinatorKey);
    if (!coordinator) { coordinator=[MGDockCoordinator new]; coordinator.window=window; objc_setAssociatedObject(window,&MGDockCoordinatorKey,coordinator,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return coordinator;
}
static void MGRefreshDock(UIWindow *window) { [MGCoordinator(window) schedule]; }
%group MangaGlassHooks
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Subclasses finish building their screen before the one-time styling pass.
    MGStyleHostController(self);
    __weak UIWindow *window = self.view.window;
    dispatch_async(dispatch_get_main_queue(), ^{ MGRefreshDock(window); });
}
%end

%hook UINavigationBar
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        MGStyleBar(self);
    }
}
%end

%hook UITabBar
- (void)layoutSubviews {
    %orig;
    MGRefreshDock(self.window);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        MGStyleBar(self);
        MGRefreshDock(self.window);
    }
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

// Rows arriving after viewDidAppear receive a lightweight color update.
// This adds no per-cell blur views and never mutates layout or tab indices.
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
- (void)becomeKeyWindow {
    %orig;
    MGRefreshDock(self);
}
%end
%end

%ctor {
    @autoreleasepool {
        NSString *bundle = [NSBundle mainBundle].bundleIdentifier.lowercaseString;
        if ([bundle containsString:@"spotify"] || NSClassFromString(@"SPTNowPlayingViewController")) {
            %init(MangaGlassHooks);
        }
    }
}
