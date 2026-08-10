static void (*orig_hideTabs)(id self, SEL _cmd, BOOL animated);

/// IGTabBar keeps parallel lists; `_tabButtons` is the canonical mutable ivar (see IGTabBar `buttons` / `_tabButtons`).
/// Works whether the stored value is NSMutableArray (mutate in-place) or plain NSArray (copy, trim, write back).
static void theta_removeMatchingViewsFromTabBarMutableArrays(id tabBar, UIView *tabView, NSString *accessibilityLabel) {
    if (!tabBar || !accessibilityLabel.length) {
        return;
    }
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"_tabButtons", @"buttons", @"_buttons", @"_tabBarButtons", @"tabBarButtons" ];
    });
    for (NSString *key in keys) {
        @try {
            id arr = [tabBar valueForKey:key];
            if (![arr isKindOfClass:[NSArray class]] || ![(NSArray *)arr count]) {
                continue;
            }
            NSMutableArray *m = [(NSArray *)arr mutableCopy];
            NSUInteger before = m.count;
            for (NSInteger i = (NSInteger)m.count - 1; i >= 0; i--) {
                id o = [m objectAtIndex:(NSUInteger)i];
                BOOL match = (o == tabView);
                if (!match && [o isKindOfClass:[UIView class]]) {
                    match = [((UIView *)o).accessibilityLabel isEqualToString:accessibilityLabel];
                }
                if (match) {
                    [m removeObjectAtIndex:(NSUInteger)i];
                }
            }
            if (m.count != before) {
                [tabBar setValue:m forKey:key];
            }
        } @catch (__unused NSException *e) {
        }
    }
}

static UIView *theta_findViewWithAccessibilityLabel(NSString *label, UIView *root) {
    if (!root || !label.length) {
        return nil;
    }
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];
        if ([v.accessibilityLabel isEqualToString:label]) {
            return v;
        }
        for (UIView *sub in v.subviews) {
            [stack addObject:sub];
        }
    }
    return nil;
}

/// Removes the whole tab “column” (fixes empty gap), not only the inner labeled view. Handles UIStackView arranged subviews.
/// Only walks ancestors inside `tabBar` so we never detach the tab bar from the window. Prefers parents with 2+ subviews (sibling columns).
static void theta_detachTabSlotForLabel(UIView *start, UIView *tabBar, NSString *accessibilityLabel) {
    if (!tabBar || !accessibilityLabel.length) {
        return;
    }
    UIView *v = start;
    if (!v || ![v isDescendantOfView:tabBar]) {
        v = theta_findViewWithAccessibilityLabel(accessibilityLabel, tabBar);
    }
    if (!v) {
        return;
    }
    Class stackClass = NSClassFromString(@"UIStackView");
    while (v.superview && v.superview != tabBar) {
        UIView *p = v.superview;
        if (stackClass && [p isKindOfClass:stackClass]) {
            SEL remArr = NSSelectorFromString(@"removeArrangedSubview:");
            if ([p respondsToSelector:remArr]) {
                ((void (*)(id, SEL, UIView *))objc_msgSend)(p, remArr, v);
            }
            [v removeFromSuperview];
            return;
        }
        if (p.subviews.count >= 2U) {
            [v removeFromSuperview];
            return;
        }
        v = p;
    }
    if (v.superview == tabBar && tabBar.subviews.count >= 2U) {
        [v removeFromSuperview];
    }
}

