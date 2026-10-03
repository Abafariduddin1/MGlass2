#import "MGGlass.h"
#import "MGSettings.h"
#import <objc/runtime.h>
#import <objc/message.h>

static char MGStateKey, MGEffectKey, MGBarKey, MGStyledKey, MGButtonBudgetKey;
static NSHashTable<UIView *> *MGViews, *MGRoots, *MGBars;
static NSHashTable<UIViewController *> *MGControllers;
static NSUInteger MGThemeGeneration = 1;
@interface MGVisualState : NSObject
@property (nonatomic, strong) UIColor *background, *tint, *text, *border;
@property (nonatomic) CGFloat radius, borderWidth;
@property (nonatomic, strong) id configuration;
@property (nonatomic) NSUInteger generation;
@end
@implementation MGVisualState
@end
@interface MGBarState : NSObject
@property (nonatomic, strong) id standard, compact, edge, compactEdge;
@property (nonatomic, strong) UIColor *tint;
@end
@implementation MGBarState
@end
static BOOL MGGlassEnabled(void) { return [[MGSettings shared] flag:@"glass"] && !UIAccessibilityIsReduceTransparencyEnabled(); }
static BOOL MGLightTheme(void) { CGFloat r=0,g=0,b=0; [MGBackgroundColor() getRed:&r green:&g blue:&b alpha:NULL]; return r*.2126 + g*.7152 + b*.0722 > .55; }
static UIBlurEffect *MGMaterial(void) { return [UIBlurEffect effectWithStyle:MGLightTheme() ? UIBlurEffectStyleSystemThinMaterialLight : UIBlurEffectStyleSystemThinMaterialDark]; }
UIVisualEffect *MGGlassEffect(void) {
    Class type=NSClassFromString(@"UIGlassEffect"); SEL factory=NSSelectorFromString(@"effectWithStyle:");
    if (@available(iOS 26.0,*)) if (type && [type respondsToSelector:factory]) return ((id (*)(id,SEL,NSInteger))objc_msgSend)(type,factory,[[[MGSettings shared] text:@"glassStyle"] isEqualToString:@"clear"] ? 1 : 0);
    return MGMaterial();
}
static MGVisualState *MGRemember(UIView *view) {
    MGStartGlassObservers(); MGVisualState *state=objc_getAssociatedObject(view,&MGStateKey);
    if (!state) {
        state=[MGVisualState new]; state.background=view.backgroundColor; state.tint=view.tintColor; state.radius=view.layer.cornerRadius; state.borderWidth=view.layer.borderWidth;
        if (view.layer.borderColor) state.border=[UIColor colorWithCGColor:view.layer.borderColor];
        if ([view isKindOfClass:[UILabel class]]) state.text=((UILabel *)view).textColor;
        if (@available(iOS 15.0,*)) if ([view isKindOfClass:[UIButton class]]) state.configuration=[((UIButton *)view).configuration copy];
        objc_setAssociatedObject(view,&MGStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC); [MGViews addObject:view];
    }
    return state;
}
static void MGRestore(UIView *view) {
    [objc_getAssociatedObject(view,&MGEffectKey) removeFromSuperview]; objc_setAssociatedObject(view,&MGEffectKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MGVisualState *state=objc_getAssociatedObject(view,&MGStateKey); if (!state) return;
    view.backgroundColor=state.background; view.tintColor=state.tint; view.layer.cornerRadius=state.radius; view.layer.borderWidth=state.borderWidth; view.layer.borderColor=state.border.CGColor;
    if ([view isKindOfClass:[UILabel class]]) ((UILabel *)view).textColor=state.text;
    if (@available(iOS 15.0,*)) if ([view isKindOfClass:[UIButton class]]) ((UIButton *)view).configuration=state.configuration;
    state.generation=0;
}
void MGInstallGlass(UIView *view) {
    if (!view || !NSThread.isMainThread) return;
    if ([view isKindOfClass:[UINavigationBar class]] || [view isKindOfClass:[UITabBar class]] || [view isKindOfClass:[UIToolbar class]]) { MGStyleBar(view); return; }
    if ([view isKindOfClass:[UIButton class]]) { MGStyleButton((UIButton *)view); return; }
    MGVisualState *state=MGRemember(view); [MGRoots addObject:view];
    BOOL panel=view.bounds.size.height>0 && view.bounds.size.height<=180 && ![view isKindOfClass:[UIScrollView class]];
    // Content screens share a flat theme background. Foreground panels carry
    // glass; no full-screen live blur or per-row material is needed.
    if (!panel) { view.backgroundColor=MGBackgroundColor(); return; }
    if (!MGGlassEnabled()) { MGRestore(view); view.backgroundColor=MGBackgroundColor(); return; }
    if (state.generation==MGThemeGeneration && objc_getAssociatedObject(view,&MGEffectKey)) return;
    [objc_getAssociatedObject(view,&MGEffectKey) removeFromSuperview];
    UIVisualEffectView *effect=[[UIVisualEffectView alloc] initWithEffect:MGGlassEffect()]; effect.frame=view.bounds;
    effect.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; effect.userInteractionEnabled=NO; effect.accessibilityElementsHidden=YES;
    effect.layer.zPosition=-1; effect.layer.cornerRadius=[[MGSettings shared] number:@"roundness"]; effect.clipsToBounds=YES;
    [view insertSubview:effect atIndex:0]; view.backgroundColor=UIColor.clearColor; objc_setAssociatedObject(view,&MGEffectKey,effect,OBJC_ASSOCIATION_RETAIN_NONATOMIC); state.generation=MGThemeGeneration;
}
void MGStyleButton(UIButton *button) {
    if (!button || !NSThread.isMainThread) return;
    MGVisualState *state=MGRemember(button); if (state.generation==MGThemeGeneration) return;
    BOOL glass=MGGlassEnabled() && [[MGSettings shared] flag:@"glassButtons"]; button.tintColor=MGAccentColor();
    if (glass) {
        if (@available(iOS 15.0,*)) {
            UIButtonConfiguration *original=state.configuration, *configuration=nil;
            if (@available(iOS 26.0,*)) {
                SEL factory=NSSelectorFromString([[[MGSettings shared] text:@"glassStyle"] isEqualToString:@"clear"] ? @"clearGlassButtonConfiguration" : @"glassButtonConfiguration");
                if ([UIButtonConfiguration respondsToSelector:factory]) configuration=((id (*)(id,SEL))objc_msgSend)([UIButtonConfiguration class],factory);
            }
            if (!configuration) configuration=[UIButtonConfiguration grayButtonConfiguration];
            configuration.title=original.title ?: button.currentTitle; configuration.subtitle=original.subtitle; configuration.image=original.image ?: button.currentImage; configuration.attributedTitle=original.attributedTitle;
            configuration.baseForegroundColor=MGAccentColor(); configuration.imagePadding=original ? original.imagePadding : 6;
            configuration.imagePlacement=original ? original.imagePlacement : NSDirectionalRectEdgeLeading;
            configuration.contentInsets=original ? original.contentInsets : NSDirectionalEdgeInsetsMake(7,12,7,12);
            configuration.titleTextAttributesTransformer=original.titleTextAttributesTransformer; configuration.buttonSize=original ? original.buttonSize : UIButtonConfigurationSizeMedium;
            configuration.background.cornerRadius=[[MGSettings shared] number:@"roundness"];
            configuration.cornerStyle=[[MGSettings shared] number:@"roundness"]>=28 ? UIButtonConfigurationCornerStyleCapsule : UIButtonConfigurationCornerStyleFixed;
            if (@available(iOS 26.0,*)) { } else configuration.background.backgroundColor=[MGBackgroundColor() colorWithAlphaComponent:.45];
            button.configuration=configuration;
        } else {
            button.backgroundColor=[MGBackgroundColor() colorWithAlphaComponent:.6]; button.layer.cornerRadius=[[MGSettings shared] number:@"roundness"]; button.layer.borderColor=[MGTextColor() colorWithAlphaComponent:.18].CGColor; button.layer.borderWidth=.5;
        }
    } else {
        if (@available(iOS 15.0,*)) button.configuration=state.configuration;
        button.backgroundColor=state.background; button.layer.cornerRadius=state.radius; button.layer.borderWidth=state.borderWidth; button.layer.borderColor=state.border.CGColor;
    }
    state.generation=MGThemeGeneration;
}
static BOOL MGSpotifyController(UIViewController *controller) {
    if (!controller.isViewLoaded) return NO; NSString *name=NSStringFromClass(controller.class);
    if ([name hasPrefix:@"MG"] || [name hasPrefix:@"Manga"]) return NO;
    NSBundle *bundle=[NSBundle bundleForClass:controller.class]; return [name hasPrefix:@"SPT"] || [bundle.bundleIdentifier.lowercaseString containsString:@"spotify"] || bundle==NSBundle.mainBundle;
}
static UIViewController *MGHostOwner(UIView *view) {
    UIResponder *owner=view.nextResponder;
    for (NSUInteger depth=0; owner && depth<24; depth++,owner=owner.nextResponder) if ([owner isKindOfClass:[UIViewController class]]) return MGSpotifyController((UIViewController *)owner) ? (UIViewController *)owner : nil;
    return nil;
}
static BOOL MGHostView(UIView *view) { return MGHostOwner(view)!=nil; }
static BOOL MGInReusedCell(UIView *view) {
    for (NSUInteger depth=0; view && depth<18; depth++,view=view.superview) if ([view isKindOfClass:[UITableViewCell class]] || [view isKindOfClass:[UICollectionViewCell class]]) return YES;
    return NO;
}
static void MGSoftenSurface(UIView *view) {
    UIColor *original=((MGVisualState *)objc_getAssociatedObject(view,&MGStateKey)).background ?: view.backgroundColor;
    CGFloat r=0,g=0,b=0,a=0; if (![original getRed:&r green:&g blue:&b alpha:&a] || a<.8 || MAX(r,MAX(g,b))-MIN(r,MIN(g,b))>.09) return;
    MGRemember(view); view.backgroundColor=[view isKindOfClass:[UIScrollView class]] ? UIColor.clearColor : MGSurfaceColor();
}
void MGStyleHostControl(UIView *view) {
    if (!view.window || !NSThread.isMainThread || !MGHostView(view)) return;
    if ([view isKindOfClass:[UIButton class]] && view.bounds.size.width>=28 && view.bounds.size.height>=28) {
        if (MGInReusedCell(view)) { MGRemember(view); view.tintColor=MGAccentColor(); }
        else {
            UIViewController *owner=MGHostOwner(view); NSHashTable *buttons=objc_getAssociatedObject(owner,&MGButtonBudgetKey);
            if (!buttons) { buttons=[NSHashTable weakObjectsHashTable]; objc_setAssociatedObject(owner,&MGButtonBudgetKey,buttons,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            if ([buttons containsObject:view] || buttons.count<12) { [buttons addObject:view]; MGStyleButton((UIButton *)view); }
            else { MGRemember(view); view.tintColor=MGAccentColor(); }
        }
    }
    if ([view isKindOfClass:[UILabel class]] && [[MGSettings shared] flag:@"hostText"]) {
        UILabel *label=(id)view; UIColor *original=((MGVisualState *)objc_getAssociatedObject(view,&MGStateKey)).text ?: label.textColor;
        CGFloat r=0,g=0,b=0,a=0;
        if ([original getRed:&r green:&g blue:&b alpha:&a] && MAX(r,MAX(g,b))-MIN(r,MIN(g,b))<.08) { MGRemember(view); label.textColor=[MGTextColor() colorWithAlphaComponent:a*(MAX(r,MAX(g,b))<.65 ? .7 : 1)]; }
    }
}
void MGStyleHostListSurface(UIView *view) {
    if (!view.window || !NSThread.isMainThread || !MGHostView(view)) return; MGSoftenSurface(view);
    UIView *content=[view isKindOfClass:[UITableViewCell class]] ? ((UITableViewCell *)view).contentView : [view isKindOfClass:[UICollectionViewCell class]] ? ((UICollectionViewCell *)view).contentView : nil;
    if (!content) return; MGSoftenSurface(content); NSMutableArray *queue=[content.subviews mutableCopy];
    for (NSUInteger i=0; i<queue.count && i<24; i++) { UIView *child=queue[i]; if ([child isKindOfClass:[UILabel class]]) MGStyleHostControl(child); if (![child isKindOfClass:[UIControl class]] && ![child isKindOfClass:[UIImageView class]] && queue.count<24) [queue addObjectsFromArray:child.subviews]; }
}
void MGStyleHostController(UIViewController *controller) {
    if (!MGSpotifyController(controller) || !NSThread.isMainThread) return; MGStartGlassObservers(); [MGControllers addObject:controller];
    if ([objc_getAssociatedObject(controller,&MGStyledKey) unsignedIntegerValue]==MGThemeGeneration) return;
    objc_setAssociatedObject(controller,&MGStyledKey,@(MGThemeGeneration),OBJC_ASSOCIATION_RETAIN_NONATOMIC); MGInstallGlass(controller.view);
    NSMutableArray *queue=[controller.view.subviews mutableCopy]; NSUInteger buttons=0;
    for (NSUInteger i=0; i<queue.count && i<280; i++) {
        UIView *view=queue[i]; if (view.hidden || view.alpha<.01) continue;
        if ([view isKindOfClass:[UINavigationBar class]] || [view isKindOfClass:[UITabBar class]] || [view isKindOfClass:[UIToolbar class]]) { MGStyleBar(view); continue; }
        if ([view isKindOfClass:[UIVisualEffectView class]] || [view isKindOfClass:[UIImageView class]]) continue;
        if ([view isKindOfClass:[UIButton class]]) { CGRect rect=[view convertRect:view.bounds toView:controller.view]; if (buttons<12 && CGRectIntersectsRect(rect,controller.view.bounds)) { MGStyleHostControl(view); buttons++; } continue; }
        if ([view isKindOfClass:[UILabel class]]) { MGStyleHostControl(view); continue; }
        MGSoftenSurface(view); if (queue.count<380) [queue addObjectsFromArray:view.subviews];
    }
}
static void MGRestoreBar(UIView *bar) {
    MGBarState *state=objc_getAssociatedObject(bar,&MGBarKey); if (!state) return;
    if ([bar isKindOfClass:[UINavigationBar class]]) { UINavigationBar *nav=(id)bar; nav.standardAppearance=state.standard; nav.compactAppearance=state.compact; nav.scrollEdgeAppearance=state.edge; if (@available(iOS 15.0,*)) nav.compactScrollEdgeAppearance=state.compactEdge; }
    if ([bar isKindOfClass:[UIToolbar class]]) { UIToolbar *toolbar=(id)bar; toolbar.standardAppearance=state.standard; toolbar.compactAppearance=state.compact; if (@available(iOS 15.0,*)) { toolbar.scrollEdgeAppearance=state.edge; toolbar.compactScrollEdgeAppearance=state.compactEdge; } }
    if ([bar isKindOfClass:[UITabBar class]]) { UITabBar *tab=(id)bar; tab.standardAppearance=state.standard; if (@available(iOS 15.0,*)) tab.scrollEdgeAppearance=state.edge; }
    bar.tintColor=state.tint;
}
void MGStyleBar(UIView *bar) {
    if (!bar || !NSThread.isMainThread) return; MGStartGlassObservers(); [MGBars addObject:bar]; MGBarState *state=objc_getAssociatedObject(bar,&MGBarKey);
    if (!state) {
        state=[MGBarState new]; state.tint=bar.tintColor;
        if ([bar isKindOfClass:[UINavigationBar class]]) { UINavigationBar *nav=(id)bar; state.standard=[nav.standardAppearance copy]; state.compact=[nav.compactAppearance copy]; state.edge=[nav.scrollEdgeAppearance copy]; if (@available(iOS 15.0,*)) state.compactEdge=[nav.compactScrollEdgeAppearance copy]; }
        if ([bar isKindOfClass:[UIToolbar class]]) { UIToolbar *toolbar=(id)bar; state.standard=[toolbar.standardAppearance copy]; state.compact=[toolbar.compactAppearance copy]; if (@available(iOS 15.0,*)) { state.edge=[toolbar.scrollEdgeAppearance copy]; state.compactEdge=[toolbar.compactScrollEdgeAppearance copy]; } }
        if ([bar isKindOfClass:[UITabBar class]]) { UITabBar *tab=(id)bar; state.standard=[tab.standardAppearance copy]; if (@available(iOS 15.0,*)) state.edge=[tab.scrollEdgeAppearance copy]; }
        objc_setAssociatedObject(bar,&MGBarKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL glass=MGGlassEnabled(); UIBlurEffect *effect=nil; if (glass) { if (@available(iOS 26.0,*)) { } else effect=MGMaterial(); }
    UIBarButtonItemAppearance *buttons=[[UIBarButtonItemAppearance alloc] initWithStyle:UIBarButtonItemStylePlain];
    buttons.normal.titleTextAttributes=@{NSForegroundColorAttributeName:MGAccentColor()}; buttons.highlighted.titleTextAttributes=buttons.normal.titleTextAttributes; buttons.disabled.titleTextAttributes=@{NSForegroundColorAttributeName:[MGTextColor() colorWithAlphaComponent:.35]};
    if ([bar isKindOfClass:[UINavigationBar class]]) {
        UINavigationBar *nav=(id)bar; UINavigationBarAppearance *appearance=[state.standard copy];
        if (glass) [appearance configureWithDefaultBackground]; else [appearance configureWithOpaqueBackground];
        appearance.backgroundEffect=effect; appearance.backgroundColor=[MGBackgroundColor() colorWithAlphaComponent:glass ? .15 : 1]; appearance.titleTextAttributes=@{NSForegroundColorAttributeName:MGTextColor()}; appearance.largeTitleTextAttributes=appearance.titleTextAttributes; appearance.buttonAppearance=buttons; appearance.doneButtonAppearance=buttons; appearance.backButtonAppearance=buttons;
        nav.standardAppearance=appearance; nav.compactAppearance=appearance; nav.scrollEdgeAppearance=appearance; if (@available(iOS 15.0,*)) nav.compactScrollEdgeAppearance=appearance;
    }
    if ([bar isKindOfClass:[UIToolbar class]]) {
        UIToolbar *toolbar=(id)bar; UIToolbarAppearance *appearance=[state.standard copy]; if (glass) [appearance configureWithDefaultBackground]; else [appearance configureWithOpaqueBackground];
        appearance.backgroundEffect=effect; appearance.backgroundColor=[MGBackgroundColor() colorWithAlphaComponent:glass ? .15 : 1]; appearance.buttonAppearance=buttons; appearance.doneButtonAppearance=buttons;
        toolbar.standardAppearance=appearance; toolbar.compactAppearance=appearance; if (@available(iOS 15.0,*)) { toolbar.scrollEdgeAppearance=appearance; toolbar.compactScrollEdgeAppearance=appearance; }
    }
    if ([bar isKindOfClass:[UITabBar class]]) {
        UITabBar *tab=(id)bar; UITabBarAppearance *appearance=[state.standard copy]; if (glass) [appearance configureWithDefaultBackground]; else [appearance configureWithOpaqueBackground];
        appearance.backgroundEffect=effect; appearance.backgroundColor=[MGBackgroundColor() colorWithAlphaComponent:glass ? .15 : 1];
        for (UITabBarItemAppearance *item in @[appearance.stackedLayoutAppearance,appearance.inlineLayoutAppearance,appearance.compactInlineLayoutAppearance]) { item.normal.iconColor=[MGTextColor() colorWithAlphaComponent:.65]; item.normal.titleTextAttributes=@{NSForegroundColorAttributeName:[MGTextColor() colorWithAlphaComponent:.65]}; item.selected.iconColor=MGAccentColor(); item.selected.titleTextAttributes=@{NSForegroundColorAttributeName:MGAccentColor()}; }
        tab.standardAppearance=appearance; if (@available(iOS 15.0,*)) tab.scrollEdgeAppearance=appearance;
    }
    bar.tintColor=MGAccentColor(); bar.tintAdjustmentMode=UIViewTintAdjustmentModeNormal; bar.overrideUserInterfaceStyle=MGLightTheme()?UIUserInterfaceStyleLight:UIUserInterfaceStyleDark;
}
void MGConfigureNavigationAppearance(UINavigationController *controller) { controller.overrideUserInterfaceStyle=MGLightTheme()?UIUserInterfaceStyleLight:UIUserInterfaceStyleDark; controller.view.tintColor=MGAccentColor(); MGStyleBar(controller.navigationBar); MGStyleBar(controller.toolbar); }
@interface MGGlassObserver : NSObject
@end
@implementation MGGlassObserver
- (void)refresh:(NSNotification *)notification {
    if (!MGIsAppearancePreference(notification.userInfo[@"key"])) return;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{ [self refresh:nil]; }); return; }
    ++MGThemeGeneration;
    for (UIView *view in MGViews.allObjects) MGRestore(view);
    for (UIView *bar in MGBars.allObjects) { MGRestoreBar(bar); MGStyleBar(bar); }
    for (UIView *root in MGRoots.allObjects) if (root.window) MGInstallGlass(root);
    for (UIViewController *controller in MGControllers.allObjects) if (controller.view.window) MGStyleHostController(controller);
    for (UIView *view in MGViews.allObjects) if (view.window && [view isKindOfClass:[UIButton class]]) { if (MGHostView(view)) MGStyleHostControl(view); else MGStyleButton((UIButton *)view); }
}
@end
void MGStartGlassObservers(void) {
    static dispatch_once_t once; static MGGlassObserver *observer;
    dispatch_once(&once,^{ MGViews=[NSHashTable weakObjectsHashTable]; MGRoots=[NSHashTable weakObjectsHashTable]; MGBars=[NSHashTable weakObjectsHashTable]; MGControllers=[NSHashTable weakObjectsHashTable]; observer=[MGGlassObserver new];
        [[NSNotificationCenter defaultCenter] addObserver:observer selector:@selector(refresh:) name:MGSettingsDidChangeNotification object:nil]; [[NSNotificationCenter defaultCenter] addObserver:observer selector:@selector(refresh:) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    });
}
