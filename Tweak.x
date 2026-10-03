#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "MangaViewController.h"
#import "MGGlass.h"
#import "MGSettings.h"

static char MGDockCoordinatorKey;

@interface MGDockCoordinator : NSObject
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIView *dock;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *constraints;
@property (nonatomic, strong) NSLayoutConstraint *trailing;
@property (nonatomic, strong) NSLayoutConstraint *bottom;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
- (void)refresh;
@end

static UIView *MGFindDock(UIWindow *window) {
    NSMutableArray<UIView *> *queue = [window.subviews mutableCopy];
    for (NSUInteger cursor = 0; cursor < queue.count && cursor < 500; cursor++) {
        UIView *view = queue[cursor];
        if (view.hidden || view.alpha < .01) continue;
        NSString *name = NSStringFromClass(view.class).lowercaseString;
        BOOL candidate = [view isKindOfClass:[UITabBar class]] || [name containsString:@"tabbar"] || [name containsString:@"bottomnavigation"];
        CGRect frame = [view convertRect:view.bounds toView:window];
        if (candidate && view.window == window && frame.size.width > window.bounds.size.width * .6 &&
            frame.size.height >= 30 && frame.size.height <= 180 && CGRectGetMinY(frame) >= window.bounds.size.height * .55 &&
            CGRectGetMinY(frame) < window.bounds.size.height) return view;
        if ([view isKindOfClass:[UIVisualEffectView class]] || [view isKindOfClass:[UIImageView class]]) continue;
        if (queue.count < 650) [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

@implementation MGDockCoordinator
- (instancetype)init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:) name:MGSettingsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    } return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)changed:(NSNotification *)notification {
    NSString *key = notification.userInfo[@"key"];
    if (key && ![@[@"glass", @"floatingFallback"] containsObject:key]) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
}
- (void)refresh {
    UIWindow *window = self.window;
    if (!window || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) return;
    UIViewController *presented = window.rootViewController;
    while (presented.presentedViewController) presented = presented.presentedViewController;
    if ([presented isKindOfClass:[MGNavigationController class]]) { self.button.hidden = YES; return; }
    UIView *dock = MGFindDock(window);
    BOOL fallback = !dock;
    if (fallback && ![[MGSettings shared] flag:@"floatingFallback"]) { self.button.hidden = YES; return; }
    if (!self.button) {
        self.button = [UIButton buttonWithType:UIButtonTypeSystem]; self.button.translatesAutoresizingMaskIntoConstraints = NO;
        self.button.backgroundColor = [UIColor colorWithWhite:.12 alpha:.90]; self.button.layer.cornerRadius = 17; self.button.clipsToBounds = YES;
        self.button.layer.borderWidth = .5; self.button.layer.borderColor = [UIColor colorWithWhite:1 alpha:.28].CGColor;
        [self.button setTitle:@"  Manga" forState:UIControlStateNormal]; [self.button setImage:[UIImage systemImageNamed:@"book.closed"] forState:UIControlStateNormal];
        self.button.tintColor = [UIColor whiteColor]; self.button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        self.button.accessibilityLabel = @"Open MangaGlass library";
        self.button.accessibilityHint = @"Browse chapters and saved bookmarks.";
        [self.button addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]; [self.button addGestureRecognizer:self.pan];
        [window addSubview:self.button];
    }
    self.button.hidden = NO; self.pan.enabled = fallback;
    if (dock && ![dock isKindOfClass:[UITabBar class]]) MGInstallGlass(dock);
    if (self.dock != dock || !self.constraints.count) {
        [NSLayoutConstraint deactivateConstraints:self.constraints ?: @[]];
        self.dock = dock;
        NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[[self.button.widthAnchor constraintEqualToConstant:104], [self.button.heightAnchor constraintEqualToConstant:34]]];
        self.trailing = [self.button.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-12];
        [constraints addObject:self.trailing];
        if (dock) {
            // Dock accessory: sits at its upper edge, leaving Spotify's tabs and delegate untouched.
            [constraints addObject:[self.button.centerYAnchor constraintEqualToAnchor:dock.topAnchor constant:-14]];
            self.bottom = nil;
        } else {
            self.bottom = [self.button.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-90];
            [constraints addObject:self.bottom];
        }
        self.constraints = constraints; [NSLayoutConstraint activateConstraints:constraints];
    }
    MGInstallGlass(self.button);
}
- (void)open { MGPresentLibrary(self.window); }
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if (self.dock || !self.bottom) return;
    UIWindow *window = self.window; CGPoint delta = [gesture translationInView:window];
    CGRect safe = window.safeAreaLayoutGuide.layoutFrame;
    CGPoint center = CGPointMake(self.button.center.x + delta.x, self.button.center.y + delta.y);
    center.x = MIN(CGRectGetMaxX(safe) - 56, MAX(CGRectGetMinX(safe) + 56, center.x));
    center.y = MIN(CGRectGetMaxY(safe) - 21, MAX(CGRectGetMinY(safe) + 21, center.y));
    self.trailing.constant = center.x + 52 - CGRectGetMaxX(safe);
    self.bottom.constant = center.y + 17 - CGRectGetMaxY(safe);
    [gesture setTranslation:CGPointZero inView:window]; [window layoutIfNeeded];
}
@end

static void MGRefreshDock(UIWindow *window) {
    if (!window || window.windowLevel != UIWindowLevelNormal || !window.isKeyWindow) return;
    MGDockCoordinator *coordinator = objc_getAssociatedObject(window, &MGDockCoordinatorKey);
    if (!coordinator) {
        coordinator = [MGDockCoordinator new]; coordinator.window = window;
        objc_setAssociatedObject(window, &MGDockCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [coordinator refresh];
}

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
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        MGStyleBar(self);
        MGRefreshDock(self.window);
    }
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