/// Removes the tab’s UIViewController at the same index as `_buttons` so swipe / pager skips Reels or Explore.
static void theta_removeTabViewControllerAtIndex(id tabBarController, NSUInteger index) {
    if (!tabBarController) {
        return;
    }

    void (^applyNewViewControllers)(NSMutableArray *) = ^(NSMutableArray *mutableVCs) {
        if (index >= mutableVCs.count) {
            return;
        }
        [mutableVCs removeObjectAtIndex:index];
        NSArray *replacement = [mutableVCs copy];
        SEL setAnimated = @selector(setViewControllers:animated:);
        SEL setPlain = @selector(setViewControllers:);
        if ([tabBarController respondsToSelector:setAnimated]) {
            ((void (*)(id, SEL, NSArray *, BOOL))objc_msgSend)(tabBarController, setAnimated, replacement, NO);
        } else if ([tabBarController respondsToSelector:setPlain]) {
            ((void (*)(id, SEL, NSArray *))objc_msgSend)(tabBarController, setPlain, replacement);
        } else {
            @try {
                [tabBarController setValue:replacement forKey:@"viewControllers"];
            } @catch (__unused NSException *e) {
            }
        }
    };

    NSArray *existing = nil;
    if ([tabBarController respondsToSelector:@selector(viewControllers)]) {
        existing = ((NSArray * (*)(id, SEL))objc_msgSend)(tabBarController, @selector(viewControllers));
    }
    if (!existing) {
        @try {
            existing = [tabBarController valueForKey:@"viewControllers"];
        } @catch (__unused NSException *e) {
        }
    }
    if (!existing) {
        @try {
            existing = [tabBarController valueForKey:@"_viewControllers"];
        } @catch (__unused NSException *e) {
        }
    }
    if (existing.count > index) {
        NSMutableArray *m = [existing mutableCopy];
        applyNewViewControllers(m);
        return;
    }

    static NSArray *mutableKeys;
    static dispatch_once_t onceVC;
    dispatch_once(&onceVC, ^{
        mutableKeys = @[ @"_viewControllers", @"viewControllers", @"_tabViewControllers", @"tabViewControllers" ];
    });
    for (NSString *key in mutableKeys) {
        @try {
            id raw = [tabBarController valueForKey:key];
            if (![raw isKindOfClass:[NSMutableArray class]]) {
                continue;
            }
            NSMutableArray *m = (NSMutableArray *)raw;
            if (index < m.count) {
                [m removeObjectAtIndex:index];
                return;
            }
        } @catch (__unused NSException *e) {
        }
    }
}

static BOOL theta_removeTabWithAccessibilityLabel(NSString *label, NSMutableArray *buttons, id tabBar, id tabBarController) {
    if (!label.length) {
        return NO;
    }
    BOOL removedAny = NO;
    for (NSInteger i = (NSInteger)buttons.count - 1; i >= 0; i--) {
        id obj = [buttons objectAtIndex:(NSUInteger)i];
        if (![obj isKindOfClass:[UIView class]]) {
            continue;
        }
        UIView *v = (UIView *)obj;
        if (![v.accessibilityLabel isEqualToString:label]) {
            continue;
        }
        theta_removeTabViewControllerAtIndex(tabBarController, (NSUInteger)i);
        [buttons removeObjectAtIndex:(NSUInteger)i];
        removedAny = YES;
        theta_removeMatchingViewsFromTabBarMutableArrays(tabBar, v, label);
        theta_detachTabSlotForLabel(v, (UIView *)tabBar, label);
    }
    return removedAny;
}

/// Keeps tabs whose label looks like Profile or DMs. Instagram varies copy ("Messages", "Direct messages", localized strings).
static BOOL theta_messengerModeKeepsTabAccessibilityLabel(NSString *label) {
    if (!label.length) {
        return NO;
    }
    NSUInteger opts = NSCaseInsensitiveSearch;
    if ([label rangeOfString:@"Profile" options:opts].location != NSNotFound) {
        return YES;
    }
    if ([label rangeOfString:@"Direct messages" options:opts].location != NSNotFound) {
        return YES;
    }
    // Short / alternate DM copy (no "Direct" prefix).
    if ([label rangeOfString:@"Messages" options:opts].location != NSNotFound) {
        return YES;
    }
    return NO;
}

/// `IGTabBarController` exposes `_profileButton` / `_directInboxButton`; `_buttons` entries are often a wrapper, so labels may be empty or on a subview.
static BOOL theta_messengerTabViewIsProfileOrDirectIvar(UIView *tab, id tabBarController) {
    if (!tab || !tabBarController) {
        return NO;
    }
    UIView *profile = nil;
    UIView *direct = nil;
    @try {
        id p = [tabBarController valueForKey:@"_profileButton"];
        if ([p isKindOfClass:[UIView class]]) {
            profile = (UIView *)p;
        }
    } @catch (__unused NSException *e) {
    }
    @try {
        id d = [tabBarController valueForKey:@"_directInboxButton"];
        if ([d isKindOfClass:[UIView class]]) {
            direct = (UIView *)d;
        }
    } @catch (__unused NSException *e) {
    }
    if (profile) {
        if (tab == profile || [profile isDescendantOfView:tab] || [tab isDescendantOfView:profile]) {
            return YES;
        }
    }
    if (direct) {
        if (tab == direct || [direct isDescendantOfView:tab] || [tab isDescendantOfView:direct]) {
            return YES;
        }
    }
    return NO;
}

