#pragma once
#import <UIKit/UIKit.h>

// Idempotent, touch-transparent materials. No layout hooks or recursive re-layout.
UIVisualEffect *MGGlassEffect(void);
void MGInstallGlass(UIView *view);
void MGStyleHostController(UIViewController *controller);
void MGStyleHostListSurface(UIView *view);
void MGStyleBar(UIView *bar);
void MGStartGlassObservers(void);
