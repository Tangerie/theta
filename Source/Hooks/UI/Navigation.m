#import "Include/ThetaTweakCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>

// MARK: - Helpers

static NSString *THTabIntentForLabel(NSString *label) {
    if (!label.length) return nil;
    NSString *lower = label.lowercaseString;
    if ([lower containsString:@"feed"] || [lower isEqualToString:@"home"]) return @"FEED";
    if ([lower containsString:@"reels"] || [lower containsString:@"clips"]) return @"CLIPS";
    if ([lower containsString:@"explore"] || [lower containsString:@"search"]) return @"SEARCH";
    if ([lower containsString:@"direct"] || [lower containsString:@"messages"]) return @"DIRECT";
    if ([lower containsString:@"create"]) return @"CREATE";
    return nil;
}

static BOOL THShouldHideTabByIntent(NSString *intent) {
    if (!intent) return NO;
    if ([intent isEqualToString:@"FEED"]   && ENABLED(@"Hide Feed Tab"))     return YES;
    if ([intent isEqualToString:@"CLIPS"]  && ENABLED(@"Hide Reels Tab"))    return YES;
    if ([intent isEqualToString:@"SEARCH"] && ENABLED(@"Hide Explore Tab"))  return YES;
    if ([intent isEqualToString:@"DIRECT"] && ENABLED(@"Hide Messages Tab")) return YES;
    return NO;
}

static BOOL THShouldHideTabForSurface(id surface) {
    if (!surface) return NO;
    NSString *intent = nil;
    @try {
        intent = [surface performSelector:@selector(tabStringFromSurfaceIntent)];
    } @catch (__unused NSException *e) {}
    return THShouldHideTabByIntent(intent);
}

// MARK: - Tab Icon Ordering

static NSInteger (*orig_tabOrdering)(id, SEL) = NULL;
static NSInteger hook_tabOrdering(id self, SEL _cmd) {
    // 0 = classic, 1 = standard, 2 = alternate
    NSInteger idx = [[NSUserDefaults standardUserDefaults] integerForKey:@"Tab Icon Order_SegmentIndex"];
    if (idx == 1) return 0;  // Classic
    if (idx == 2) return 1;  // Standard
    if (idx == 3) return 2;  // Alternate
    return orig_tabOrdering ? orig_tabOrdering(self, _cmd) : 1;
}

// MARK: - Swipe Between Tabs

static BOOL (*orig_isTabSwipingEnabled)(id, SEL) = NULL;
static BOOL hook_isTabSwipingEnabled(id self, SEL _cmd) {
    NSInteger idx = [[NSUserDefaults standardUserDefaults] integerForKey:@"Swipe Between Tabs_SegmentIndex"];
    if (idx == 1) return YES;   // Enabled
    if (idx == 2) return NO;    // Disabled
    return orig_isTabSwipingEnabled ? orig_isTabSwipingEnabled(self, _cmd) : YES;
}

// MARK: - Launch Tab

static void (*orig_viewWillAppear_tabBar)(id, SEL, BOOL) = NULL;
static void hook_viewWillAppear_tabBar(id self, SEL _cmd, BOOL animated) {
    orig_viewWillAppear_tabBar(self, _cmd, animated);

    // Only fire once at launch, and only if Messenger Mode is not active
    if (ENABLED(@"Messenger Mode")) return;

    static BOOL sLaunchFired = NO;
    if (sLaunchFired) return;
    sLaunchFired = YES;

    NSInteger launchIdx = [[NSUserDefaults standardUserDefaults] integerForKey:@"Launch Tab_SegmentIndex"];
    NSString *selName = nil;
    switch (launchIdx) {
        case 1:  selName = @"_timelineButtonPressed";       break; // Home
        case 2:  selName = @"_exploreButtonPressed";         break; // Explore
        case 3:  selName = @"_discoverVideoButtonPressed";   break; // Reels
        case 4:  selName = @"_directInboxButtonPressed";     break; // Messages
        case 5:  selName = @"_profileButtonPressed";         break; // Profile
        default: break;
    }
    if (selName) {
        SEL sel = NSSelectorFromString(selName);
        if ([self respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(self, sel);
        }
    }
}

void THRegisterNavigationHooks(void) {
    // _TtC18IGNavConfiguration18IGNavConfiguration is the Swift class name
    Class navConfig = objc_getClass("_TtC18IGNavConfiguration18IGNavConfiguration");
    if (navConfig) {
        SEL tabOrd = sel_registerName("tabOrdering");
        SEL swipe = sel_registerName("isTabSwipingEnabled");

        if ([navConfig instancesRespondToSelector:tabOrd])
            NullHookMessageEx(navConfig, tabOrd, (void *)hook_tabOrdering, &orig_tabOrdering);
        if ([navConfig instancesRespondToSelector:swipe])
            NullHookMessageEx(navConfig, swipe, (void *)hook_isTabSwipingEnabled, &orig_isTabSwipingEnabled);
    }

    // Launch tab — hooks IGTabBarController viewWillAppear
    Class tbCls = objc_getClass("IGTabBarController");
    NullHookMessageEx(tbCls, @selector(viewWillAppear:), (void *)hook_viewWillAppear_tabBar, &orig_viewWillAppear_tabBar);
}