/// Removes every tab whose accessibility label is not kept by messenger mode (Profile / Direct messages).
static BOOL theta_removeTabsNotMatchingMessengerMode(NSMutableArray *buttons, id tabBar, id tabBarController) {
    if (!buttons.count) {
        return NO;
    }
    BOOL removedAny = NO;
    for (NSInteger i = (NSInteger)buttons.count - 1; i >= 0; i--) {
        id obj = [buttons objectAtIndex:(NSUInteger)i];
        if (![obj isKindOfClass:[UIView class]]) {
            continue;
        }
        UIView *v = (UIView *)obj;
        NSString *label = v.accessibilityLabel ?: @"";
        if (theta_messengerTabViewIsProfileOrDirectIvar(v, tabBarController)) {
            continue;
        }
        if (theta_messengerModeKeepsTabAccessibilityLabel(label)) {
            continue;
        }
        theta_removeTabViewControllerAtIndex(tabBarController, (NSUInteger)i);
        [buttons removeObjectAtIndex:(NSUInteger)i];
        removedAny = YES;
        theta_removeMatchingViewsFromTabBarMutableArrays(tabBar, v, label);
        theta_detachTabSlotForLabel(v, (UIView *)tabBar, label);
    }
    return removedAny;
}

/// If present, call IGTabBar’s own layout so button frames match internal state.
static void theta_tryInvokeTabBarPrivateLayout(id tabBar) {
    if (!tabBar) {
        return;
    }
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[ @"_layoutButtons", @"_layoutTabBarItems", @"_updateTabBarLayout", @"_relayoutButtons" ];
    });
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if ([tabBar respondsToSelector:sel]) {
            ((void (*)(id, SEL))objc_msgSend)(tabBar, sel);
            return;
        }
    }
}

/// Removing a tab item skips IGTabBar’s normal layout pass; force redistribution of the remaining buttons.
static void theta_relayoutTabBarAfterButtonRemoval(UIView *tabBar, UIViewController *controller) {
    if (!tabBar) {
        return;
    }
    void (^apply)(void) = ^{
        SEL invSel = @selector(invalidateIntrinsicContentSize);
        if ([tabBar respondsToSelector:invSel]) {
            ((void (*)(id, SEL))objc_msgSend)(tabBar, invSel);
        }
        if ([tabBar respondsToSelector:@selector(setNeedsUpdateConstraints)]) {
            [tabBar setNeedsUpdateConstraints];
        }
        [tabBar setNeedsLayout];
        for (UIView *v = tabBar.superview; v; v = v.superview) {
            [v setNeedsLayout];
            if ([v respondsToSelector:@selector(setNeedsUpdateConstraints)]) {
                [v setNeedsUpdateConstraints];
            }
        }
        if (controller) {
            [controller.view setNeedsLayout];
        }
        [tabBar updateConstraintsIfNeeded];
        theta_tryInvokeTabBarPrivateLayout(tabBar);
        [tabBar layoutIfNeeded];
        if (controller) {
            [controller.view layoutIfNeeded];
        }
    };
    apply();
    dispatch_async(dispatch_get_main_queue(), apply);
}

static void theta_syncSwipeCoordinatorAndTabSelection(id tabBarController) {
    if (!tabBarController) {
        return;
    }
    id coord = nil;
    @try {
        coord = [tabBarController valueForKey:@"_swipeCoordinator"];
    } @catch (__unused NSException *e) {
    }
    if (!coord) {
        return;
    }

    id collectionView = nil;
    @try {
        collectionView = [coord valueForKey:@"_collectionView"];
    } @catch (__unused NSException *e) {
    }
    if (collectionView && [collectionView respondsToSelector:@selector(reloadData)]) {
        [collectionView performSelector:@selector(reloadData)];
    }

    id selectedSurface = nil;
    @try {
        selectedSurface = [tabBarController valueForKey:@"_selectedTabBarSurface"];
    } @catch (__unused NSException *e) {
    }
    if (!selectedSurface && [tabBarController respondsToSelector:@selector(selectedTabBarSurface)]) {
        selectedSurface = ((id (*)(id, SEL))objc_msgSend)(tabBarController, @selector(selectedTabBarSurface));
    }

    if (selectedSurface && [coord respondsToSelector:@selector(setSelectedSurface:)]) {
        [coord performSelector:@selector(setSelectedSurface:) withObject:selectedSurface];
    }

    SEL syncSel = @selector(setSelectedTabBarSurface:animated:skipMainFeedFetch:);
    if (selectedSurface && [tabBarController respondsToSelector:syncSel]) {
        ((void (*)(id, SEL, id, BOOL, BOOL))objc_msgSend)(tabBarController, syncSel, selectedSurface, NO, YES);
    }

    if ([coord respondsToSelector:@selector(forceInitialLayout)]) {
        [coord performSelector:@selector(forceInitialLayout)];
    }
}

