#import "MGGlass.h"
#import "MGSettings.h"
#import <objc/runtime.h>
#import <objc/message.h>

static char MGEffectKey, MGColorKey, MGStyledControllerKey, MGBarAppearanceKey, MGBarScrollKey;
static NSHashTable<UIView *> *MGSurfaces;
static NSHashTable<UIViewController *> *MGControllers;
static NSHashTable<UIView *> *MGBars;
static NSHashTable<UIView *> *MGGlassRoots;

UIVisualEffect *MGGlassEffect(void) {
    // Runtime lookup keeps iOS 14 and older SDK builds working. Use native glass where present.
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    SEL factory = NSSelectorFromString(@"effectWithStyle:");
    if (@available(iOS 26.0, *)) {
        if (glassClass && [glassClass respondsToSelector:factory])
            return ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, factory, 0);
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

static void MGRememberColor(UIView *view) {
    if (!objc_getAssociatedObject(view, &MGColorKey)) {
        objc_setAssociatedObject(view, &MGColorKey, view.backgroundColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [MGSurfaces addObject:view];
    }
}

static void MGRestoreSurface(UIView *view) {
    [objc_getAssociatedObject(view, &MGEffectKey) removeFromSuperview];
    objc_setAssociatedObject(view, &MGEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id old = objc_getAssociatedObject(view, &MGColorKey);
    if (old) view.backgroundColor = old == [NSNull null] ? nil : old;
    objc_setAssociatedObject(view, &MGColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void MGInstallGlass(UIView *view) {
    if (!view || ![NSThread isMainThread]) return;
    // UIKit owns a bar's content hierarchy. Style its background through the
    // appearance API rather than inserting an effect beside its buttons.
    if ([view isKindOfClass:[UINavigationBar class]] || [view isKindOfClass:[UITabBar class]]) {
        MGStyleBar(view);
        return;
    }
    MGStartGlassObservers();
    [MGGlassRoots addObject:view];
    if (![[MGSettings shared] flag:@"glass"] || UIAccessibilityIsReduceTransparencyEnabled()) {
        MGRestoreSurface(view); return;
    }
    if (objc_getAssociatedObject(view, &MGEffectKey)) return;
    MGRememberColor(view);
    // Full-screen surfaces are backdrops. Reserve native glass for small
    // controls so it cannot composite the screen's content as part of a lens.
    BOOL smallSurface = [view isKindOfClass:[UIControl class]] || (view.bounds.size.height > 0 && view.bounds.size.height <= 180);
    UIVisualEffect *effect = smallSurface ? MGGlassEffect() : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.frame = view.bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glass.userInteractionEnabled = NO;
    glass.accessibilityElementsHidden = YES;
    [view insertSubview:glass atIndex:0];
    view.backgroundColor = [UIColor clearColor];
    objc_setAssociatedObject(view, &MGEffectKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL MGSpotifyController(UIViewController *controller) {
    if (!controller.isViewLoaded) return NO;
    NSString *name = NSStringFromClass(controller.class);
    if ([name hasPrefix:@"MG"] || [name hasPrefix:@"Manga"]) return NO;
    NSBundle *bundle = [NSBundle bundleForClass:controller.class];
    return [name hasPrefix:@"SPT"] || [bundle.bundleIdentifier.lowercaseString containsString:@"spotify"] || bundle == [NSBundle mainBundle];
}

static void MGSoftenNeutralSurface(UIView *view) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    BOOL neutral = [view.backgroundColor getRed:&r green:&g blue:&b alpha:&a] && a > .85 &&
        MAX(r, MAX(g, b)) < .25 && MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) < .06;
    if (!neutral) return;
    MGRememberColor(view);
    view.backgroundColor = [UIColor colorWithWhite:.08 alpha:.16];
}

void MGStyleHostListSurface(UIView *view) {
    if (!view.window || ![NSThread isMainThread] || ![[MGSettings shared] flag:@"glass"] || UIAccessibilityIsReduceTransparencyEnabled()) return;
    UIResponder *owner = view.nextResponder;
    for (NSUInteger depth = 0; owner && depth < 24; depth++, owner = owner.nextResponder) {
        if (![owner isKindOfClass:[UIViewController class]]) continue;
        if (!MGSpotifyController((UIViewController *)owner)) return;
        MGStartGlassObservers(); MGSoftenNeutralSurface(view);
        if ([view isKindOfClass:[UITableViewCell class]]) MGSoftenNeutralSurface(((UITableViewCell *)view).contentView);
        if ([view isKindOfClass:[UICollectionViewCell class]]) MGSoftenNeutralSurface(((UICollectionViewCell *)view).contentView);
        return;
    }
}

void MGStyleHostController(UIViewController *controller) {
    if (!MGSpotifyController(controller) || ![NSThread isMainThread]) return;
    MGStartGlassObservers();
    [MGControllers addObject:controller];
    if (![[MGSettings shared] flag:@"glass"] || UIAccessibilityIsReduceTransparencyEnabled() || objc_getAssociatedObject(controller, &MGStyledControllerKey)) return;
    objc_setAssociatedObject(controller, &MGStyledControllerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MGInstallGlass(controller.view);
    // One bounded pass per controller. Keep artwork, controls, and colored brand surfaces intact.
    NSMutableArray<UIView *> *queue = [controller.view.subviews mutableCopy];
    for (NSUInteger cursor = 0; cursor < queue.count && cursor < 350; cursor++) {
        UIView *view = queue[cursor];
        if ([view isKindOfClass:[UIVisualEffectView class]] || [view isKindOfClass:[UIImageView class]] ||
            [view isKindOfClass:[UIControl class]] || [view isKindOfClass:[UINavigationBar class]] || [view isKindOfClass:[UITabBar class]]) continue;
        if (view.bounds.size.width >= 44 && view.bounds.size.height >= 30) MGSoftenNeutralSurface(view);
        if (queue.count < 500) [queue addObjectsFromArray:view.subviews];
    }
}

void MGStyleBar(UIView *bar) {
    if (!bar || ![NSThread isMainThread]) return;
    // Manga supplies its own complete navigation/toolbar appearance. Host
    // hooks must not overwrite it when the modal attaches to the window.
    Class readerNavigation = NSClassFromString(@"MGNavigationController");
    UIResponder *owner = bar.nextResponder;
    for (NSUInteger depth = 0; owner && depth < 24; depth++, owner = owner.nextResponder) {
        if (readerNavigation && [owner isKindOfClass:readerNavigation]) return;
    }
    MGStartGlassObservers();
    [MGBars addObject:bar];
    BOOL enabled = [[MGSettings shared] flag:@"glass"] && !UIAccessibilityIsReduceTransparencyEnabled();
    id original = objc_getAssociatedObject(bar, &MGBarAppearanceKey);
    if ([bar isKindOfClass:[UINavigationBar class]]) {
        UINavigationBar *nav = (UINavigationBar *)bar;
        if (!enabled) {
            if (original) {
                nav.standardAppearance = original;
                id edge = objc_getAssociatedObject(bar, &MGBarScrollKey);
                nav.scrollEdgeAppearance = edge == [NSNull null] ? nil : edge;
            }
        } else if (!original) {
            objc_setAssociatedObject(bar, &MGBarAppearanceKey, [nav.standardAppearance copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(bar, &MGBarScrollKey, [nav.scrollEdgeAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UINavigationBarAppearance *appearance = [nav.standardAppearance copy];
            [appearance configureWithTransparentBackground];
            appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
            appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[UIColor whiteColor]};
            nav.standardAppearance = appearance;
            nav.scrollEdgeAppearance = appearance;
        }
    } else if ([bar isKindOfClass:[UITabBar class]]) {
        UITabBar *tab = (UITabBar *)bar;
        if (!enabled) {
            if (original) {
                tab.standardAppearance = original;
                if (@available(iOS 15.0, *)) {
                    id edge = objc_getAssociatedObject(bar, &MGBarScrollKey);
                    tab.scrollEdgeAppearance = edge == [NSNull null] ? nil : edge;
                }
            }
        } else if (!original) {
            objc_setAssociatedObject(bar, &MGBarAppearanceKey, [tab.standardAppearance copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (@available(iOS 15.0, *)) objc_setAssociatedObject(bar, &MGBarScrollKey, [tab.scrollEdgeAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UITabBarAppearance *appearance = [tab.standardAppearance copy];
            [appearance configureWithTransparentBackground];
            appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
            tab.standardAppearance = appearance;
            if (@available(iOS 15.0, *)) tab.scrollEdgeAppearance = appearance;
        }
    }
    if (!enabled) {
        MGRestoreSurface(bar);
        objc_setAssociatedObject(bar, &MGBarAppearanceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(bar, &MGBarScrollKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@interface MGGlassObserver : NSObject
@end
@implementation MGGlassObserver
- (void)refresh:(NSNotification *)notification {
    NSString *preference = notification.userInfo[@"key"];
    if (preference && ![preference isEqualToString:@"glass"]) return;
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh:nil]; }); return; }
    for (UIView *view in MGSurfaces.allObjects) MGRestoreSurface(view);
    for (UIView *view in MGGlassRoots.allObjects) MGInstallGlass(view);
    for (UIViewController *controller in MGControllers.allObjects) {
        objc_setAssociatedObject(controller, &MGStyledControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        MGStyleHostController(controller);
    }
    for (UIView *bar in MGBars.allObjects) {
        // Restore first so enabling a material again cannot stack effects.
        id saved = objc_getAssociatedObject(bar, &MGBarAppearanceKey);
        if (saved) {
            id edge = objc_getAssociatedObject(bar, &MGBarScrollKey);
            if ([bar isKindOfClass:[UINavigationBar class]]) { ((UINavigationBar *)bar).standardAppearance = saved; ((UINavigationBar *)bar).scrollEdgeAppearance = edge == [NSNull null] ? nil : edge; }
            if ([bar isKindOfClass:[UITabBar class]]) { ((UITabBar *)bar).standardAppearance = saved; if (@available(iOS 15.0, *)) ((UITabBar *)bar).scrollEdgeAppearance = edge == [NSNull null] ? nil : edge; }
            objc_setAssociatedObject(bar, &MGBarAppearanceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(bar, &MGBarScrollKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        MGStyleBar(bar);
    }
}
@end

void MGStartGlassObservers(void) {
    static dispatch_once_t once;
    static MGGlassObserver *observer;
    dispatch_once(&once, ^{
        MGSurfaces = [NSHashTable weakObjectsHashTable];
        MGControllers = [NSHashTable weakObjectsHashTable];
        MGBars = [NSHashTable weakObjectsHashTable];
        MGGlassRoots = [NSHashTable weakObjectsHashTable];
        observer = [MGGlassObserver new];
        [[NSNotificationCenter defaultCenter] addObserver:observer selector:@selector(refresh:) name:MGSettingsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:observer selector:@selector(refresh:) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    });
}