/// Keeps only PROFILE and DIRECT swipe surfaces (matches `tabStringFromSurfaceIntent`).
static void theta_trimSurfacesToMessengerOnly(id swipeCoordinator, BOOL *outMutated) {
    if (!swipeCoordinator) {
        return;
    }
    id surfacesObj = nil;
    @try {
        surfacesObj = [swipeCoordinator valueForKey:@"_surfaces"];
    } @catch (__unused NSException *e) {
    }
    if (![surfacesObj isKindOfClass:[NSArray class]] || [(NSArray *)surfacesObj count] == 0) {
        return;
    }
    NSMutableArray *surfaces = [(NSArray *)surfacesObj mutableCopy];
    NSUInteger before = surfaces.count;
    for (NSInteger i = (NSInteger)surfaces.count - 1; i >= 0; i--) {
        id surface = [surfaces objectAtIndex:(NSUInteger)i];
        NSString *intent = [surface performSelector:@selector(tabStringFromSurfaceIntent)];
        BOOL keep = [intent isEqualToString:@"PROFILE"] || [intent isEqualToString:@"DIRECT"];
        if (!keep) {
            [surfaces removeObjectAtIndex:(NSUInteger)i];
        }
    }
    if (surfaces.count != before) {
        *outMutated = YES;
        @try {
            [swipeCoordinator setValue:surfaces forKey:@"_surfaces"];
        } @catch (__unused NSException *e) {
        }
    }
}

static void theta_trimTabBarSurfacesToMessengerOnly(id tabBarController, BOOL *outMutated) {
    id tabBarSurfacesObj = nil;
    @try {
        tabBarSurfacesObj = [tabBarController valueForKey:@"_tabBarSurfaces"];
    } @catch (__unused NSException *e) {
    }
    if (![tabBarSurfacesObj isKindOfClass:[NSArray class]] || [(NSArray *)tabBarSurfacesObj count] == 0) {
        return;
    }
    NSMutableArray *mutableTabBarSurfaces = [(NSArray *)tabBarSurfacesObj mutableCopy];
    NSUInteger before = mutableTabBarSurfaces.count;
    for (NSInteger i = (NSInteger)mutableTabBarSurfaces.count - 1; i >= 0; i--) {
        id surface = [mutableTabBarSurfaces objectAtIndex:(NSUInteger)i];
        NSString *intent = [surface performSelector:@selector(tabStringFromSurfaceIntent)];
        BOOL keep = [intent isEqualToString:@"PROFILE"] || [intent isEqualToString:@"DIRECT"];
        if (!keep) {
            [mutableTabBarSurfaces removeObjectAtIndex:(NSUInteger)i];
        }
    }
    if (mutableTabBarSurfaces.count != before) {
        *outMutated = YES;
        @try {
            [tabBarController setValue:mutableTabBarSurfaces forKey:@"_tabBarSurfaces"];
        } @catch (__unused NSException *e) {
        }
    }
}

// Returns YES if the tab with the given surface intent should be removed
static BOOL theta_shouldRemoveSurfaceIntent(NSString *intent) {
    if ([intent isEqualToString:@"FEED"]   && ENABLED(@"Hide Feed Tab"))     return YES;
    if ([intent isEqualToString:@"CLIPS"]  && ENABLED(@"Hide Reels Tab"))    return YES;
    if ([intent isEqualToString:@"SEARCH"] && ENABLED(@"Hide Explore Tab"))  return YES;
    if ([intent isEqualToString:@"DIRECT"] && ENABLED(@"Hide Messages Tab")) return YES;
    return NO;
}

// Returns YES if any individual tab-hide toggle is active
static BOOL theta_anyTabHideEnabled(void) {
    return ENABLED(@"Hide Feed Tab") || ENABLED(@"Hide Reels Tab")
        || ENABLED(@"Hide Explore Tab") || ENABLED(@"Hide Messages Tab");
}

// Walks the full VC hierarchy (children + presented) to find IGTabBarController.
static UIViewController *theta_findIGTabBarController(void) {
    Class cls = objc_getClass("IGTabBarController");
    if (!cls) return nil;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    UIViewController *root = win.rootViewController;
    if (!root) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([vc isKindOfClass:cls]) return vc;
        for (UIViewController *child in vc.childViewControllers) {
            [queue addObject:child];
        }
        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
    }
    return nil;
}

// After updating the surface data model, force the tab bar's UICollectionView (floating
// glass tab bar) to reload so it renders the correct number of slots without gaps.
static void theta_reloadTabBarCollectionViews(id tabBarController) {
    if (!tabBarController) return;
    UIView *tabBar = nil;
    @try { tabBar = ((id(*)(id,SEL))objc_msgSend)(tabBarController, @selector(tabBar)); } @catch (__unused NSException *e) {}
    if (!tabBar) return;

    // Walk the tab bar's full view hierarchy and reload any UICollectionViews found.
    NSMutableArray *queue = [NSMutableArray arrayWithObject:tabBar];
    while (queue.count) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UICollectionView class]]) {
            [(UICollectionView *)v reloadData];
            [v layoutIfNeeded];
        }
        [queue addObjectsFromArray:v.subviews];
    }

    // Also attempt known private rebuild selectors on the tab bar controller.
    static NSArray *sRebuildNames;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sRebuildNames = @[
            @"_reloadTabBarButtons", @"_refreshTabBarLayout",
            @"_setupTabBarItems",    @"_buildTabBarButtons",
            @"_updateTabBarButtons", @"_configureTabBarButtons",
        ];
    });
    for (NSString *name in sRebuildNames) {
        SEL sel = NSSelectorFromString(name);
        if ([tabBarController respondsToSelector:sel]) {
            ((void(*)(id,SEL))objc_msgSend)(tabBarController, sel);
            break;
        }
    }
}

// Core tab-hiding logic — safe to call directly without going through viewWillAppear:.
static void THApplyTabHidingNow(id tabBarController) {
    if (!tabBarController) return;
    BOOL messengerMode = ENABLED(@"Messenger Mode");
    BOOL anyTabHide = theta_anyTabHideEnabled();
    if (!messengerMode && !anyTabHide) return;

    @try {
        BOOL removedTabButtons = NO;
        BOOL mutatedSurfaceLists = NO;

        id buttonsObj = [tabBarController valueForKey:@"_buttons"];
        if ([buttonsObj isKindOfClass:[NSArray class]] && [(NSArray *)buttonsObj count] > 0) {
            // Always work on a mutable copy so removals work even if Instagram stores
            // _buttons as an immutable NSArray; we write back the modified copy below.
            NSMutableArray *buttons = [(NSArray *)buttonsObj mutableCopy];
            id tabBar = ((id (*)(id, SEL))objc_msgSend)(tabBarController, @selector(tabBar));
            if (messengerMode) {
                removedTabButtons |= theta_removeTabsNotMatchingMessengerMode(buttons, tabBar, tabBarController);
            } else {
                if (ENABLED(@"Hide Reels Tab")) {
                    removedTabButtons |= theta_removeTabWithAccessibilityLabel(@"Reels", buttons, tabBar, tabBarController);
                }
                if (ENABLED(@"Hide Explore Tab")) {
                    removedTabButtons |= theta_removeTabWithAccessibilityLabel(@"Explore", buttons, tabBar, tabBarController);
                }
                if (ENABLED(@"Hide Feed Tab")) {
                    removedTabButtons |= theta_removeTabWithAccessibilityLabel(@"Home", buttons, tabBar, tabBarController);
                    removedTabButtons |= theta_removeTabWithAccessibilityLabel(@"Feed", buttons, tabBar, tabBarController);
                }
                if (ENABLED(@"Hide Messages Tab")) {
                    removedTabButtons |= theta_removeTabWithAccessibilityLabel(@"Direct messages", buttons, tabBar, tabBarController);
                    removedTabButtons |= theta_removeTabWithAccessibilityLabel(@"Messages", buttons, tabBar, tabBarController);
                }
            }
            if (removedTabButtons) {
                // Write the trimmed array back so IG's internal state stays in sync.
                @try { [tabBarController setValue:buttons forKey:@"_buttons"]; } @catch (__unused NSException *e) {}
                theta_relayoutTabBarAfterButtonRemoval((UIView *)tabBar, (UIViewController *)tabBarController);
            }
        }

        id swipeCoordinator = [tabBarController valueForKey:@"_swipeCoordinator"];
        if (swipeCoordinator) {
            if (messengerMode) {
                theta_trimSurfacesToMessengerOnly(swipeCoordinator, &mutatedSurfaceLists);
            } else {
                id surfacesObj = nil;
                @try {
                    surfacesObj = [swipeCoordinator valueForKey:@"_surfaces"];
                } @catch (__unused NSException *e) {
                }
                if ([surfacesObj isKindOfClass:[NSArray class]] && [(NSArray *)surfacesObj count] > 0) {
                    NSMutableArray *surfaces = [(NSArray *)surfacesObj mutableCopy];
                    NSUInteger before = surfaces.count;
                    for (NSInteger i = (NSInteger)surfaces.count - 1; i >= 0; i--) {
                        id surface = [surfaces objectAtIndex:(NSUInteger)i];
                        NSString *intent = nil;
                        @try { intent = [surface performSelector:@selector(tabStringFromSurfaceIntent)]; } @catch (__unused NSException *e) {}
                        if (theta_shouldRemoveSurfaceIntent(intent)) {
                            [surfaces removeObjectAtIndex:(NSUInteger)i];
                        }
                    }
                    if (surfaces.count != before) {
                        mutatedSurfaceLists = YES;
                        @try {
                            [swipeCoordinator setValue:surfaces forKey:@"_surfaces"];
                        } @catch (__unused NSException *e) {
                        }
                    }
                }
            }
        }

        if (messengerMode) {
            theta_trimTabBarSurfacesToMessengerOnly(tabBarController, &mutatedSurfaceLists);
        } else {
            id tabBarSurfacesObj = [tabBarController valueForKey:@"_tabBarSurfaces"];
            if ([tabBarSurfacesObj isKindOfClass:[NSArray class]] && [(NSArray *)tabBarSurfacesObj count] > 0) {
                NSMutableArray *mutableTabBarSurfaces = [(NSArray *)tabBarSurfacesObj mutableCopy];
                NSUInteger before = mutableTabBarSurfaces.count;
                for (NSInteger i = (NSInteger)mutableTabBarSurfaces.count - 1; i >= 0; i--) {
                    id surface = [mutableTabBarSurfaces objectAtIndex:(NSUInteger)i];
                    NSString *intent = nil;
                    @try { intent = [surface performSelector:@selector(tabStringFromSurfaceIntent)]; } @catch (__unused NSException *e) {}
                    if (theta_shouldRemoveSurfaceIntent(intent)) {
                        [mutableTabBarSurfaces removeObjectAtIndex:(NSUInteger)i];
                    }
                }
                if (mutableTabBarSurfaces.count != before) {
                    mutatedSurfaceLists = YES;
                    @try {
                        [tabBarController setValue:mutableTabBarSurfaces forKey:@"_tabBarSurfaces"];
                    } @catch (__unused NSException *e) {
                    }
                }
            }
        }

        if (removedTabButtons || mutatedSurfaceLists) {
            theta_syncSwipeCoordinatorAndTabSelection(tabBarController);
        }
    } @catch (NSException *exception) {
        NSLog(@"HideTabs: %@", exception);
    }
}

static void hook_hideTabs(id self, SEL _cmd, BOOL animated) {
    // Let Instagram finish setting up the tab bar first
    orig_hideTabs(self, _cmd, animated);
    THApplyTabHidingNow(self);
}

void THRegisterHideTabsHooks(void) {
    Class tbCls = objc_getClass("IGTabBarController");
    if (!tbCls) return;

    NullHookMessageEx(tbCls, @selector(viewWillAppear:), (void *)hook_hideTabs, &orig_hideTabs);

    // Hooks are installed post-auth; viewWillAppear: has already fired for the visible
    // tab bar. Apply immediately so the user sees the correct state on first launch.
    // Use dispatch_after to let IG finish any in-flight layout before we modify it.
    void (^applyNow)(void) = ^{
        if (!ENABLED(@"Messenger Mode") && !theta_anyTabHideEnabled()) return;
        UIViewController *tbc = theta_findIGTabBarController();
        if (tbc) THApplyTabHidingNow(tbc);
    };
    // First attempt: next run-loop turn
    dispatch_async(dispatch_get_main_queue(), applyNow);
    // Second attempt: after 0.5 s in case IG is still building the tab bar
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), applyNow);
}
